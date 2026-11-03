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
Tests preserve this counterexample. Independent
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

## Storage and materialization

`manifest` stores the canonical antichain. `observed` records the versions
actually materialized locally; a skipped write must not grant an editor causal
knowledge of unseen incoming content. `cache` records the materialized stat
tuple and hash. Current blobs are retained by manifest/cache references and
reclaimed after each round. Conflict copies are derived views, not synthetic
edits. Editing a conflict copy makes it an ordinary independent path.

Text bases retain current live text hashes and their immediate parents (each
limited by `SHARE_TEXT_MAX_KB`), rather than exactly one base per path. Two
concurrent branches need their shared parent until the elected merge finishes.
There is no growth per historical version; unresolved siblings and tombstones
remain until superseded by an observed local edit. History is a metadata audit
log, not a content backup.

The main daemon remains below 400 lines; filesystem, payload and pure algebra
helpers are separate because combining them would obscure the unchanged
watchdog. The Homebrew formula renderer installs `lib/` alongside `tools/`.

## Operational deviations and limits

* The existing per-friend lock and stale-lock recovery remain unchanged. Run
  only one friend daemon per folder. Multi-friend folder locking is deferred.
* A migration adds `/.share/` to the working `.gitignore` so rollback does not
  commit v2's replica identity or cache. No file within `.git` is touched.
* A generated conflict name already occupied by a real manifest path gets a
  deterministic full-hash suffix; repeated collisions repeat that suffix.
* Stat caching rehashes recent files because stock BSD stat has only seconds
  precision. Every apply also verifies the destination hash before replacing
  it. Portable shell has no atomic compare-and-swap for filenames: an external
  writer can still race the final check and rename. Applications should finish
  atomic saves before stopping sync; backups remain necessary.
* Only regular files sync. Symlinks and paths crossing symlink parents are
  refused. File-versus-directory conflicts are deferred in place; they need
  manual renaming before the affected paths can converge.
* Text election uses the lowest replica ID in the sibling clocks. With two
  peers it is deterministic. After permanently retiring that replica, text
  falls back to deterministic conflict copies until a user edits the file.
* No dependency was added. `diff3` is optional (without it, conflict copies);
  the engine never uses a git merge fallback. Git is used only by rollback
  tests and the existing installation/version infrastructure.
