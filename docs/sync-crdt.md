# CRDT design and specification corrections

The wire manifest is a sorted antichain of `(path, hash, parent, vector)`
records. Merge is set union followed by strict vector-dominance elimination.
Exact duplicate records collapse. This is associative, commutative and
idempotent on canonical states: removing a dominated element is permanent
because every future dominator of its dominator also dominates that element.

## Why identical hashes cannot join their clocks

For one path, use A = X/a:1, B = X/b:1, C = Y/a:1,b:1. Under the
specified identical-hash collapse, `(A merge B) merge C` retains X and Y;
`A merge (B merge C)` retains only Y: C strictly dominates A and B
individually but does not strictly dominate their joined clock.
Left retains X and Y;
right retains only Y. Tests preserve this counterexample. Independent
same-content records must remain distinct causal evidence, even though their
materialized bytes collapse to one file.

## Why materialization must not replace causal siblings

Resolving a subset of concurrent siblings by replacing them with a synthetic
joined clock can dominate another version that was not in that subset.
Arrival order then changes which content survives. The original siblings
remain the register state; the winner and conflict copies are a deterministic
view. Only an actual local edit, including an elected clean text merge,
increments a replica clock and supersedes observed siblings.

Internal helpers live in `lib/`, outside the CLI dispatcher, so pure merge
tests exercise the exact implementation without requiring croc or git.
