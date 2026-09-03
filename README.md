# share

Send folders/files to friends using [croc](https://github.com/schollz/croc).

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
