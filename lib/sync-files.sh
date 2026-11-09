#!/usr/bin/env bash
# File IO under the daemon's lock. All temporary metadata stays in .share/.
# Globals are supplied by tools/sync; ignore patterns intentionally expand.
# shellcheck disable=SC2154,SC2254,SC2034
hash_file() { openssl dgst -sha256 "$1" | sed 's/.*= //'; }
file_stat() { stat -c '%s %Y %i' "$1" 2>/dev/null || stat -f '%z %m %i' "$1" 2>/dev/null; }
event() { printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" >> "$state/history"; }
# Patterns are read once per scan/payload, not once per path: large ignored
# trees made per-path rereads dominate every cycle.
ignore_load() {
  local pattern
  ignores=(); ignores_from="$d"
  [ -f "$d/.shareignore" ] || return 0
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case "$pattern" in ''|'#'*) continue;; esac
    ignores+=("$pattern")
  done < "$d/.shareignore"
}
ignored() {
  local p="$1" pattern
  case "/$p/" in */.share/*|*/.git/*) return 0;; esac
  [ "$p" != .shareignore ] || return 1
  case "${p##*/}" in .DS_Store|*.swp|*~|.~lock*|'~$'*|.syncthing.*|*.tmp-share-*) return 0;; esac
  [ "${ignores_from-}" = "$d" ] || ignore_load
  for pattern in ${ignores[@]+"${ignores[@]}"}; do
    case "$p" in $pattern) return 0;; esac
    case "${p##*/}" in $pattern) return 0;; esac
    case "$pattern" in */) case "$p/" in "$pattern"*) return 0;; esac;; esac
  done
  return 1
}
# find arguments pruning directories whose every descendant ignored() skips.
# find -path, like case, lets * match /, so a pattern ending in * that matches
# a directory also matches everything below it; a literal x/ covers its tree.
# Anything not pruned is still filtered per file, so semantics are unchanged.
prune_args() {
  local pattern root
  root="$(printf '%s' "$d" | sed 's/[][*?\\]/\\&/g')"
  prune=(-name .share -o -name .git)
  for pattern in ${ignores[@]+"${ignores[@]}"}; do
    case "$pattern" in
      */) case "$pattern" in *[][*?\\]*) ;; *) prune+=(-o -path "$root/${pattern%/}");; esac;;
      */\*) prune+=(-o -path "$root/${pattern%/\*}" -o -path "$root/$pattern");;
      *\*) prune+=(-o -path "$root/$pattern");;
    esac
  done
}
safe_path() {
  local rest="$1" part at="$d"
  case "$rest" in ''|/*|*$'\t'*|*$'\n'*) return 1;; esac
  while :; do
    part="${rest%%/*}"
    case "$part" in ''|.|..|.git|.share) return 1;; esac
    at="$at/$part"; [ ! -L "$at" ] || return 1
    [ "$rest" != "$part" ] || break; rest="${rest#*/}"
  done
}
is_text() {
  local ext
  case "$1" in *.md|*.txt) return 0;; esac
  for ext in ${SHARE_TEXT_EXT:-}; do case "$1" in *."${ext#.}") return 0;; esac; done
  return 1
}
# .sharemerge: "<glob> <strategy>" per line, first match wins, globs as in
# .shareignore. Synced, so the elected replica (see text_merges) applies the
# same rule either side wrote. Unmatched text keeps diff3, the rest copies.
merge_load() {
  local pattern strategy rest
  merges=()
  [ -f "$d/.sharemerge" ] || return 0
  while read -r pattern strategy rest || [ -n "$pattern" ]; do
    case "$pattern" in ''|'#'*) continue;; esac
    case "$strategy" in
      diff3|union-lines|json-merge|conflict-copies|lease) ;;
      cmd:*) case "${strategy#cmd:}" in ''|*[!A-Za-z0-9_.-]*|.*) strategy=invalid;; esac;;
      *) strategy=invalid;;
    esac
    if [ "$strategy" = invalid ]; then
      grep -Fxq -- "$pattern" "$state/merge.warned" 2>/dev/null ||
        { log ".sharemerge: bad strategy for $pattern; keeping conflict copies"; printf '%s\n' "$pattern" >> "$state/merge.warned"; }
      strategy=conflict-copies
    fi
    merges+=("$pattern" "$strategy")
  done < "$d/.sharemerge"
}
# Sets $strategy for path $1 (no subshell: retain_blobs asks once per entry).
merge_strategy() {
  local p="$1" i=0
  while [ "$i" -lt "${#merges[@]}" ]; do
    case "$p" in ${merges[i]}) strategy="${merges[i+1]}"; return;; esac
    case "${p##*/}" in ${merges[i]}) strategy="${merges[i+1]}"; return;; esac
    i=$((i+2))
  done
  if is_text "$p"; then strategy=diff3; else strategy=conflict-copies; fi
}
merge_uses_base() { case "$1" in diff3|union-lines|json-merge|cmd:*) return 0;; esac; return 1; }
# merge_run STRATEGY PATH FIRST BASE SECOND > merged; nonzero leaves the
# siblings as conflict copies. Drivers are local (never synced): a peer can
# name one in .sharemerge but cannot supply the program.
merge_run() {
  local driver
  case "$1" in
    diff3) command -v diff3 >/dev/null && diff3 -m "$3" "$4" "$5";;
    # Keep FIRST; append lines SECOND added over BASE that FIRST did not also add.
    union-lines) awk 'FILENAME==ARGV[1]{b[$0]++;next}
      FILENAME==ARGV[2]{print;f[$0]++;next}
      !init{for(l in f)a[l]=f[l]-b[l];init=1}
      {if(b[$0]>0)b[$0]--;else if(a[$0]>0)a[$0]--;else print}' "$4" "$3" "$5";;
    json-merge) command -v jq >/dev/null && jq -n --slurpfile b "$4" --slurpfile x "$3" --slurpfile y "$5" '
      # Values wrapped as [] (absent) or [v]; objects merge per key, anything
      # else changed differently on both sides is a conflict.
      def m($b; $x; $y):
        if $x == $y then $x elif $x == $b then $y elif $y == $b then $x
        elif ([$b, $x, $y] | all(length == 1 and (.[0] | type) == "object")) then
          $b[0] as $bo | $x[0] as $xo | $y[0] as $yo |
          [reduce ((($xo | keys_unsorted) + (($yo | keys_unsorted) - ($xo | keys_unsorted)))[]) as $k ({};
            m(if $bo | has($k) then [$bo[$k]] else [] end;
              if $xo | has($k) then [$xo[$k]] else [] end;
              if $yo | has($k) then [$yo[$k]] else [] end) as $r |
            if $r == [] then . else .[$k] = $r[0] end)]
        else error("conflict") end;
      if [$b, $x, $y | length] != [1, 1, 1] then error("one JSON value per file") else m($b; $x; $y)[0] end';;
    cmd:*) driver="${XDG_CONFIG_HOME:-$HOME/.config}/share/merge/${1#cmd:}"
      [ -x "$driver" ] && "$driver" "$4" "$3" "$5" "$2";;
    *) return 1;;
  esac
}
# A lease path with concurrent versions means two writers broke a territory:
# record it once per sibling set for whoever enforces leases.
lease_collision() {
  local p="$1" hashes
  hashes="$(cut -f2 "$state/siblings" | LC_ALL=C sort -u | paste -sd, -)"
  SHARE_QUERY_PATH="$p" SHARE_QUERY_HASHES="$hashes" \
    awk -F '\t' '$2==ENVIRON["SHARE_QUERY_PATH"]&&$3==ENVIRON["SHARE_QUERY_HASHES"]{found=1}END{exit !found}' \
    "$state/collisions" 2>/dev/null && return 0
  printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$p" "$hashes" >> "$state/collisions"
  event "$rid" L "$p"; log "lease collision: $p"
}
init_state() {
  state="$d/.share"; [ ! -L "$state" ] || return 1
  mkdir -p "$state"/{blobs,base,peer} || return 1
  if [ ! -f "$state/replica" ]; then
    openssl rand -hex 6 > "$state/replica.new" && mv "$state/replica.new" "$state/replica" || return 1
    [ ! -d "$d/.git" ] || log 'v2 migration: .git left untouched; remove it only after both sides run v2 and rollback is no longer needed'
    # v1's git add -A must not commit our replica ID/cache on rollback. Use a
    # normal working file, never mutate .git/config or .git/info/exclude.
    if [ -d "$d/.git" ] && ! grep -Fxq '/.share/' "$d/.gitignore" 2>/dev/null; then
      [ ! -L "$d/.gitignore" ] || return 1
      { [ ! -f "$d/.gitignore" ] || cat "$d/.gitignore"; printf '\n/.share/\n'; } > "$d/.gitignore.tmp-share-migrate" &&
        mv "$d/.gitignore.tmp-share-migrate" "$d/.gitignore" || return 1
    fi
  fi
  rid="$(cat "$state/replica")"
  for meta in manifest cache history observed rescan; do [ -f "$state/$meta" ] || : > "$state/$meta"; done
}
path_entries() { SHARE_QUERY_PATH="$1" awk -F '\t' '$1==ENVIRON["SHARE_QUERY_PATH"]' "$state/manifest"; }
observe_path() {
  SHARE_QUERY_PATH="$1" awk -F '\t' '$1!=ENVIRON["SHARE_QUERY_PATH"]' "$state/observed" > "$state/observed.new"
  path_entries "$1" >> "$state/observed.new"
  mv "$state/observed.new" "$state/observed"
}
cache_row() { SHARE_QUERY_PATH="$1" awk -F '\t' '$1==ENVIRON["SHARE_QUERY_PATH"]{print $2 " " $3 " " $4 " " $5;exit}' "$state/cache"; }
set_cache() {
  local p="$1" h="$2" st="$3"
  SHARE_QUERY_PATH="$p" awk -F '\t' '$1!=ENVIRON["SHARE_QUERY_PATH"]' "$state/cache" > "$state/cache.new" || return 1
  [ "$h" = - ] || printf '%s\t%s\t%s\t%s\t%s\n' "$p" $st "$h" >> "$state/cache.new"
  mv "$state/cache.new" "$state/cache"
}
local_version() {
  local p="$1" h="$2" parent="$3" vv op=M
  # A skipped apply has not observed the incoming clocks. Using them here
  # would let an intervening editor write dominate bytes it never saw.
  SHARE_QUERY_PATH="$p" awk -F '\t' '$1==ENVIRON["SHARE_QUERY_PATH"]' "$state/observed" > "$state/observed.path"
  # Own counters must still be monotonic if a failed apply follows a text merge.
  path_entries "$p" | awk -F '\t' -v rid="$rid" '{n=split($4,a,",");for(i=1;i<=n;i++){split(a[i],b,":");if(b[1]==rid&&b[2]+0>m)m=b[2]+0}}END{if(m)print "-\t-\t-\t" rid ":" m}' >> "$state/observed.path"
  vv="$(sync_clock "$rid" < "$state/observed.path")"
  [ "$parent" != - ] || op=A; [ "$h" != - ] || op=D
  printf '%s\t%s\t%s\t%s\n' "$p" "$h" "$parent" "$vv" > "$state/edit"
  sync_merge "$state/manifest" "$state/edit" > "$state/manifest.new" && mv "$state/manifest.new" "$state/manifest" || return 1
  # Only this local version was observed, not concurrent incoming siblings.
  SHARE_QUERY_PATH="$p" awk -F '\t' '$1!=ENVIRON["SHARE_QUERY_PATH"]' "$state/observed" > "$state/observed.new"
  cat "$state/edit" >> "$state/observed.new"; mv "$state/observed.new" "$state/observed"
  event "$rid" "$op" "$p"
}
# Batch stat of newline-separated relative paths: "size mtime inode<TAB>./path"
# (the ./ keeps a leading - from reading as an option).
stat_paths() {
  if stat -c %s / >/dev/null 2>&1; then
    sed 's|^|./|' | tr '\n' '\0' | (cd "$d" && xargs -0 stat -c $'%s %Y %i\t%n' 2>/dev/null) || true
  else
    sed 's|^|./|' | tr '\n' '\0' | (cd "$d" && xargs -0 stat -f $'%z %m %i\t%N' 2>/dev/null) || true
  fi
}
scan() {
  local file p st after old oldh h size mt inode prune
  : > "$state/seen"
  ignore_load; prune_args
  while IFS= read -r -d '' file; do
    p="${file#"$d/"}"
    if ! safe_path "$p"; then
      h="$(printf %s "$p" | openssl dgst -sha256 | sed 's/.*= //')"
      if [ ! -f "$state/skipped-$h" ]; then log "skipped unsupported path: $(printf %q "$p")"; : > "$state/skipped-$h"; fi
      continue
    fi
    ignored "$p" && continue
    printf '%s\n' "$p" >> "$state/seen"
  done < <(find "$d" -type d \( "${prune[@]}" \) -prune -o -type f -print0)
  # Unchanged files are settled by one batched stat joined with the cache, not
  # several processes per file. The per-file checks below still decide the rest.
  stat_paths < "$state/seen" > "$state/stats"
  # "new" paths have no cache, manifest, observed or rescan rows at all.
  awk -F '\t' -v now="$(date +%s)" '
    FILENAME==ARGV[1]{cache[$1]=$2 " " $3 " " $4;next}
    FILENAME==ARGV[2]{rescan[$1]=1;next}
    FILENAME==ARGV[3]||FILENAME==ARGV[4]{known[$1]=1;next}
    {sub(/^\.\//,"",$2);split($1,a," ");if(!($2 in cache)||cache[$2]!=$1||a[2]>=now-2||($2 in rescan))
      print (($2 in cache)||($2 in rescan)||($2 in known)?"seen":"new") "\t" $2}' \
    "$state/cache" "$state/rescan" "$state/manifest" "$state/observed" "$state/stats" > "$state/changed"
  : > "$state/fresh"; : > "$state/fresh.cache"
  while IFS=$'\t' read -r kind p; do
    file="$d/$p"
    st="$(file_stat "$file")" || continue
    old="$(cache_row "$p")"; oldh="${old##* }"; oldh="${oldh:--}"
    read -r size mt inode <<< "$st"
    # Seconds-only BSD stat cannot detect a second write in the same second.
    # Rehash recent files even if their stat tuple matches the previous scan.
    if [ "$old" = "$st $oldh" ] && [ "$mt" -lt "$(($(date +%s)-2))" ] && ! grep -Fxq -- "$p" "$state/rescan"; then continue; fi
    cp "$file" "$state/snapshot" || continue
    h="$(hash_file "$state/snapshot")"; after="$(file_stat "$file")"
    [ "$st" = "$after" ] && [ "$h" = "$(hash_file "$file")" ] || continue
    mv "$state/snapshot" "$state/blobs/$h" || continue
    [ "$size" -lt $((${SHARE_BIG_MB:-20}*1048576)) ] || [ "$h" = "$oldh" ] || log "large file $((size/1048576))MB: $p"
    # A new path's first version is always "rid:1" with no parent. Register
    # them in one merge below; a first scan otherwise rewrites the whole
    # manifest once per file.
    if [ "$kind" = new ]; then
      printf '%s\t%s\t-\t%s:1\n' "$p" "$h" "$rid" >> "$state/fresh"
      printf '%s\t%s\t%s\t%s\t%s\n' "$p" $st "$h" >> "$state/fresh.cache"
      continue
    fi
    if [ "$h" != "$oldh" ]; then local_version "$p" "$h" "$oldh" || return 1; fi
    set_cache "$p" "$h" "$st"
    grep -Fxv -- "$p" "$state/rescan" > "$state/rescan.new" || true
    mv "$state/rescan.new" "$state/rescan"
  done < "$state/changed"
  if [ -s "$state/fresh" ]; then
    sync_merge "$state/manifest" "$state/fresh" > "$state/manifest.new" && mv "$state/manifest.new" "$state/manifest" || return 1
    cat "$state/fresh" >> "$state/observed"; cat "$state/fresh.cache" >> "$state/cache"
    awk -F '\t' -v t="$(date -u +%FT%TZ)" -v rid="$rid" '{print t "\t" rid "\tA\t" $1}' "$state/fresh" >> "$state/history"
  fi
  # Cached paths no longer seen: candidates for deletion.
  awk -F '\t' 'FILENAME==ARGV[1]{seen[$0]=1;next}!($1 in seen)' "$state/seen" "$state/cache" > "$state/cache.before"
  while IFS=$'\t' read -r p size mt inode oldh; do
    [ -n "$p" ] || continue
    ignored "$p" && continue
    if [ ! -e "$d/$p" ] && [ ! -L "$d/$p" ]; then
      local_version "$p" - "$oldh" && set_cache "$p" - '' || return 1
    fi
  done < "$state/cache.before"
}
# A deterministic view. Causal siblings remain in the manifest until an edit.
make_view() {
  LC_ALL=C sort -t $'\t' -k1,1 -k2,2 "$state/manifest" > "$state/sorted"
    awk -F '\t' 'BEGIN{OFS="\t"}
    FILENAME==ARGV[1]{reserved[$1]=1;next}
    function conflict(p,hash, n,ext,stem,candidate){
      n=split(p,a,"/");stem=p;ext=""
      if(a[n]~/^.+\.[^.]*$/){ext=a[n];sub(/^.*\./,".",ext);stem=substr(p,1,length(p)-length(ext))}
      candidate=stem ".conflict-" substr(hash,1,8) ext
      while(candidate in reserved || candidate in used) candidate=candidate ".conflict-" hash
      used[candidate]=1;return candidate
    }
    function flush( i,p,n,ext,stem){
      if(path=="")return
      if(!count){print path,"-";return}
      print path,h[count]
      for(i=1;i<count;i++){
        print conflict(path,h[i]),h[i]
      }
    }
    $1!=path{flush();path=$1;count=0;last=""}
    $2!="-"&&$2!=last{h[++count]=$2;last=$2}
    END{flush()}' "$state/manifest" "$state/sorted" | LC_ALL=C sort -u
}
text_merges() {
  local p h parent vv n joined elected first second strategy
  merge_load
  # Only paths with at least two different versions. Most sibling paths are
  # identical-hash concurrent creations from a migration.
  awk -F '\t' '!(($1 SUBSEP $2) in seen){seen[$1,$2]=1;n[$1]++}END{for(p in n)if(n[p]>1)print p}' \
    "$state/manifest" | LC_ALL=C sort > "$state/paths"
  while IFS= read -r p; do
    merge_strategy "$p"
    case "$strategy" in conflict-copies) continue;; esac
    path_entries "$p" > "$state/siblings"
    if [ "$strategy" = lease ]; then lease_collision "$p"; continue; fi
    # Merge only two edits of one shared non-empty parent, neither a deletion.
    n="$(wc -l < "$state/siblings" | tr -d ' ')"; [ "$n" = 2 ] || continue
    [ "$(cut -f2 "$state/siblings" | LC_ALL=C sort -u | wc -l | tr -d ' ')" = 2 ] || continue
    grep -q $'\t-\t' "$state/siblings" && continue
    [ "$(cut -f3 "$state/siblings" | LC_ALL=C sort -u | wc -l | tr -d ' ')" = 1 ] || continue
    parent="$(head -1 "$state/siblings" | cut -f3)"; [ -f "$state/base/$parent" ] || continue
    joined="$(sync_clock < "$state/siblings")"; elected="${joined%%:*}"
    [ "$elected" = "$rid" ] || continue
    first="$(head -1 "$state/siblings" | cut -f2)"; second="$(tail -1 "$state/siblings" | cut -f2)"
    if merge_run "$strategy" "$p" "$state/blobs/$first" "$state/base/$parent" "$state/blobs/$second" > "$state/merged" 2>/dev/null; then
      h="$(hash_file "$state/merged")"; mv "$state/merged" "$state/blobs/$h"
      vv="$(sync_clock "$rid" < "$state/siblings")"
      printf '%s\t%s\t%s\t%s\n' "$p" "$h" "$second" "$vv" > "$state/edit"
      sync_merge "$state/manifest" "$state/edit" > "$state/manifest.new" && mv "$state/manifest.new" "$state/manifest"
      event "$rid" M "$p"
    fi
  done < "$state/paths"
}
materialize() {
  local p h old oldh st dest temp op
  scan || return 1
  text_merges
  make_view > "$state/view"
  # Derived copies no longer needed after a clean merge may be removed only
  # while their bytes still match the previous materialization cache.
  if [ -f "$state/applied" ]; then
    awk -F '\t' 'FILENAME==ARGV[1]{seen[$1]=1;next}!($1 in seen){print $1 "\t-"}' "$state/view" "$state/applied" > "$state/obsolete"
    cat "$state/obsolete" >> "$state/view"
  fi
  # A path already materialized (view hash == cached hash) whose file keeps the
  # cached, settled stat tuple only needs observing; scan trusts the same tuple.
  # Mark those rows so the loop skips rehashing every file on every receive.
  awk -F '\t' 'FILENAME==ARGV[1]{c[$1]=$5;next}($1 in c)&&c[$1]==$2{print $1}' "$state/cache" "$state/view" | stat_paths > "$state/same.stats"
  awk -F '\t' -v now="$(date +%s)" '
    FILENAME==ARGV[1]{cache[$1]=$2 " " $3 " " $4;next}
    FILENAME==ARGV[2]{rescan[$1]=1;next}
    FILENAME==ARGV[3]{sub(/^\.\//,"",$2);split($1,a," ");if(cache[$2]==$1&&a[2]<now-2&&!($2 in rescan))settled[$2]=1;next}
    {print $1 "\t" $2 "\t" (($1 in settled)?"settled":"-")}' \
    "$state/cache" "$state/rescan" "$state/same.stats" "$state/view" > "$state/view.flagged"
  : > "$state/settled"
  while IFS=$'\t' read -r p h flag; do
    safe_path "$p" && ! ignored "$p" || continue
    if [ "$flag" = settled ]; then printf '%s\n' "$p" >> "$state/settled"; continue; fi
    dest="$d/$p"; old="$(cache_row "$p")"; oldh="${old##* }"; oldh="${oldh:--}"
    if [ -f "$dest" ]; then
      st="$(file_stat "$dest")"
      if [ "$old" != "$st $oldh" ] || [ "$(hash_file "$dest")" != "$oldh" ]; then
        printf '%s\n' "$p" >> "$state/rescan"; continue
      fi
    elif [ -e "$dest" ] || [ "$oldh" != - ]; then continue
    fi
    if [ "$h" = "$oldh" ]; then observe_path "$p"; continue; fi
    if [ "$h" = - ]; then
      rm -f -- "$dest" || continue
      set_cache "$p" - ''; event "$f" D "$p"
      # rmdir -p stops at the nonempty root (.share); never follows symlinks.
      rmdir -p "${dest%/*}" 2>/dev/null || true
    else
      [ -f "$state/blobs/$h" ] || continue
      mkdir -p "${dest%/*}" || continue
      temp="$dest.tmp-share-$(openssl rand -hex 6)"
      cp "$state/blobs/$h" "$temp" && mv -f -- "$temp" "$dest" || { rm -f -- "$temp"; continue; }
      set_cache "$p" "$h" "$(file_stat "$dest")"
      op=M; [ "$oldh" != - ] || op=A; case "$p" in *.conflict-*) op=C;; esac
      event "$f" "$op" "$p"
      [ "$p" != .shareignore ] || ignore_load
    fi
    observe_path "$p"
  done < "$state/view.flagged"
  # The manifest is fixed during the loop, so observing them together is the same.
  if [ -s "$state/settled" ]; then
    awk -F '\t' 'FILENAME==ARGV[1]{s[$0]=1;next}FILENAME==ARGV[2]{if(!($1 in s))print;next}($1 in s)' \
      "$state/settled" "$state/observed" "$state/manifest" > "$state/observed.new" && mv "$state/observed.new" "$state/observed"
  fi
  make_view > "$state/applied.new"; mv "$state/applied.new" "$state/applied"
  retain_blobs
}
retain_blobs() {
  local p h parent vv size strategy
  : > "$state/base.keep"
  merge_load
  while IFS=$'\t' read -r p h parent vv; do
    merge_strategy "$p"; merge_uses_base "$strategy" || continue
    for h in "$h" "$parent"; do
      [ "$h" != - ] || continue
      # Content-addressed: an existing base copy already holds these bytes.
      if [ ! -f "$state/base/$h" ] && [ -f "$state/blobs/$h" ]; then
        size="$(wc -c < "$state/blobs/$h")"
        if [ "$size" -le $((${SHARE_TEXT_MAX_KB:-1024}*1024)) ]; then cp "$state/blobs/$h" "$state/base/$h"; fi
      fi
      [ ! -f "$state/base/$h" ] || printf '%s\n' "$h" >> "$state/base.keep"
    done
  done < "$state/manifest"
  prune_store base base.keep
  { cut -f2 "$state/manifest"; cut -f5 "$state/cache"; } | LC_ALL=C sort -u > "$state/blob.keep"
  prune_store blobs blob.keep
}
# Remove store files not listed in the keep file: one set difference, not a grep per file.
prune_store() {
  local file
  (cd "$state/$1" && find . -type f -name '[!.]*' | sed 's|^\./||') | LC_ALL=C sort |
    LC_ALL=C comm -23 - <(LC_ALL=C sort -u "$state/$2") |
    while IFS= read -r file; do rm -f "$state/$1/$file"; done
}
