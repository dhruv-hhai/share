#!/bin/bash
# Drives both panes of the demo tmux session with human-ish typing.
set -uo pipefail

tm() { tmux -L demo "$@"; }
type_into() {  # type_into PANE "command"
  local pane="$1" s="$2" i
  for ((i = 0; i < ${#s}; i++)); do
    tm send-keys -t "demo:0.$pane" -l -- "${s:$i:1}"; sleep 0.04
  done
  sleep 0.3; tm send-keys -t "demo:0.$pane" Enter
}
wait_for() {  # wait_for PANE "regex" [timeout]
  local pane="$1" re="$2" t="${3:-30}" i
  for ((i = 0; i < t * 5; i++)); do
    tm capture-pane -p -t "demo:0.$pane" | grep -qE "$re" && return 0
    sleep 0.2
  done
  return 1
}

sleep 3.5                                    # vhs attaches

# 1. what alice wants to send
type_into 0 "ls notes/";                      sleep 2

# 2. pair — invite on alice, one-time code appears
type_into 0 "share friends invite bob"
wait_for 0 'share friends accept alice [a-z0-9-]+' 30
code="$(tm capture-pane -p -t demo:0.0 | grep -oE 'share friends accept alice [a-z0-9-]+' | tail -1 | awk '{print $NF}')"
sleep 2.5                                     # let the viewer read the code

# 3. bob accepts with the code (PAKE over the relay)
tm select-pane -t demo:0.1
type_into 1 "share friends accept alice $code"
wait_for 1 "added alice" 30;                  sleep 1
type_into 1 "source ~/.bashrc";               sleep 1

# 4. alice's side registered too — load it and push
tm select-pane -t demo:0.0
wait_for 0 "added bob" 15
type_into 0 "source ~/.zshrc";                sleep 1
type_into 0 "share push --friend bob ./notes"
wait_for 0 'waiting for bob to pull' 20;      sleep 2.5

# 5. bob pulls
tm select-pane -t demo:0.1
type_into 1 "share pull --friend alice"
wait_for 1 'recipe\.md.*100%' 40;             sleep 1.5
type_into 1 "ls share/alice/notes/";          sleep 2

# 6. end on alice's completed push
tm select-pane -t demo:0.0;                   sleep 2
ssh analaya 'sed -i "/# demo-prompt/d" ~/.bashrc' 2>/dev/null || true
touch /tmp/demo-done
