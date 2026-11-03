#!/usr/bin/env bash
# File IO under the daemon's lock. All temporary metadata stays in .share/.
# Globals are supplied by tools/sync; ignore patterns intentionally expand.
# shellcheck disable=SC2154,SC2254,SC2034
hash_file() { openssl dgst -sha256 "$1" | sed 's/.*= //'; }
file_stat() { stat -c '%s %Y %i' "$1" 2>/dev/null || stat -f '%z %m %i' "$1" 2>/dev/null; }
event() { printf '%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" >> "$state/history"; }
ignored() {
  local p="$1" pattern
  case "/$p/" in */.share/*|*/.git/*) return 0;; esac
  [ "$p" != .shareignore ] || return 1
  case "${p##*/}" in .DS_Store|*.swp|*~|.~lock*|'~$'*|.syncthing.*|*.tmp-share-*) return 0;; esac
  [ -f "$d/.shareignore" ] || return 1
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case "$pattern" in ''|'#'*) continue;; esac
    case "$p" in $pattern) return 0;; esac
    case "${p##*/}" in $pattern) return 0;; esac
    case "$pattern" in */) case "$p/" in "$pattern"*) return 0;; esac;; esac
  done < "$d/.shareignore"
  return 1
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
scan() {
  local file p st after old oldh h size mt inode
  : > "$state/seen"
  while IFS= read -r -d '' file; do
    p="${file#"$d/"}"
    if ! safe_path "$p"; then
      h="$(printf %s "$p" | openssl dgst -sha256 | sed 's/.*= //')"
      if [ ! -f "$state/skipped-$h" ]; then log "skipped unsupported path: $(printf %q "$p")"; : > "$state/skipped-$h"; fi
      continue
    fi
    ignored "$p" && continue
    printf '%s\n' "$p" >> "$state/seen"
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
    if [ "$h" != "$oldh" ]; then
      local_version "$p" "$h" "$oldh" || return 1
      [ "$size" -lt $((${SHARE_BIG_MB:-20}*1048576)) ] || log "large file $((size/1048576))MB: $p"
    fi
    set_cache "$p" "$h" "$st"
    grep -Fxv -- "$p" "$state/rescan" > "$state/rescan.new" || true
    mv "$state/rescan.new" "$state/rescan"
  done < <(find "$d" -type d \( -name .share -o -name .git \) -prune -o -type f -print0)
  cp "$state/cache" "$state/cache.before"
  while IFS=$'\t' read -r p size mt inode oldh; do
    [ -n "$p" ] || continue
    ignored "$p" && continue
    if ! grep -Fxq -- "$p" "$state/seen" && [ ! -e "$d/$p" ] && [ ! -L "$d/$p" ]; then
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
  local p h parent vv n joined elected first second
  cut -f1 "$state/manifest" | LC_ALL=C sort -u > "$state/paths"
  while IFS= read -r p; do
    is_text "$p" || continue
    path_entries "$p" > "$state/siblings"
    n="$(wc -l < "$state/siblings" | tr -d ' ')"; [ "$n" = 2 ] || continue
    [ "$(cut -f2 "$state/siblings" | LC_ALL=C sort -u | wc -l | tr -d ' ')" = 2 ] || continue
    grep -q $'\t-\t' "$state/siblings" && continue
    [ "$(cut -f3 "$state/siblings" | LC_ALL=C sort -u | wc -l | tr -d ' ')" = 1 ] || continue
    parent="$(head -1 "$state/siblings" | cut -f3)"; [ -f "$state/base/$parent" ] || continue
    joined="$(sync_clock < "$state/siblings")"; elected="${joined%%:*}"
    [ "$elected" = "$rid" ] || continue
    first="$(head -1 "$state/siblings" | cut -f2)"; second="$(tail -1 "$state/siblings" | cut -f2)"
    command -v diff3 >/dev/null || continue
    if diff3 -m "$state/blobs/$first" "$state/base/$parent" "$state/blobs/$second" > "$state/merged"; then
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
  while IFS=$'\t' read -r p h; do
    safe_path "$p" && ! ignored "$p" || continue
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
    fi
    observe_path "$p"
  done < "$state/view"
  make_view > "$state/applied.new"; mv "$state/applied.new" "$state/applied"
  retain_blobs
}
retain_blobs() {
  local p h parent vv file size
  : > "$state/base.keep"
  while IFS=$'\t' read -r p h parent vv; do
    is_text "$p" || continue
    for h in "$h" "$parent"; do
      [ "$h" != - ] || continue
      if [ -f "$state/blobs/$h" ]; then
        size="$(wc -c < "$state/blobs/$h")"
        if [ "$size" -le $((${SHARE_TEXT_MAX_KB:-1024}*1024)) ]; then cp "$state/blobs/$h" "$state/base/$h"; fi
      fi
      [ ! -f "$state/base/$h" ] || printf '%s\n' "$h" >> "$state/base.keep"
    done
  done < "$state/manifest"
  for file in "$state/base"/*; do
    [ ! -f "$file" ] || grep -Fxq "${file##*/}" "$state/base.keep" || rm -f "$file"
  done
  { cut -f2 "$state/manifest"; cut -f5 "$state/cache"; } | LC_ALL=C sort -u > "$state/blob.keep"
  for file in "$state/blobs"/*; do
    [ ! -f "$file" ] || grep -Fxq "${file##*/}" "$state/blob.keep" || rm -f "$file"
  done
}
