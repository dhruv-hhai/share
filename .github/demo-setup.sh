#!/bin/bash
# Side-by-side demo stage for the share README gif.
# Left pane: alice (this mac). Right pane: bob (ssh'd into analaya, hidden).
set -euo pipefail

tmux -L demo kill-server 2>/dev/null || true

D="$(mktemp -d)"
mkdir "$D/notes"
printf '# pad thai — the good recipe\n' > "$D/notes/recipe.md"
printf 'day 1247: still not enlightened\n' > "$D/notes/journal.md"

S="$(sed -n 's/^export SHARE_SECRET_ANALAYA="\(.*\)"$/\1/p' "$HOME/.zshrc")"

# fresh server, no user config: default prefix, no theming surprises
tmux -L demo -f /dev/null new-session -d -s demo -x 150 -y 34
tmux -L demo set -t demo status off
tmux -L demo set -t demo pane-border-style "fg=colour238"
tmux -L demo set -t demo pane-active-border-style "fg=colour238"

# left: alice
tmux -L demo send-keys -t demo:0.0 \
  "export SHARE_SECRET_BOB='$S'; cd $D; PROMPT='%F{81}[alice:66.65.73.62] >%f '; RPROMPT=''; clear" Enter

# right: bob (analaya) — ssh plumbing happens before the recording starts
tmux -L demo split-window -h -t demo
tmux -L demo send-keys -t demo:0.1 "ssh analaya" Enter
sleep 3
tmux -L demo send-keys -t demo:0.1 \
  "export SHARE_SECRET_ALICE='$S'; PS1='\[\e[38;5;215m\][bob:2.28.37.137] >\[\e[0m\] '; cd; rm -rf ~/share/alice; clear" Enter

tmux -L demo select-pane -t demo:0.0
