# Sync reference

[← README](../README.md)

## Commands

```sh
share sync status
share sync check --friend bob          # health + exit code
share sync check --repair              # restart unhealthy saved configurations
share sync restart --friend bob        # reuse the saved role and folder
share sync log --friend bob
share sync history --friend bob        # activity, not restore points
share sync stop --friend bob
share sync --friend bob                # resume after stop or reboot
```

Use `--fg` to run in the foreground or `--every SEC` to set the scan interval.
Daemons do not survive reboot. To check and recover saved configurations from
cron: `*/5 * * * * share sync check --repair` (ensure share and croc are on PATH).

## Health

Verdicts are `ok`, `waiting-peer` (a push is open at the relay until they come online — normal), `sending` (they connected and the transfer is moving), `stuck` (heartbeat stopped, stale lock, a waiting push far past its cap, or a transfer with no progress — restart it), `down` (configured but not running). The daemon's own watchdog fixes what it can in place: respawns a dead loop, reopens a push still *waiting* longer than `SHARE_PUSH_MAX` seconds (default 7200 — relays drop unclaimed rooms after ~3h) or one opened before the UTC-midnight code rotation, reopens a *transfer* only when it shows no progress for `SHARE_PUSH_STALL` seconds (default 900 — a big folder on a slow link is never cut off just for taking long), reconnects after a sleep/wake clock jump, breaks a lock held over 10 minutes, and versions your edits on its own tick so a blocked push never holds them hostage. Every reset is a log line.

## Versions, conflicts and storage

The v2 engine uses **file-level causal registers** in `.share/`, with no git
dependency for sync. Version vectors distinguish later edits from concurrent
ones; full-state manifests can be lost, repeated or delivered out of order.
Only current content, text merge bases and in-flight payloads are retained.

- **Concurrent edits converge:** the highest SHA256 hash wins the original
  path. Each other version becomes `name.conflict-<8 hash chars>.ext` on both
  sides. Identical bytes produce one visible file. Editing the original after
  observing the conflict supersedes its siblings.
- **Text merging:** `.md`, `.txt` and `SHARE_TEXT_EXT` extensions may merge with
  `diff3` when exactly two versions have a shared retained parent. The lowest
  replica ID performs a clean merge; overlapping edits keep conflict copies.
- **Merge strategies:** a synced `.sharemerge` picks the strategy per path, one
  `<glob> <strategy>` per line (globs as in `.shareignore`, first match wins,
  `#` comments). Unmatched paths keep the defaults above.

  ```
  *.jsonl      union-lines      # append-only logs
  *.json       json-merge
  src/*        lease
  *.lock       cmd:lockfile     # ~/.config/share/merge/lockfile
  ```

  | Strategy | Two concurrent edits of one parent become |
  | --- | --- |
  | `diff3` | a clean line merge, else conflict copies (default for text) |
  | `union-lines` | one side, plus lines the other side added that it did not also add; the other side's deletions are not applied |
  | `json-merge` | a key-level three-way merge of one JSON value per file (needs `jq`; output is reformatted); a key changed differently on both sides keeps conflict copies |
  | `conflict-copies` | conflict copies, never merged (default for non-text) |
  | `lease` | conflict copies plus one record per sibling set in `.share/collisions` (`time path hashes`) and an `L` history event, for whatever enforces leases |
  | `cmd:NAME` | the stdout of the local executable `${XDG_CONFIG_HOME:-~/.config}/share/merge/NAME BASE FIRST SECOND PATH`; nonzero exit keeps conflict copies |

  Only the elected replica runs a strategy and its result is an ordinary new
  version, so both sides converge on it even if their drivers differ. Drivers
  are never synced: a peer's `.sharemerge` can name one but not supply it.
  Unknown strategies are logged once and keep conflict copies. Merge bases are
  retained (up to `SHARE_TEXT_MAX_KB`) for every path whose strategy merges.
- **Deletes propagate**, but concurrent edits win over deletion. Tombstones
  remain so an old payload cannot resurrect a causally deleted file.
- **Ignores:** `.share/` and `.git/` are always excluded. Defaults also exclude
  `.DS_Store`, `*.swp`, `*~`, `.~lock*`, `~$*`, `.syncthing.*` and
  `*.tmp-share-*`. A synced `.shareignore` accepts one Bash glob per line
  (full relative path or basename); blank/comment lines are ignored and a
  trailing `/` excludes a directory tree at that root path. Unlike Git, `*`
  also matches `/` and there is no `!` negation; exclude a directory name at
  any depth with `name/*` plus `*/name/*`. Directories whose every path is
  ignored are pruned from the scan, so large ignored trees cost nothing.
  Git ignore rules are not imported: copy any desired v1 exclusions into
  `.shareignore` before upgrading.
- **Local edits are scanned before applying incoming state.** Each replacement
  checks the cached stat and content hash, then writes a same-directory temp
  file and renames it. A changed destination is deferred. External writers
  can still race the final check/rename; sync is not a historical backup.
- **Storage is bounded by current content and conflicts**, not every binary
  version ever written. Large files are logged during scanning. A disk fence
  requires 2× the incoming tar size plus the configured reserve before reading
  its contents. Peer manifests omit already-known blobs as an optimization;
  missing blobs are retried on the next state exchange.
- **Lenient payloads:** receive skips unknown members and unknown non-critical
  `features` with a log line, and never unpacks them. A `critical` feature this
  build lacks refuses the whole payload before any state changes.
- **Features:** every payload carries a `features` member (one word per line,
  empty until a build advertises one). Envelope `version` stays `2`; new
  members start only once both peers advertise them.

`status` reports pending entries, paths with causal siblings, and tombstones.
Siblings can remain after deterministic conflict materialization until an
actual edit supersedes them. `history` reads the `.share/history` event log;
it does not restore old content. Keep ordinary backups.

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `SHARE_TEXT_EXT` | empty | Extra space-separated extensions, e.g. `csv rst` |
| `SHARE_TEXT_MAX_KB` | `1024` | Maximum size of each retained text base |
| `SHARE_SYNC_HEARTBEAT` | `180` | Seconds between unchanged-state retries |
| `SHARE_PUSH_MAX` | `7200` | Waiting-peer cap, seconds |
| `SHARE_PUSH_STALL` | `900` | Transfer no-progress cap, seconds |
| `SHARE_DISK_RESERVE_MB` | `1024` | Free-space reserve |
| `SHARE_BIG_MB` | `20` | Large-file warning threshold |
| `SHARE_PULL_DIR` | `~/share` | Default parent of friend folders |
| `SHARE_AUTO_UPDATE` | `1` | Set `0` to disable automatic same-major updates |
| `SHARE_FOLLOW_EVERY` | `60` | Installed-version polling interval, seconds |

Only regular files sync; tab/newline names are skipped with a logged warning.
Use one friend daemon per folder. File/directory collisions require a manual
rename. See [design corrections and limits](sync-crdt.md).

### Upgrade from 1.x and rollback

**2.0.0 is a major release: upgrade both sides together by hand.** Automatic
updates never cross the major boundary. Stop both daemons, transfer desired
ignore globs from `.gitignore` into `.shareignore`, install v2 on both sides,
then restart with the saved configurations. A v1 peer is refused loudly.

The current folder migrates automatically. Its `.git` is left untouched and
excluded; v2 adds `/.share/` to the working `.gitignore` for safe rollback.
To roll back, stop both v2 daemons, reinstall 1.x on both sides and restart.
V1 resumes its old history and commits changes made under v2 as ordinary edits.
Do not delete `.share/` while using v2: it contains the replica identity and
causal state. Delete the old `.git` only after both sides run v2, backups are
verified and you no longer need the v1 history or rollback.


## Updates

`share` updates itself. Once a day (on any command, and from inside each sync daemon) it looks at the newest tag on GitHub and, if it is the **same major version**, applies it in the background — `brew upgrade share` for the brew install, `git pull` for the curl install. Running sync daemons re-exec onto the new version within a minute, same pid, nothing lost. A **major** bump is never applied automatically: it changes the sync payload, so both sides upgrade together by hand — the daily check just says so. `share update --check` shows where you stand, `share update` applies now, `SHARE_AUTO_UPDATE=0` opts out.

State on disk: a friend secret in your shell rc, pulled files, per-friend saved sync configurations, and per-folder `.share/` state. (croc itself keeps two small cache files in `~/.config/croc` — relay choice and version check.)

