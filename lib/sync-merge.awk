# Canonical antichain of file versions. Input/output: path hash parent vv (TSV).
# Keep independent identical-content versions: joining their clocks is not an
# associative operation (docs/sync-crdt.md). Exact duplicate records collapse.
BEGIN { FS = OFS = "\t" }
function dominates(a, b,    x,y,n,i,k,strict) {
    split(a,x,","); split(b,y,",")
    for (k in av) delete av[k]
    for (k in bv) delete bv[k]
    for (i in x) { n=split(x[i],v,":"); av[v[1]]=v[2]+0 }
    for (i in y) { n=split(y[i],v,":"); bv[v[1]]=v[2]+0 }
    strict=0
    for (k in bv) if (av[k]+0 < bv[k]) return 0
    for (k in av) if (av[k] > bv[k]+0) strict=1
    return strict
}
function flush(    i,j,dead) {
    for (i=1;i<=count;i++) {
        dead=0
        for (j=1;j<=count;j++) if (i!=j && dominates(clock[j],clock[i])) { dead=1; break }
        if (!dead) print line[i]
    }
    count=0
}
$1 != path { flush(); path=$1 }
{ line[++count]=$0; clock[count]=$4 }
END { flush() }
