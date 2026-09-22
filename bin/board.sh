#!/usr/bin/env bash
# Live status board for the tmux "board" window.
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
while :; do
  clear
  echo "== $(date -u +%FT%TZ) =="
  echo; echo "-- in progress --"
  bd list --json 2>/dev/null | jq -r '.[]? | select(.status=="in_progress") | "\(.id)  [\(.assignee // "-")]  \(.title)"'
  echo; echo "-- ready --"
  bd ready --limit 50 --json 2>/dev/null | jq -r '.[]? | "\(.id)  \((.labels // []) | join(","))  \(.title)"'
  echo; echo "-- needs-human (see \`bd show <id>\` for what's needed) --"
  bd list --json 2>/dev/null | jq -r '.[]? | select(.status!="closed" and ((.labels // []) | index("needs-human"))) | "\(.id)  \(.title)"'
  echo; echo "-- spend today (USD) --"
  cat "$DATA_DIR"/control/cost/*."$(date +%F)" 2>/dev/null | awk '{s+=$1} END{printf "%.2f\n", s+0}'
  echo; echo "-- recent alerts --"
  tail -n 6 "$DATA_DIR/control/alerts.log" 2>/dev/null
  sleep 15
done
