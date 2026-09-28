#!/usr/bin/env bash
# Start everything: Dolt, then a tmux session with an "agents" window (all 6 roles as panes,
# tiled) and a separate "ops" window with the interactive shell you type into plus a board pane
# above it (each pane/window backed by its own container).
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
  local cmd="PROJECT_DIR='$PROJECT_DIR' KIT_DIR='$KIT_DIR' AGENT_ENV_FILE='$AGENT_ENV_FILE' ROLE=$role docker compose -f '$KIT_DIR/docker-compose.yml' --env-file '$AGENT_ENV_FILE' run --rm --name factory-$title $*"
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -n "$WIN" "$cmd"
  else
    tmux split-window -t "$SESSION:$WIN" "$cmd"
    tmux select-layout -t "$SESSION:$WIN" tiled >/dev/null
  fi
  tmux select-pane -t "$SESSION:$WIN" -T "$title"
}

pane team-lead team-lead agent
for r in "${ROLES[@]}"; do pane "$r" "$r" agent; done

tmux set-option -w -t "$SESSION:$WIN" remain-on-exit on   # keep a pane (and its last output) if its agent dies
tmux set-option -w -t "$SESSION:$WIN" pane-border-status top
tmux set-option -w -t "$SESSION:$WIN" pane-border-format "#{pane_title}"
tmux select-layout -t "$SESSION:$WIN" tiled >/dev/null

ops_cmd="PROJECT_DIR='$PROJECT_DIR' KIT_DIR='$KIT_DIR' AGENT_ENV_FILE='$AGENT_ENV_FILE' ROLE=shell docker compose -f '$KIT_DIR/docker-compose.yml' --env-file '$AGENT_ENV_FILE' run --rm --name factory-ops --entrypoint bash agent '$KIT_DIR/bin/ops-shell.sh'"
board_cmd="PROJECT_DIR='$PROJECT_DIR' KIT_DIR='$KIT_DIR' AGENT_ENV_FILE='$AGENT_ENV_FILE' ROLE=shell docker compose -f '$KIT_DIR/docker-compose.yml' --env-file '$AGENT_ENV_FILE' run --rm --name factory-board --entrypoint bash agent '$KIT_DIR/bin/board.sh'"
tmux new-window -t "$SESSION" -n ops "$ops_cmd"
tmux select-pane -t "$SESSION:ops" -T shell
tmux split-window -v -b -p 33 -t "$SESSION:ops" "$board_cmd"
tmux select-pane -t "$SESSION:ops" -T board
tmux set-option -w -t "$SESSION:ops" remain-on-exit on
tmux set-option -w -t "$SESSION:ops" pane-border-status top
tmux set-option -w -t "$SESSION:ops" pane-border-format "#{pane_title}"

tmux select-window -t "$SESSION:ops"   # land where you type, as before
echo "Started. Attach with: tmux attach -t $SESSION"
echo "Project: $PROJECT_DIR"
echo "Window '$WIN': panes team-lead ${ROLES[*]}   (Ctrl-b o to cycle panes, Ctrl-b q to show numbers, Ctrl-b n/p for windows)"
echo "Window 'ops': shell pane (where you type) plus a board pane above it - the live status view, relocated here."
echo "Respawn a dead pane/window: tmux respawn-pane -k -t $SESSION:$WIN.<index>  (or tmux list-panes -t $SESSION:$WIN for indices)"
