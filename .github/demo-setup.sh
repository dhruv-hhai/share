#!/bin/bash
# Stage for the share README gif — full honest flow, no pre-shared secrets.
# Left pane: alice (this mac, sandboxed HOME). Right pane: bob (analaya over ssh).
# All typing is driven by demo-orchestrator.sh; vhs only films.
set -euo pipefail

tmux -L demo kill-server 2>/dev/null || true
pkill -f "croc --yes" 2>/dev/null || true
rm -f /tmp/demo-done

# alice's sandbox: fresh rc, demo files, fake whoami so invite says "alice"
D="/tmp/alice"
rm -rf "$D"; mkdir -p "$D/notes" "$D/bin"
printf '# pad thai — the good recipe\n' > "$D/notes/recipe.md"
printf 'day 1247: still not enlightened\n' > "$D/notes/journal.md"
printf '#!/bin/sh\necho alice\n' > "$D/bin/whoami"; chmod +x "$D/bin/whoami"
echo "$D" > /tmp/demo-dir

# bob's side: clean slate for the pairing
# bob: clean slate + keep the demo prompt across `source ~/.bashrc`
# (ubuntu's bashrc sets PS1 mid-file; our line at the end wins)
ssh analaya 'sed -i "/SHARE_SECRET_ALICE/d;/# demo-prompt/d" ~/.bashrc; printf "PS1='\''\\[\\e[38;5;215m\\][bob:2.28.37.137] >\\[\\e[0m\\] '\'' # demo-prompt\n" >> ~/.bashrc; rm -rf ~/share/alice; pkill -x croc 2>/dev/null; true'

tmux -L demo -f /dev/null new-session -d -s demo -x 150 -y 34
tmux -L demo set -t demo status off
tmux -L demo set -t demo pane-border-style "fg=colour238"
tmux -L demo set -t demo pane-active-border-style "fg=colour238"

tmux -L demo send-keys -t demo:0.0 \
  "export HOME=$D PATH=$D/bin:\$PATH; cd $D; PROMPT='%F{81}[alice:66.65.73.62] >%f '; RPROMPT=''; clear" Enter

tmux -L demo split-window -h -t demo
tmux -L demo send-keys -t demo:0.1 "ssh analaya" Enter
sleep 3
tmux -L demo send-keys -t demo:0.1 "cd; clear" Enter

tmux -L demo select-pane -t demo:0.0
nohup bash "$(dirname "$0")/demo-orchestrator.sh" >/tmp/orch.log 2>&1 &
