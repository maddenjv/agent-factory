#!/usr/bin/env bash
# Live status board for the tmux "board" window.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

# still_needs_human ID -> exit 0 (still labelled, not closed - keep showing) / 1 (resolved - drop).
# Any lookup ambiguity (bd unreachable, id typo'd, issue deleted) fails open: keep showing the
# alert rather than risk silently dropping one that's still real.
still_needs_human() {
  local id="$1" json status
  json=$(bd show "$id" --json 2>/dev/null | jq -c 'if type=="array" then .[0] else . end' 2>/dev/null)
  [ -n "$json" ] || return 0
  status=$(echo "$json" | jq -r '.status // empty')
  [ "$status" = "closed" ] && return 1
  echo "$json" | jq -e '(.labels // []) | index("needs-human")' >/dev/null 2>&1
}

# recent_alerts: reads the last 6 lines of alerts.log (same tail window as before) and writes the
# filtered result to stdout - needs-human alerts whose issue has since lost the label (or been
# closed) and usage-limit alerts whose wait window has elapsed are dropped; everything else
# (including anything that doesn't match either format) is printed unchanged.
recent_alerts() {
  local now line ts msg id wait_s alert_epoch
  now=$(date -u +%s)
  tail -n 6 "$DATA_DIR/control/alerts.log" 2>/dev/null | while IFS= read -r line; do
    if [[ ! $line =~ ^([0-9T:-]+Z)\ \[[^]]*\]\ (.*)$ ]]; then
      echo "$line"; continue
    fi
    ts="${BASH_REMATCH[1]}"; msg="${BASH_REMATCH[2]}"

    if [[ $msg =~ ^([A-Za-z0-9_.-]+)\ (flagged\ needs-human|not\ completed\ after\ [0-9]+\ attempts\;\ labelled\ needs-human) ]]; then
      id="${BASH_REMATCH[1]}"
      still_needs_human "$id" && echo "$line"
      continue
    fi

    if [[ $msg =~ usage\ limit\ hit.*waiting\ ([0-9]+)s ]]; then
      wait_s="${BASH_REMATCH[1]}"
      alert_epoch=$(date -d "$ts" +%s 2>/dev/null) || { echo "$line"; continue; }
      (( now < alert_epoch + wait_s )) && echo "$line"
      continue
    fi

    echo "$line"
  done
}

ready_section() {
  bd ready --limit 50 --json 2>/dev/null \
    | jq -r '.[]? | select((.labels // []) | index("needs-human") | not)
                  | "\(.id)  \((.labels // []) | join(","))  \(.title)"'
}

needs_human_section() {
  bd list --json 2>/dev/null \
    | jq -r '.[]? | select(.status!="closed" and ((.labels // []) | index("needs-human"))) | "\(.id)  \(.title)"'
}

blocked_section() {
  bd list --json 2>/dev/null | jq -r '
    ( [.[] | select(.status != "closed")] ) as $open
    | ($open | map({key: .id, value: (.labels // [])}) | from_entries) as $labels
    | ($open | map({key: .id, value: .status}) | from_entries) as $status
    | $open[]
    | . as $issue
    | select(($issue.labels // []) | index("needs-human") | not)
    | ((.dependencies // [])
        | map(select(.type == "blocks"))
        | map(.depends_on_id)
        | map(select(($status[.] // "closed") != "closed"))
        | map(select(($labels[.] // []) | index("needs-human")))
      ) as $blockers
    | select(($blockers | length) > 0)
    | "\($issue.id)  waiting on \($blockers | join(","))  \($issue.title)"
  '
}

render() {
  clear
  echo "== $(date -u +%FT%TZ) =="
  echo; echo "-- in progress --"
  bd list --json 2>/dev/null | jq -r '.[]? | select(.status=="in_progress") | "\(.id)  [\(.assignee // "-")]  \(.title)"'
  echo; echo "-- ready --"
  ready_section
  echo; echo "-- needs-human (see \`bd show <id>\` for what's needed) --"
  needs_human_section
  echo; echo "-- blocked (waiting on a needs-human issue) --"
  blocked_section
  echo; echo "-- spend today (USD) --"
  cat "$DATA_DIR"/control/cost/*."$(date +%F)" 2>/dev/null | awk '{s+=$1} END{printf "%.2f\n", s+0}'
  echo; echo "-- recent alerts --"
  recent_alerts
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  while :; do render; sleep 15; done
fi
