#!/usr/bin/env bash
# Live status board for the tmux "board" window.
source /work/bin/env.sh
cd /work/repo 2>/dev/null || true
while :; do
  clear
  echo "== $(date -u +%FT%TZ) =="
  echo; echo "-- in progress --"
  bd list --json 2>/dev/null | jq -r '.[]? | select(.status=="in_progress") | "\(.id)  [\(.assignee // "-")]  \(.title)"'
  echo; echo "-- ready --"
  bd ready --limit 50 --json 2>/dev/null | jq -r '.[]? | "\(.id)  \((.labels // []) | join(","))  \(.title)"'
  echo; echo "-- needs-human --"
  bd list --json 2>/dev/null | jq -r '.[]? | select(.status!="closed" and ((.labels // []) | index("needs-human"))) | "\(.id)  \(.title)"'
  echo; echo "-- spend today (USD) --"
  cat /work/control/cost/*."$(date +%F)" 2>/dev/null | awk '{s+=$1} END{printf "%.2f\n", s+0}'
  echo; echo "-- recent alerts --"
  tail -n 6 /work/control/alerts.log 2>/dev/null
  sleep 15
done
