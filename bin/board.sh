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

# agent_last_started_epoch AGENT_ID -> epoch of that agent's most recent successful-start marker
# (the "started: role=..." line agent-loop.sh logs to loop.log once preflight passes - a
# successful preflight itself logs nothing to alerts.log, so this is the only place that signal
# exists), or non-zero if there is none or it's unparseable. Fails open (non-zero => "no known
# restart"), same philosophy as still_needs_human.
agent_last_started_epoch() {
  local agent_id="$1" line ts
  line=$(grep -F "[$agent_id] started: role=" "$DATA_DIR/logs/$agent_id/loop.log" 2>/dev/null | tail -n 1)
  [ -n "$line" ] || return 1
  [[ $line =~ ^([0-9T:-]+Z)\ \[ ]] || return 1
  ts="${BASH_REMATCH[1]}"
  date -d "$ts" +%s 2>/dev/null
}

# recent_alerts: reads the last 6 lines of alerts.log (same tail window as before) and writes the
# filtered result to stdout - needs-human alerts whose issue has since lost the label (or been
# closed) and usage-limit alerts whose wait window has elapsed are dropped; any other alert is
# dropped once older than ALERT_MAX_AGE_MINUTES (default 60). Lines that don't match the log
# format or have an unparseable timestamp are printed unchanged.
#
# Preflight alerts (the "bd cannot reach" and "harness failed to run" messages specifically - NOT
# "usage limit hit", which stays governed purely by the wait-window logic below, per
# agent-factory-wzg AC5) get one more pre-check first: an agent's own preflight alert is dropped
# once superseded - either by a later preflight alert of its own (two alerts from the same agent
# can only happen across two separate process starts, since each of these two messages ends that
# run immediately) or by that agent's own later successful-start marker. This needs two passes
# over the tail window: whether an early line is superseded can depend on a later line the
# forward filtering pass hasn't reached yet (agent-factory-wzg AC3).
#
# "bd cannot reach" / "harness failed to run" always exit agent-loop.sh immediately, so ANY later
# alert line for that same agent - including a "usage limit hit" preflight retry, which loops/
# sleeps within its own process rather than exiting - is by construction proof that a later
# process has since started for that agent. The first pass below therefore also counts
# "usage limit hit" lines as restart *evidence* (updating restart_epoch), even though the second
# pass never drops a "usage limit hit" line itself (still governed purely by the wait-window
# check further down, per AC5) - agent-factory-kuw.
recent_alerts() {
  local now line ts agent msg id wait_s alert_epoch
  local max_min="${ALERT_MAX_AGE_MINUTES:-60}"
  [[ $max_min =~ ^[1-9][0-9]*$ ]] || max_min=60
  local max_age_s=$(( max_min * 60 ))
  now=$(date -u +%s)
  local lines
  lines=$(tail -n 6 "$DATA_DIR/control/alerts.log" 2>/dev/null)

  local -A restart_epoch
  local pf_epoch
  while IFS= read -r line; do
    [[ $line =~ ^([0-9T:-]+Z)\ \[([^]]*)\]\ (.*)$ ]] || continue
    ts="${BASH_REMATCH[1]}"; agent="${BASH_REMATCH[2]}"; msg="${BASH_REMATCH[3]}"
    [[ $msg =~ ^preflight:\ (bd\ cannot\ reach|harness\ failed\ to\ run|usage\ limit\ hit) ]] || continue
    pf_epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
    if [ -z "${restart_epoch[$agent]:-}" ] || (( pf_epoch > restart_epoch[$agent] )); then
      restart_epoch[$agent]=$pf_epoch
    fi
  done <<< "$lines"
  local started_epoch
  for agent in "${!restart_epoch[@]}"; do
    started_epoch=$(agent_last_started_epoch "$agent") || continue
    (( started_epoch > restart_epoch[$agent] )) && restart_epoch[$agent]=$started_epoch
  done

  while IFS= read -r line; do
    if [[ ! $line =~ ^([0-9T:-]+Z)\ \[([^]]*)\]\ (.*)$ ]]; then
      echo "$line"; continue
    fi
    ts="${BASH_REMATCH[1]}"; agent="${BASH_REMATCH[2]}"; msg="${BASH_REMATCH[3]}"

    if [[ $msg =~ ^preflight:\ (bd\ cannot\ reach|harness\ failed\ to\ run) ]]; then
      alert_epoch=$(date -d "$ts" +%s 2>/dev/null) && [ -n "${restart_epoch[$agent]:-}" ] \
        && (( alert_epoch < restart_epoch[$agent] )) && continue
    fi

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

    alert_epoch=$(date -d "$ts" +%s 2>/dev/null) || { echo "$line"; continue; }
    if (( now - alert_epoch <= max_age_s )); then echo "$line"; fi
  done <<< "$lines"
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

throttle_section() {
  local f="$DATA_DIR/control/throttle.json"
  [ -f "$f" ] || { echo "(no assessment yet - po/architect proceed unthrottled)"; return; }
  jq -r '(if .idle then "IDLE" else "GO" end) as $s | "\($s)  (assessed \(.assessed_at // "?"))  \(.reason // "no reason recorded")"' "$f" 2>/dev/null \
    || echo "(unreadable: $f)"
}

render() {
  clear
  echo "== $(date -u +%FT%TZ) =="
  local throttle_out
  throttle_out=$(throttle_section)
  if [[ "$throttle_out" == "GO  ("* || "$throttle_out" == "(no assessment yet"* ]]; then
    :  # nothing held back, or no judgment recorded yet - AC1/AC2: stay quiet
  else
    echo; echo "-- throttle (po/architect) --"
    echo "$throttle_out"  # IDLE, or the file exists but is unreadable/malformed - AC3/AC4: surface it
  fi
  echo; echo "-- in progress --"
  bd list --json 2>/dev/null | jq -r '.[]? | select(.status=="in_progress") | "\(.id)  [\(.assignee // "-")]  \(.title)"'
  echo; echo "-- ready --"
  ready_section
  echo; echo "-- needs-human (see \`bd show <id>\` for what's needed) --"
  needs_human_section
  echo; echo "-- blocked (waiting on a needs-human issue) --"
  blocked_section
  echo; echo "-- recent alerts --"
  recent_alerts
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  while :; do render; sleep 15; done
fi
