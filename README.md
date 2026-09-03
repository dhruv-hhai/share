# share

Send folders/files to friends using [croc](https://github.com/schollz/croc).

```sh
curl -fsSL https://raw.githubusercontent.com/dhruv-hhai/share/main/install | bash
```

Installs [croc](https://github.com/schollz/croc) if missing, clones this repo to `~/.share`, links `share` into `~/.local/bin`. Then: `share tutorial`.

A file exchange needs a single secret exchange — nothing more, nothing less.

## End to end

Alice wants to keep sharing a folder with Bob, without a persistent connection between their machines.

1. **Alice registers Bob.** Generates a secret (or pass your own three random words):
   ```sh
   share friends add bob
   ```
2. **Bob registers Alice.** Alice sends him the printed line over something they trust (Signal, in person):
   ```sh
   share friends add alice <secret>
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
tools/friends    who you can share with; `add` registers one
tools/pull       receive from a friend
tools/push       send paths to a friend
tools/tutorial   guided tour; real push/pull with yourself in a sandbox
```

Add a capability: drop an executable in `tools/` with a `# desc:` line. MIT.
