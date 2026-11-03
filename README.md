# share

Send files/folders across machines statelessly using [croc](https://github.com/schollz/croc). 

Assign dedicated sharing folders with friends.

# Installation & dependencies

Dependencies
- [croc](https://github.com/schollz/croc) 
- unix shell

1. Mac OS Installation

```sh macos
brew tap dhruv-hhai/tap && brew install share
```

2. Unix Installation

```sh unix
curl -fsSL https://raw.githubusercontent.com/dhruv-hhai/share/main/install | bash
```

## Guided tutorial in CLI

```sh
share tutorial
```

## Example Quickstart 

![share push on one machine, share pull on another — a real transfer with the gates printed](.github/share.gif)

## Full walkthrough 

1. Generate an invite code for your friend 
   ```sh
   share friends invite bob
   ```
2. They accept with the code — it's single-use and PAKE-protected, so tell them over any channel
   ```sh
   share friends accept alice <code>
   ```
3. Push them a folder — waits until they pull
   ```sh
   share push --friend bob ./notes
   ```
4. They pull — lands in `~/share/alice/`
   ```sh
   share pull --friend alice
   ```

That's it. Pair once (1–2), then repeat 3–4 whenever there's something new; their copy gets overwritten.

## Auto-sync (two-way)

Keep one folder mirrored between two machines, continuously — picking up where the walkthrough left off: alice's `./notes`, which bob's pull landed in `~/share/alice/`. Both sides run `sync` against their copy; edits propagate in seconds.

1. Agree roles once, over any channel — one of you is `a`, the other is `b`. It's a coin flip: the letters just keep the two directions in separate relay rooms (both pushing into one room breaks it — every pull gets `relay admission rejected`).
2. Each side starts it — it goes to the background on its own:
   ```sh
   # alice — her original folder
   share sync --friend bob --role a --dir ./notes
   # bob — his pulled copy (the default: ~/share/<friend>/, movable via SHARE_PULL_DIR)
   share sync --friend alice --role b
   ```
3. Manage it:
   ```sh
   share sync status                  # every daemon: friend, role, health verdict, pid, dir
   share sync check [--friend bob]    # same, with an exit code (0 = fine) — cron it; --repair restarts the sick
   share sync restart --friend bob    # stop + start from the saved config (role/dir remembered per friend)
   share sync log --friend bob        # daemon log: pushes/pulls/resets as they happen
   share sync history --friend bob    # file-level audit: who, when, A/M/D per file
   share sync stop --friend bob       # kills the whole tree, croc included
   ```
   `--fg` runs it in the foreground instead (debugging). Daemons don't survive a reboot, but the config does: `share sync --friend bob` (no `--role`) brings one back, and `*/5 * * * * share sync check --repair` in cron brings them all back.

   **Health.** Verdicts are `ok`, `waiting-peer` (a push is open at the relay until they come online — normal), `sending` (they connected and the transfer is moving), `stuck` (heartbeat stopped, stale lock, a waiting push far past its cap, or a transfer with no progress — restart it), `down` (configured but not running). The daemon's own watchdog fixes what it can in place: respawns a dead loop, reopens a push still *waiting* longer than `SHARE_PUSH_MAX` seconds (default 7200 — relays drop unclaimed rooms after ~3h) or one opened before the UTC-midnight code rotation, reopens a *transfer* only when it shows no progress for `SHARE_PUSH_STALL` seconds (default 900 — a big folder on a slow link is never cut off just for taking long), reconnects after a sleep/wake clock jump, breaks a lock held over 10 minutes, and versions your edits on its own tick so a blocked push never holds them hostage. Every reset is a log line.

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
- **Deletes propagate**, but concurrent edits win over deletion. Tombstones
  remain so an old payload cannot resurrect a causally deleted file.
- **Ignores:** `.share/` and `.git/` are always excluded. Defaults also exclude
  `.DS_Store`, `*.swp`, `*~`, `.~lock*`, `~$*`, `.syncthing.*` and
  `*.tmp-share-*`. A synced `.shareignore` accepts one Bash glob per line
  (full relative path or basename); blank/comment lines are ignored and a
  trailing `/` excludes a directory tree. Git ignore rules are not imported:
  copy any desired v1 exclusions into `.shareignore` before upgrading.
- **Local edits are scanned before applying incoming state.** Each replacement
  checks the cached stat and content hash, then writes a same-directory temp
  file and renames it. A changed destination is deferred. External writers
  can still race the final check/rename; sync is not a historical backup.
- **Storage is bounded by current content and conflicts**, not every binary
  version ever written. Large files are logged during scanning. A disk fence
  requires 2× the incoming tar size plus the configured reserve before reading
  its contents. Peer manifests omit already-known blobs as an optimization;
  missing blobs are retried on the next state exchange.

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
rename. See [design corrections and limits](docs/sync-crdt.md).

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

## Commands

```
share tutorial                     guided tour in a sandbox
share push --friend NAME PATH...   send (blocks until they pull)
share pull --friend NAME [--dest]  receive (default ~/share/NAME; base movable via SHARE_PULL_DIR)
share sync --friend NAME --role a|b [--dir DIR] [--every SEC] [--fg]
                                   two-way folder sync daemon (roles: one side a, other b)
share sync status|check|restart|stop|log|history
                                   manage sync daemons; check = health + exit code (--repair fixes); history = per-file audit
share friends                      who you can share with
share friends invite NAME          pair: prints a one-time code to tell them
share friends accept NAME CODE     other side of a pairing
share friends add NAME [SECRET]    register by hand
share code --friend NAME [--salt]  today's code, for debugging (salt = named room, used by sync)
share update [--check|--installed] same-major self-update (runs daily on its own; see Updates)
```

Every step prints its gates: today's code (also usable as plain `croc <code>`), how long the relay holds an unclaimed room (~3h), and when the code rotates (UTC midnight — with a warning if that's imminent).

Every command takes `--help`.

## Updates

`share` updates itself. Once a day (on any command, and from inside each sync daemon) it looks at the newest tag on GitHub and, if it is the **same major version**, applies it in the background — `brew upgrade share` for the brew install, `git pull` for the curl install. Running sync daemons re-exec onto the new version within a minute, same pid, nothing lost. A **major** bump is never applied automatically: it changes the sync payload, so both sides upgrade together by hand — the daily check just says so. `share update --check` shows where you stand, `share update` applies now, `SHARE_AUTO_UPDATE=0` opts out.

State on disk: a friend secret in your shell rc, pulled files, per-friend saved sync configurations, and per-folder `.share/` state. (croc itself keeps two small cache files in `~/.config/croc` — relay choice and version check.)

## Code Layout

```
share            dispatcher: exec tools/<cmd>; help = each tool's header
tools/code       today's croc code for a friend — derived on both ends, rotates daily, never sent
tools/friends    who you can share with; `invite`/`accept` pair, `add` registers by hand
tools/pull       receive from a friend
tools/push       send paths to a friend
tools/sync       continuous two-way folder sync — composes push/pull on salted rooms
tools/tutorial   guided tour; real push/pull with yourself in a sandbox
tools/update     same-major self-update; latest = newest tag on GitHub; daemons re-exec to follow it
test/sync-e2e    two daemons over a local relay: round trips, verdicts, repair, watchdog resets (CI runs it)
```

Add a capability: drop an executable in `tools/` with a `# desc:` line. MIT.

## Future Improvements

Migrate to a seL4 formally verified shell language
