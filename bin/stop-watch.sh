#!/usr/bin/env bash
# stop-watch.sh <session> - launched by bin/stop.sh's graceful mode, backgrounded and detached
# from the invoking terminal. Polls until none of FACTORY_ROLES' containers are still running,
# then stops ops/board and kills the tmux session housing every pane - the teardown a graceful
# stop needs that nothing else performs (docs/design/agent-factory-rez8.md). Never run directly
# by an operator.
set -uo pipefail   # narrower than stop.sh's -e: one bad poll must not kill a background watcher
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SESSION="${1:?usage: stop-watch.sh <session>}"
POLL_INTERVAL="${STOP_WATCH_POLL_INTERVAL:-15}"

role_running() { [ -n "$(docker ps -q -f "name=^factory-$1\$" 2>/dev/null)" ]; }

while :; do
  any=0
  for r in "${FACTORY_ROLES[@]}"; do role_running "$r" && { any=1; break; }; done
  [ "$any" -eq 0 ] && break
  sleep "$POLL_INTERVAL"
done

for r in ops board; do docker stop "factory-$r" >/dev/null 2>&1 & done
wait
tmux kill-session -t "$SESSION" 2>/dev/null
echo "$(date -u +%FT%TZ) graceful shutdown complete: ops/board stopped, tmux session $SESSION killed."
