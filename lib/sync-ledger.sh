#!/usr/bin/env bash
# shellcheck disable=SC2154 # $state is the caller's
# Per-writer hash chains of TSV entries in $state/ledger/<rid>/<name>.log.
# Needs sync-files.sh (hash_file) and the daemon's log(); holds no state itself.

ledger_file() {
  local r="${1%%/*}" n="${1#*/}"
  case "$1" in */*) ;; *) return 1;; esac
  case "$r" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac
  case "$n" in ''|*[!A-Za-z0-9_.-]*) return 1;; esac
  printf '%s/ledger/%s/%s.log\n' "$state" "$r" "$n"
}

# Peek at the next hlc for WRITER; nothing is reserved until ledger_append.
ledger_hlc() {
  local f last ls lc sec cnt
  f="$(ledger_file "$1")" || return 1
  sec="$(date +%s)"; cnt=0
  if [ -s "$f" ]; then
    last="$(tail -n 1 "$f" | cut -f3)"
    ls=$((10#${last:0:10})); lc=$((10#${last:10:6}))
    # A last entry stamped ahead of our clock (peer skew): keep its second, count on.
    if [ "$ls" -ge "$sec" ]; then sec=$ls; cnt=$((lc + 1)); fi
  fi
  printf '%010d%06d\n' "$sec" "$cnt"
}

# ledger_append WRITER KIND SUBJECT [DATA...]: prints the new entry's id.
# Read prev, take hlc and append under one flock: concurrent appenders would
# otherwise read the same prev and fork their own chain. The kernel drops the
# lock when the subshell exits, so a killed appender never leaves it held.
ledger_append() {
  local f lk prev hlc rest id x writer kind subj
  [ $# -ge 3 ] && [ -n "$2" ] || return 1
  for x in "$@"; do case "$x" in *$'\t'*|*$'\n'*) return 1;; esac; done
  f="$(ledger_file "$1")" || return 1
  writer="$1"; kind="$2"; subj="$3"; shift 3
  mkdir -p "$(dirname "$f")"
  lk="${f%.log}.lock"
  (
    flock 9 || exit 1
    prev=-
    if [ -s "$f" ]; then prev="$(tail -n 1 "$f" | cut -f1)"; fi
    hlc="$(ledger_hlc "$writer")"
    rest="$prev"$'\t'"$hlc"$'\t'"$writer"$'\t'"$kind"$'\t'"$subj"
    while [ $# -gt 0 ]; do rest="$rest"$'\t'"$1"; shift; done
    id="$(printf '%s' "$rest" | openssl dgst -sha256 | sed 's/.*= //')"
    printf '%s\t%s\n' "$id" "$rest" >> "$f"
    printf '%s\n' "$id"
  ) 9> "$lk"
}

# Sorted union of all chains, optionally one kind. Ties on hlc break on writer.
ledger_lines() {
  local f
  for f in "$state"/ledger/*/*.log; do
    [ -f "$f" ] || continue
    cat "$f"
  done | LC_ALL=C sort -t$'\t' -k3,3 -k4,4 |
    LC_ALL=C awk -F '\t' -v k="${1:-}" 'k == "" || $5 == k'
}

# Recompute ids, check prev links and report forks. Prints problems; nonzero if any.
ledger_verify() {
  local f base ln line id rest prev r2 r3 writer hash last tmp fk bad=0
  tmp="$(mktemp)"
  for f in "$state"/ledger/*/*.log; do
    [ -f "$f" ] || continue
    base="${f##*/}"; ln=0; last=-
    while IFS= read -r line || [ -n "$line" ]; do
      ln=$((ln + 1))
      id="${line%%$'\t'*}"; rest="${line#*$'\t'}"
      prev="${rest%%$'\t'*}"; r2="${rest#*$'\t'}"; r3="${r2#*$'\t'}"; writer="${r3%%$'\t'*}"
      hash="$(printf '%s' "$rest" | openssl dgst -sha256 | sed 's/.*= //')"
      if [ "$hash" != "$id" ]; then echo "bad-id $f $ln"; bad=$((bad + 1)); fi
      # A fork file starts at the fork point, so its first prev is not in this file; fork detection covers it.
      if [ "$ln" -eq 1 ]; then
        case "$base" in
          *.fork-*) ;;
          *) if [ "$prev" != - ]; then echo "bad-prev $f $ln"; bad=$((bad + 1)); fi;;
        esac
      elif [ "$prev" != "$last" ]; then
        echo "bad-prev $f $ln"; bad=$((bad + 1))
      fi
      last="$id"
      printf '%s\t%s\t%s\t%s\t%s\n' "$writer" "$prev" "$id" "$f" "$ln" >> "$tmp"
    done < "$f"
  done
  # Same writer and prev with a different id is a fork; a shared prefix repeats the same id.
  fk="$(LC_ALL=C awk -F '\t' '{k = $1 SUBSEP $2; if (k in seen) {if (seen[k] != $3) print "fork", $4, $5} else seen[k] = $3}' "$tmp")"
  if [ -n "$fk" ]; then
    printf '%s\n' "$fk"
    bad=$((bad + $(printf '%s\n' "$fk" | wc -l)))
  fi
  rm -f "$tmp"
  [ "$bad" -eq 0 ]
}

# Take INCOMING as LOCAL when it extends it; a stale peer keeps LOCAL; else keep it as a fork file.
ledger_accept() {
  local local_f="$1" incoming="$2" n base h dest
  mkdir -p "$(dirname "$local_f")"
  if [ ! -e "$local_f" ]; then cp "$incoming" "$local_f.new"; mv "$local_f.new" "$local_f"; return 0; fi
  cmp -s "$incoming" "$local_f" && return 0
  n="$(wc -c < "$local_f" | tr -d ' ')"
  if head -c "$n" "$incoming" | cmp -s - "$local_f"; then
    cp "$incoming" "$local_f.new"; mv "$local_f.new" "$local_f"; return 0
  fi
  n="$(wc -c < "$incoming" | tr -d ' ')"
  if head -c "$n" "$local_f" | cmp -s - "$incoming"; then
    log "ledger: peer behind on ${local_f##*/}"; return 0
  fi
  base="${local_f##*/}"; base="${base%.log}"
  h="$(hash_file "$incoming")"
  dest="$(dirname "$local_f")/$base.fork-${h:0:8}.log"
  cp "$incoming" "$dest.new"; mv "$dest.new" "$dest"
  log "ledger fork: ${dest##*/}"
}

# Derive $state/leases.idx from lease kinds: one live lease per glob. A claim takes a
# glob only when it is free, already the claimer's, or expired by the claim's own hlc
# second, so two writers racing for a live lease keep the first claim on every replica.
project_leases() {
  local out="$state/leases.idx"
  ledger_lines | LC_ALL=C awk -F '\t' '
    $5 ~ /^lease-/ {
      g = substr($6, 6)
      if ($5 == "lease-claim") {
        if (!live[g] || w[g] == $4 || e[g] + 0 <= substr($3, 1, 10) + 0) { live[g] = 1; w[g] = $4; e[g] = $7 + 0; p[g] = $8; c[g] = $1 }
      } else if ($5 == "lease-renew") {
        if (live[g] && w[g] == $4 && $7 + 0 > e[g] + 0) e[g] = $7 + 0
      } else if ($5 == "lease-release" || $5 == "lease-lost") {
        if (live[g] && w[g] == $4) live[g] = 0
      }
    }
    END { for (g in live) if (live[g]) printf "%s\t%s\t%d\t%s\t%s\n", g, w[g], e[g], p[g], c[g] }' |
    LC_ALL=C sort > "$out.new"
  mv "$out.new" "$out"
}
