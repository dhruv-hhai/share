# share

Send files/folders across machines statelessly using [croc](https://github.com/schollz/croc).

Instant messaging & hosting platforms require personal identification to allow you to upload & share data on their servers. `share` needs neither: no account, no server that knows you, no state left behind — just a one-time code between two people.

```sh
brew tap dhruv-hhai/tap && brew install share
```

Or without Homebrew: `curl -fsSL https://raw.githubusercontent.com/dhruv-hhai/share/main/install | bash`.
Both bring [croc](https://github.com/schollz/croc) along. Then: `share tutorial`.

A file exchange needs a single secret exchange — nothing more, nothing less. Pairing does it for you over [croc](https://github.com/schollz/croc)'s PAKE, so no secret is ever typed or seen.

## End to end

Alice wants to keep sharing a folder with Bob, without a persistent connection between their machines.

1. **Alice invites Bob.** Prints a short one-time code:
   ```sh
   share friends invite bob
   ```
2. **Bob accepts.** Alice tells him the code any way she likes — it's single-use and PAKE-protected, so even a plaintext channel is fine:
   ```sh
   share friends accept alice <code>
   ```
3. **Alice pushes** her folder (waits until Bob pulls):
   ```sh
   share push --friend bob ./notes
   ```
4. **Bob pulls** (lands in `~/share/alice/`):
   ```sh
   share pull --friend alice
   ```

That's it. Repeat 3–4 whenever there's something new; Bob's copy gets overwritten.

## Commands

```
share friends                      who you can share with
share friends invite NAME          pair: prints a one-time code to tell them
share friends accept NAME CODE     other side of a pairing
share friends add NAME [SECRET]    register by hand
share push --friend NAME PATH...   send (blocks until they pull)
share pull --friend NAME [--dest]  receive (default ~/share/NAME)
share code --friend NAME           today's code, for debugging
share tutorial                     guided tour in a sandbox
```

Every command takes `--help`. The brew install checks for updates once a day and nudges `brew upgrade share`.

## Layout

```
share            dispatcher: exec tools/<cmd>; help = each tool's header
tools/code       today's croc code for a friend — derived on both ends, rotates daily, never sent
tools/friends    who you can share with; `invite`/`accept` pair, `add` registers by hand
tools/pull       receive from a friend
tools/push       send paths to a friend
tools/tutorial   guided tour; real push/pull with yourself in a sandbox
```

Add a capability: drop an executable in `tools/` with a `# desc:` line. MIT.
