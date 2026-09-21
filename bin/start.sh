#!/usr/bin/env bash
# Start everything: Dolt, then a tmux session with one window per agent (each a container).
set -euo pipefail
cd "$(dirname "$0")/.."
SESSION=${SESSION:-factory}
ROLES=(po architect qa engineer reviewer)

docker compose up -d dolt
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Already running: tmux attach -t $SESSION"; exit 0
fi
rm -f data/control/STOP data/control/STOP.*

win() {  # win <name> <role> <bash-args...>
  local name=$1 role=$2; shift 2
  local cmd="ROLE=$role docker compose run --rm --name factory-$name $*"
  if tmux has-session -t "$SESSION" 2>/dev/null; then tmux new-window -t "$SESSION" -n "$name" "$cmd"
  else tmux new-session -d -s "$SESSION" -n "$name" "$cmd"; fi
  tmux set-option -w -t "$SESSION:$name" remain-on-exit on   # keep the pane (and its last output) if the agent dies
}

win ops   shell --entrypoint bash agent /work/bin/ops-shell.sh
win board shell --entrypoint bash agent /work/bin/board.sh
for r in "${ROLES[@]}"; do win "$r" "$r" agent; done

tmux select-window -t "$SESSION:ops"
echo "Started. Attach with: tmux attach -t $SESSION"
echo "Windows: ops board ${ROLES[*]}   (Ctrl-b n/p to switch; respawn a dead agent: tmux respawn-pane -k -t $SESSION:<name>)"
