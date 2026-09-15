# share

Send files/folders across machines statelessly using [croc](https://github.com/schollz/croc). 

Assign dedicated sharing folders with folders.

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
   share sync status                  # every daemon: friend, role, pid, dir
   share sync log --friend bob        # daemon log: pushes/pulls as they happen
   share sync history --friend bob    # file-level audit: who, when, A/M/D per file
   share sync stop --friend bob       # kills the whole tree, croc included
   ```
   `--fg` runs it in the foreground instead (debugging). Daemons don't survive a reboot — rerun sync (or add it to cron/launchd).

Under the hood each side keeps a **local git repo** in the folder — the git *binary* only, no account, no remote, no network git; what travels over the relay is a git bundle. That buys real sync semantics:
- **nothing is ever dropped** — edits are committed before any merge, so a stale incoming copy can't overwrite your work
- concurrent edits to one text file (`*.md`/`*.txt`) merge as **append-both** (git union merge); same-line edits arrive as adjacent lines
- other file types that truly conflict keep **yours** in place and save **theirs** beside it as `NAME.conflict-<timestamp>`
- **deletes propagate**; full history sits in `.git` on each side (squash if it ever bothers you)
- a push only happens when there are new commits, and it blocks until received — that's the delivery ack

## Commands

```
share tutorial                     guided tour in a sandbox
share push --friend NAME PATH...   send (blocks until they pull)
share pull --friend NAME [--dest]  receive (default ~/share/NAME; base movable via SHARE_PULL_DIR)
share sync --friend NAME --role a|b [--dir DIR] [--every SEC] [--fg]
                                   two-way folder sync daemon (roles: one side a, other b)
share sync status|stop|log|history manage sync daemons; history = per-file audit trail
share friends                      who you can share with
share friends invite NAME          pair: prints a one-time code to tell them
share friends accept NAME CODE     other side of a pairing
share friends add NAME [SECRET]    register by hand
share code --friend NAME [--salt]  today's code, for debugging (salt = named room, used by sync)
```

Every step prints its gates: today's code (also usable as plain `croc <code>`), how long the relay holds an unclaimed room (~3h), and when the code rotates (UTC midnight — with a warning if that's imminent).

Every command takes `--help`. The brew install checks for updates once a day and nudges `brew upgrade share`.

State on disk, in full: one `export SHARE_SECRET_<NAME>=…` line per friend in your shell rc, and the files you pull. (croc itself keeps two small cache files in `~/.config/croc` — relay choice and version check.)

## Code Layout

```
share            dispatcher: exec tools/<cmd>; help = each tool's header
tools/code       today's croc code for a friend — derived on both ends, rotates daily, never sent
tools/friends    who you can share with; `invite`/`accept` pair, `add` registers by hand
tools/pull       receive from a friend
tools/push       send paths to a friend
tools/sync       continuous two-way folder sync — composes push/pull on salted rooms
tools/tutorial   guided tour; real push/pull with yourself in a sandbox
```

Add a capability: drop an executable in `tools/` with a `# desc:` line. MIT.

## Future Improvements

Migrate to a seL4 formally verified shell language
