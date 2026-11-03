# 2.0.0 release notes (proposed; not released)

`share sync` replaces local git bundles with portable shell file registers,
version vectors and SHA256-addressed current content. Concurrent edits produce
the same hash-named conflict copies on both peers; eligible nonoverlapping text
edits merge on one elected replica. Deletes propagate, with concurrent edits
winning over deletion. Old binary versions no longer accumulate in git packs.
The watchdog, progress-based transfer timeout, health commands, saved configs
and one-shot `push`/`pull` behavior are preserved.

**Upgrade both sides together.** This is a plain major release, not a
dual-protocol transition. Automatic updates will not cross from 1.x. Stop both
sync daemons, copy desired git exclusions into `.shareignore`, manually install
2.0.0 on both machines, then restart using the saved configurations. Incompatible
v1 payloads are refused with an upgrade-both-sides message.

The folder migrates automatically from its current working files. Existing
`.git` directories remain untouched and excluded. V2 adds `/.share/` to the
working `.gitignore` so a later v1 daemon will not commit v2 runtime state.

To roll back, stop both v2 daemons, reinstall 1.x on both sides and restart.
V1 resumes its retained history and commits edits made under v2 normally.
Keep `.git` until both peers run v2, backups have been verified, and rollback
and the old content history are no longer needed. Never delete `.share/` while
continuing to use v2.

New settings: `SHARE_TEXT_EXT`, `SHARE_TEXT_MAX_KB` and
`SHARE_SYNC_HEARTBEAT`. `SHARE_GC_PACKS` no longer applies. Status replaces git
dirty/unsent counts with pending entries, sibling paths and tombstones. History
is an append-only file-event log, not a content backup. See the README and
[design corrections and limits](sync-crdt.md), especially single-friend folder
locking, regular-file scope, and external-writer races.
