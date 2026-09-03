# share

Send folders/files to friends using [croc](https://github.com/schollz/croc).

```sh
brew install croc
git clone https://github.com/dhruv-hhai/share ~/.share && ln -s ~/.share/share ~/.local/bin/share
share tutorial
```

A friend is an env var, same value on both machines: `export SHARE_SECRET_<NAME>="<passphrase>"`.

```sh
share push --friend sunny ./notes     # you; blocks until they pull
share pull --friend dhruv             # them; lands in ~/share/dhruv/
```

## Layout

```
share            dispatcher: exec tools/<cmd>; help = each tool's header
tools/code       sha256(SHARE_SECRET_<FRIEND>|date)[:24] — derived on both ends, rotates daily
tools/friends    env | grep SHARE_SECRET_
tools/pull       CROC_SECRET=$(code -f F) croc --yes --overwrite   (in ~/share/F)
tools/push       CROC_SECRET=$(code -f F) croc --yes send PATH...
tools/tutorial   guided tour; real push/pull with yourself in a sandbox
```

Add a capability: drop an executable in `tools/` with a `# desc:` line. MIT.
