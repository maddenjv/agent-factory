#!/usr/bin/env bash
# stop.sh [graceful|now|clear]
#   graceful (default): agents finish their current session, then exit
#   now:                stop agent containers and kill the tmux session (in-flight work is lost; stale claims are released on next start)
#   clear:              remove STOP flags so agents can run again
cd "$(dirname "$0")/.." || exit 1
SESSION=${SESSION:-factory}
case "${1:-graceful}" in
  graceful) mkdir -p data/control; touch data/control/STOP; echo "STOP flag set; agents exit after their current session." ;;
  now)
    for r in po architect qa engineer reviewer ops board; do docker stop "factory-$r" >/dev/null 2>&1 & done; wait
    tmux kill-session -t "$SESSION" 2>/dev/null
    echo "Agents stopped. Dolt is still running (docker compose stop dolt to stop it)." ;;
  clear) rm -f data/control/STOP data/control/STOP.*; echo "STOP flags cleared." ;;
  *) echo "usage: stop.sh [graceful|now|clear]"; exit 1 ;;
esac
