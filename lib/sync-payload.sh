#!/usr/bin/env bash
# The peer manifest is only a bandwidth hint. Missing bytes never enter state.
# shellcheck disable=SC2154,SC2034
# heal_blob PATH HASH: restore a missing blob from the working file if it still
# has exactly those bytes.
heal_blob() {
  local t="$state/blobs/.heal-$$"
  [ -f "$d/$1" ] && cp "$d/$1" "$t" 2>/dev/null && [ "$(hash_file "$t")" = "$2" ] && mv "$t" "$state/blobs/$2" && return 0
  rm -f "$t"; return 1
}
# Feature words this build implements; later phases append. A peer's critical
# feature missing here refuses its payload; other unknown features are logged.
share_features=()
has_feature() {
  local ft
  for ft in ${share_features[@]+"${share_features[@]}"}; do [ "$ft" = "$1" ] && return 0; done
  return 1
}
# Probed once at load. A failed probe leaves the flag empty, so the plain tar
# call still runs. --no-xattrs drops the LIBARCHIVE.xattr headers that GNU tar
# warns about; --warning silences only that keyword (BSD tar has no --warning).
tar_no_xattrs=
if tar --no-xattrs -cf /dev/null -T /dev/null 2>/dev/null; then tar_no_xattrs=--no-xattrs; fi
# Read probe uses a piped empty archive: GNU tar rejects /dev/null as input.
tar_quiet=
if tar -cf - -T /dev/null 2>/dev/null | tar --warning=no-unknown-keyword -tf - 2>/dev/null; then tar_quiet=--warning=no-unknown-keyword; fi
make_payload() {
  local build="$bd/build" h p parent vv known ft
  rm -rf "$build"; mkdir -p "$build/blobs" "$build/base"
  printf '2\n' > "$build/version"; cp "$state/replica" "$build/replica"
  cp "$state/manifest" "$bd/snapshot" || return 1
  : > "$build/manifest"; ignore_load
  : > "$build/features"
  for ft in ${share_features[@]+"${share_features[@]}"}; do printf '%s\n' "$ft" >> "$build/features"; done
  # A newly added ignore rule must also stop sending previously tracked paths.
  # Retain their local clocks; ignoring is not a replicated deletion.
  while IFS=$'\t' read -r p h parent vv; do
    ignored "$p" && continue
    printf '%s\t%s\t%s\t%s\n' "$p" "$h" "$parent" "$vv" >> "$build/manifest"
  done < "$state/manifest"
  { cut -f2 "$state/peer/$f.manifest" 2>/dev/null || true; } | LC_ALL=C sort -u > "$state/peer.hashes"
  awk -F '\t' 'FILENAME==ARGV[1]{k[$0]=1;next}{print $1 "\t" $2 "\t" $3 "\t" (($2 in k)?"known":"-")}' \
    "$state/peer.hashes" "$build/manifest" > "$build/sends"
  : > "$build/unsendable"
  while IFS=$'\t' read -r p h parent known; do
    if [ "$h" != - ] && [ "$known" != known ]; then
      # A lost local blob must not stop every later payload: restore it from an
      # identical working file, else leave that version out until rescanned.
      [ -f "$state/blobs/$h" ] || heal_blob "$p" "$h" ||
        { printf '%s\n' "$h" >> "$build/unsendable"; log "missing blob for $p; not sent until rescanned"; continue; }
      cp "$state/blobs/$h" "$build/blobs/$h" || return 1
    fi
    [ ! -f "$state/base/$parent" ] || cp "$state/base/$parent" "$build/base/$parent" || return 1
  done < "$build/sends"
  if [ -s "$build/unsendable" ]; then
    awk -F '\t' 'FILENAME==ARGV[1]{u[$0]=1;next}!($2 in u)' "$build/unsendable" "$build/manifest" > "$build/manifest.new" &&
      mv "$build/manifest.new" "$build/manifest" || return 1
  fi
  # macOS tar stores extended attributes (e.g. com.apple.provenance, set on new
  # files) as AppleDouble ._* members; a Linux peer refuses them as unknown.
  # COPYFILE_DISABLE covers the ._* members; --no-xattrs covers the xattr headers.
  COPYFILE_DISABLE=1 tar ${tar_no_xattrs:+"$tar_no_xattrs"} -cf "$bf.new" -C "$build" version replica manifest features blobs base && mv "$bf.new" "$bf"
}
receive_payload() {
  local archive="$1" entry p h parent vv src w x="$state/unpack"
  # Member names are validated first; content members are then unpacked in one
  # pass into a private directory (one read per member re-scanned the whole
  # archive each time). Only plain regular files are read: links, FIFOs and
  # devices are refused before any read. Hashes are validated, then renamed.
  tar ${tar_quiet:+"$tar_quiet"} -tf "$archive" > "$state/members" || return 1
  # Unknown members are skipped, never unpacked: a newer peer may send them.
  while IFS= read -r entry; do
    case "$entry" in version|replica|manifest|features|critical|ledger/*|blobs/|base/) ;;
      blobs/*|base/*) h="${entry#*/}"; [ "${#h}" = 64 ] || return 1; case "$h" in *[!0-9a-f]*) return 1;; esac;;
      *) log "skipping unknown payload member: $entry";;
    esac
  done < "$state/members"
  [ "$(tar ${tar_quiet:+"$tar_quiet"} -xOf "$archive" version)" = 2 ] || return 1
  # Features are read before any content is unpacked, so a refused payload
  # leaves no trace. Only plain files are read, as with content members.
  for p in features critical; do
    grep -qx "$p" "$state/members" || continue
    [ "$(tar ${tar_quiet:+"$tar_quiet"} -tvf "$archive" "$p" | cut -c1)" = - ] || return 1
    tar ${tar_quiet:+"$tar_quiet"} -xOf "$archive" "$p" > "$state/$p.raw" || return 1
    while IFS= read -r w || [ -n "$w" ]; do
      case "$w" in ''|'#'*) continue;; esac
      has_feature "$w" && continue
      if [ "$p" = critical ]; then log "peer requires feature $w; upgrade share"; return 1; fi
      log "skipping unknown feature $w"
    done < "$state/$p.raw"
  done
  tar ${tar_quiet:+"$tar_quiet"} -xOf "$archive" manifest > "$state/incoming.raw" || return 1
  awk -F '\t' 'NF!=4{exit 1}
    {for(i=2;i<=3;i++)if($i!="-"&&(length($i)!=64||$i~/[^a-f0-9]/))exit 1
     n=split($4,a,",");if(!n)exit 1;last=""
     for(i=1;i<=n;i++){if(split(a[i],b,":")!=2||b[1]!~/^[a-f0-9]+(~[A-Za-z0-9_.-]+)?$/||b[2]!~/^[0-9]+$/||length(b[2])>12||("x" b[1])<=("x" last))exit 1;last=b[1]}}' "$state/incoming.raw" || return 1
  : > "$state/incoming"; ignore_load
  rm -rf "$x"; mkdir "$x" || return 1
  tar ${tar_quiet:+"$tar_quiet"} -xf "$archive" -C "$x" blobs base || return 1
  while IFS=$'\t' read -r p h parent vv; do
    safe_path "$p" || return 1
    ignored "$p" && continue
    for entry in "blobs/$h" "base/$parent"; do
      [ "${entry#*/}" != - ] || continue
      src="$x/$entry"
      # Absent: not sent, or already moved in for an earlier row.
      [ -e "$src" ] || [ -L "$src" ] || continue
      [ ! -L "$src" ] && [ -f "$src" ] || return 1
      [ "$(hash_file "$src")" = "${entry#*/}" ] || return 1
      if [ "${entry%%/*}" = base ] && [ "$(wc -c < "$src")" -gt $((${SHARE_TEXT_MAX_KB:-1024}*1024)) ]; then rm -f "$src"; continue; fi
      mv "$src" "$state/$entry" || return 1
    done
    [ "$h" = - ] || [ -f "$state/blobs/$h" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$p" "$h" "$parent" "$vv" >> "$state/incoming"
  done < "$state/incoming.raw"
  rm -rf "$x"
  scan || return 1
  sync_merge "$state/manifest" "$state/incoming" > "$state/manifest.new" && mv "$state/manifest.new" "$state/manifest" || return 1
  cp "$state/incoming" "$state/peer/$f.manifest"
  materialize
}
