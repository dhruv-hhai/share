#!/usr/bin/env bash
# Pure state operations shared by the daemon and hermetic tests.
sync_merge() { LC_ALL=C sort -u "$@" | LC_ALL=C awk -f "$sync_lib/sync-merge.awk"; }
# Join clocks, optionally increment this replica. Sorted output is canonical.
sync_clock() {
  awk -F '\t' '{n=split($4,a,","); for(i=1;i<=n;i++){split(a[i],b,":"); if(b[2]+0>v[b[1]])v[b[1]]=b[2]+0}}
    END {for(r in v) print r "\t" v[r]}' | LC_ALL=C sort |
    awk -v rid="${1:-}" 'BEGIN{FS="\t"} {v[$1]=$2; names[++n]=$1}
      END{if(rid!=""){if(!(rid in v))names[++n]=rid;v[rid]++} for(i=1;i<=n;i++)print names[i] ":" v[names[i]]}' |
    LC_ALL=C sort | paste -sd, -
}
sync_conflict_name() {
  local p="$1" h="$2" name stem ext
  name="${p##*/}"; stem="$p"; ext=""
  case "$name" in ?*.*) stem="${p%.*}"; ext=".${p##*.}";; esac
  printf '%s.conflict-%.8s%s\n' "$stem" "$h" "$ext"
}
