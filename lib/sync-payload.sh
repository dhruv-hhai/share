#!/usr/bin/env bash
# The peer manifest is only a bandwidth hint. Missing bytes never enter state.
# shellcheck disable=SC2154,SC2034
make_payload() {
  local build="$bd/build" h p parent vv
  rm -rf "$build"; mkdir -p "$build/blobs" "$build/base"
  printf '2\n' > "$build/version"; cp "$state/replica" "$build/replica"
  cp "$state/manifest" "$bd/snapshot" || return 1
  : > "$build/manifest"; ignore_load
  # A newly added ignore rule must also stop sending previously tracked paths.
  # Retain their local clocks; ignoring is not a replicated deletion.
  while IFS=$'\t' read -r p h parent vv; do
    ignored "$p" && continue
    printf '%s\t%s\t%s\t%s\n' "$p" "$h" "$parent" "$vv" >> "$build/manifest"
  done < "$state/manifest"
  { cut -f2 "$state/peer/$f.manifest" 2>/dev/null || true; } | LC_ALL=C sort -u > "$state/peer.hashes"
  while IFS=$'\t' read -r p h parent vv; do
    if [ "$h" != - ] && ! grep -Fxq "$h" "$state/peer.hashes"; then
      cp "$state/blobs/$h" "$build/blobs/$h" || return 1
    fi
    [ ! -f "$state/base/$parent" ] || cp "$state/base/$parent" "$build/base/$parent" || return 1
  done < "$build/manifest"
  tar -cf "$bf.new" -C "$build" version replica manifest blobs base && mv "$bf.new" "$bf"
}
receive_payload() {
  local archive="$1" entry p h parent vv src
  # Never unpack paths or links from a peer. Read only named regular members
  # into our own temporary files, validate hashes, then rename into the store.
  tar -tf "$archive" > "$state/members" || return 1
  while IFS= read -r entry; do
    case "$entry" in version|replica|manifest|blobs/|base/) ;;
      blobs/*|base/*) h="${entry#*/}"; [ "${#h}" = 64 ] || return 1; case "$h" in *[!0-9a-f]*) return 1;; esac;;
      *) return 1;;
    esac
  done < "$state/members"
  [ "$(tar -xOf "$archive" version)" = 2 ] || return 1
  tar -xOf "$archive" manifest > "$state/incoming.raw" || return 1
  awk -F '\t' 'NF!=4{exit 1}
    {for(i=2;i<=3;i++)if($i!="-"&&(length($i)!=64||$i~/[^a-f0-9]/))exit 1
     n=split($4,a,",");if(!n)exit 1;last=""
     for(i=1;i<=n;i++){if(split(a[i],b,":")!=2||b[1]!~/^[a-f0-9]+$/||b[2]!~/^[0-9]+$/||length(b[2])>12||("x" b[1])<=("x" last))exit 1;last=b[1]}}' "$state/incoming.raw" || return 1
  : > "$state/incoming"; ignore_load
  while IFS=$'\t' read -r p h parent vv; do
    safe_path "$p" || return 1
    ignored "$p" && continue
    for entry in "blobs/$h" "base/$parent"; do
      [ "${entry#*/}" != - ] || continue
      if grep -Fxq "$entry" "$state/members"; then
        src="$state/received"
        tar -xOf "$archive" "$entry" > "$src" || return 1
        [ "$(hash_file "$src")" = "${entry#*/}" ] || return 1
        if [ "${entry%%/*}" = base ] && [ "$(wc -c < "$src")" -gt $((${SHARE_TEXT_MAX_KB:-1024}*1024)) ]; then rm -f "$src"; continue; fi
        mv "$src" "$state/$entry" || return 1
      fi
    done
    [ "$h" = - ] || [ -f "$state/blobs/$h" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$p" "$h" "$parent" "$vv" >> "$state/incoming"
  done < "$state/incoming.raw"
  scan || return 1
  sync_merge "$state/manifest" "$state/incoming" > "$state/manifest.new" && mv "$state/manifest.new" "$state/manifest" || return 1
  cp "$state/incoming" "$state/peer/$f.manifest"
  materialize
}
