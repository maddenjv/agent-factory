#!/usr/bin/env bash
# Start everything: Dolt, then a tmux session with an "agents" window (the board + all 5 roles as
# panes, tiled) and a separate "ops" window for the interactive shell you type into (each
# pane/window backed by its own container).
# Run this from the ROOT OF THE PROJECT you want agent-factory to work on (see bin/lib.sh).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SESSION=${SESSION:-factory}
ROLES=(po architect qa engineer reviewer)
WIN=agents

dc up -d dolt
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Already running: tmux attach -t $SESSION"; exit 0
fi
rm -f "$DATA_DIR/control/STOP" "$DATA_DIR"/control/STOP.*

pane() {  # pane <title> <role> <bash-args...>  - first call creates the window, rest split it
  local title=$1 role=$2; shift 2
  # PROJECT_DIR/KIT_DIR spelled out explicitly (not relied on via tmux's environment inheritance)
  # so this is correct even if the pane gets torn down and respawned later from a different shell.
  local cmd="PROJECT_DIR='$PROJECT_DIR' KIT_DIR='$KIT_DIR' ROLE=$role docker compose -f '$KIT_DIR/docker-compose.yml' run --rm --name factory-$title $*"
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -n "$WIN" "$cmd"
  else
    tmux split-window -t "$SESSION:$WIN" "$cmd"
    tmux select-layout -t "$SESSION:$WIN" tiled >/dev/null
  fi
  tmux select-pane -t "$SESSION:$WIN" -T "$title"
}

pane board shell --entrypoint bash agent "$KIT_DIR/bin/board.sh"
for r in "${ROLES[@]}"; do pane "$r" "$r" agent; done

tmux set-option -w -t "$SESSION:$WIN" remain-on-exit on   # keep a pane (and its last output) if its agent dies
tmux set-option -w -t "$SESSION:$WIN" pane-border-status top
tmux set-option -w -t "$SESSION:$WIN" pane-border-format "#{pane_title}"
tmux select-layout -t "$SESSION:$WIN" tiled >/dev/null

ops_cmd="PROJECT_DIR='$PROJECT_DIR' KIT_DIR='$KIT_DIR' ROLE=shell docker compose -f '$KIT_DIR/docker-compose.yml' run --rm --name factory-ops --entrypoint bash agent '$KIT_DIR/bin/ops-shell.sh'"
tmux new-window -t "$SESSION" -n ops "$ops_cmd"
tmux set-option -w -t "$SESSION:ops" remain-on-exit on

tmux select-window -t "$SESSION:ops"   # land where you type, as before
echo "Started. Attach with: tmux attach -t $SESSION"
echo "Project: $PROJECT_DIR"
echo "Window '$WIN': panes board ${ROLES[*]}   (Ctrl-b o to cycle panes, Ctrl-b q to show numbers, Ctrl-b n/p for windows)"
echo "Window 'ops' is separate - that's the shell you type into."
echo "Respawn a dead pane/window: tmux respawn-pane -k -t $SESSION:$WIN.<index>  (or tmux list-panes -t $SESSION:$WIN for indices)"
