# README animations

`sync.gif` renders the real commands and output in `sync-session.json` as two
terminal panes. It is a captured command session, not a screen capture. Only home
paths and playback timing are changed. Setup uses pre-paired demo friends, two
isolated homes and a real local croc relay; both directions are checked by exact
file contents. The recorder stops its daemons and relay on exit. Do not run two
recorders simultaneously (demo friend names and relay ports are fixed).

From the repository root, with croc on PATH:

```sh
python3 .github/demos/record-sync.py
# Optional: DEMO_RELAY_PORT=49149 python3 .github/demos/record-sync.py
python3 -m venv /tmp/share-demo-venv
/tmp/share-demo-venv/bin/pip install Pillow==13.0.0
/tmp/share-demo-venv/bin/python .github/demos/render.py
```

Rendering uses DejaVu Sans Mono at the Linux path in `render.py`; adjust `FONT`
for other systems. Python/Pillow are documentation authoring tools, not share
runtime dependencies. Re-rendering does not need croc or any running daemon.

The two explanatory animations are diagrams, not terminal recordings. Their
text equivalents are in the README; final-frame PNGs provide static previews.
`sync-conflict.gif` uses actual SHA256s for its example content and filename.
The existing send/pull animation and its VHS scripts remain in `.github/`.
