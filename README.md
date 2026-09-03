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

## Commands

```
share tutorial                     guided tour in a sandbox
share push --friend NAME PATH...   send (blocks until they pull)
share pull --friend NAME [--dest]  receive (default ~/share/NAME; base movable via SHARE_PULL_DIR)
share friends                      who you can share with
share friends invite NAME          pair: prints a one-time code to tell them
share friends accept NAME CODE     other side of a pairing
share friends add NAME [SECRET]    register by hand
share code --friend NAME           today's code, for debugging
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
tools/tutorial   guided tour; real push/pull with yourself in a sandbox
```

Add a capability: drop an executable in `tools/` with a `# desc:` line. MIT.

## Future Improvements

Migrate to a seL4 formally verified shell language
