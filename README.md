# share

Send folders/files to friends using [croc](https://github.com/schollz/croc).

```sh
brew install croc
git clone https://github.com/dhruv-hhai/share ~/.share && ln -s ~/.share/share ~/.local/bin/share
share tutorial
```

A file exchange needs a single secret exchange — nothing more, nothing less.

## End to end

Say you want to keep sharing a folder or file with a friend, without a persistent connection between your machines.

1. **Pick a secret** — three random words is plenty (`share push` suggests one) — and send it over something you trust (Signal, in person).
2. **Register each other.** You name them, they name you, same secret:
   ```sh
   echo 'export SHARE_SECRET_SUNNY="<secret>"' >> ~/.zshrc && source ~/.zshrc   # you
   echo 'export SHARE_SECRET_DHRUV="<secret>"' >> ~/.zshrc && source ~/.zshrc   # them
   ```
3. **Push** your file or dir (waits until they pull):
   ```sh
   share push --friend sunny ./notes
   ```
4. **Pull** from the other side (lands in `~/share/dhruv/`):
   ```sh
   share pull --friend dhruv
   ```

That's it. Repeat 3–4 whenever there's something new; their copy gets overwritten.

## Layout

```
share            dispatcher: exec tools/<cmd>; help = each tool's header
tools/code       today's croc code for a friend — derived on both ends, rotates daily, never sent
tools/friends    who you can share with
tools/pull       receive from a friend
tools/push       send paths to a friend
tools/tutorial   guided tour; real push/pull with yourself in a sandbox
```

Add a capability: drop an executable in `tools/` with a `# desc:` line. MIT.
