#!/usr/bin/env bash
# agent-loop.sh - one autonomous agent (one role), running in its own container.
#
# Pull-based: find the next ready Beads issue labelled role:$ROLE, claim it, run ONE fresh
# Claude Code session on it, check what happened, repeat. Beads is the only memory.
set -uo pipefail

ROLE="${ROLE:?ROLE must be set (po|architect|qa|engineer|reviewer)}"
AGENT_ID="${AGENT_ID:-$ROLE}"
KIT_DIR="${KIT_DIR:?KIT_DIR must be set}"           # this repo (docker-compose.yml, bin/, agents/)
PROJECT_DIR="${PROJECT_DIR:?PROJECT_DIR must be set}"  # the real project - see bin/lib.sh
DATA_DIR="${DATA_DIR:-$PROJECT_DIR/.agent-factory}"    # agent-factory's own runtime state, kept
                                                        # inside the project rather than the kit
ORIGIN="${ORIGIN:-$PROJECT_DIR}"   # every role clones from and (only the reviewer) pushes to it
REPO="$DATA_DIR/workspaces/$ROLE"
CONTROL="$DATA_DIR/control"
LOGDIR="$DATA_DIR/logs/$ROLE"
STATE="$CONTROL/state/$AGENT_ID"

MAX_TURNS="${MAX_TURNS:-60}"
ITERATION_TIMEOUT="${ITERATION_TIMEOUT:-45m}"
IDLE_SLEEP="${IDLE_SLEEP:-60}"
MAX_ATTEMPTS_PER_ISSUE="${MAX_ATTEMPTS_PER_ISSUE:-2}"
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"
WIP_LIMIT="${WIP_LIMIT:-2}"
DAILY_BUDGET_USD="${DAILY_BUDGET_USD:-}"
PREFLIGHT="${PREFLIGHT:-1}"
QUOTA_RETRY_INTERVAL="${QUOTA_RETRY_INTERVAL:-900}"  # fallback poll interval when a reset time can't be parsed
CONTAINER_HOME="${CONTAINER_HOME:-$HOME}"
if [ "$CONTAINER_HOME" != "$HOME" ]; then
  echo "error: CONTAINER_HOME ($CONTAINER_HOME) != image HOME ($HOME). Set HOST_USER (and CONTAINER_HOME=/home/<HOST_USER>) in .env - re-run bin/init.sh after removing a stale CONTAINER_HOME line - then rebuild: docker compose build agent" >&2
  exit 1
fi
model_var="MODEL_${ROLE^^}"
MODEL="${!model_var:-}"

mkdir -p "$LOGDIR" "$STATE" "$CONTROL/cost"
# shellcheck disable=SC1091
source "$KIT_DIR/bin/env.sh"

# ---------- logging / alerting ----------
log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$AGENT_ID" "$*" | tee -a "$LOGDIR/loop.log"; }
alert() {
  printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$AGENT_ID" "$*" >> "$CONTROL/alerts.log"
  log "ALERT: $*"
  if [ -n "${NOTIFY_URL:-}" ]; then curl -fsS -m 10 -d "[$AGENT_ID] $*" "$NOTIFY_URL" >/dev/null 2>&1 || true; fi
}
stopping() { [ -f "$CONTROL/STOP" ] || [ -f "$CONTROL/STOP.$ROLE" ]; }

# ---------- beads helpers ----------
show_json()   { bd show "$1" --json 2>/dev/null | jq -c 'if type=="array" then .[0] else . end' 2>/dev/null; }
issue_field() { show_json "$1" | jq -r --arg f "$2" '.[$f] // empty' 2>/dev/null; }
has_label()   { show_json "$1" | jq -e --arg l "$2" '(.labels // []) | index($l)' >/dev/null 2>&1; }
is_ready()    { bd ready --limit 200 --json 2>/dev/null | jq -e --arg id "$1" '[.[]? | select(.id == $id)] | length > 0' >/dev/null 2>&1; }

next_issue() {
  bd ready --label "role:$ROLE" --limit 50 --json 2>>"$LOGDIR/bd-err.log" | jq -r --arg me "$AGENT_ID" '
    [ .[]?
      | select(((.labels // []) | index("needs-human")) | not)
      | select(((.assignee // "") == "") or (.assignee == $me)) ]
    | .[0].id // empty' 2>/dev/null
}

claim() {  # atomic claim when unassigned; resume if it was already ours
  local id=$1 who
  who=$(issue_field "$id" assignee)
  if [ -z "$who" ]; then bd update "$id" --claim --assignee "$AGENT_ID" >/dev/null 2>&1
  elif [ "$who" = "$AGENT_ID" ]; then bd update "$id" --status in_progress >/dev/null 2>&1
  else return 1; fi
}

release_stale() {  # anything still in_progress under our name at startup is left over from a crash
  bd list --json 2>/dev/null \
    | jq -r --arg me "$AGENT_ID" '.[]? | select(.status=="in_progress" and (.assignee // "")==$me) | .id' \
    | while read -r id; do
        [ -n "$id" ] || continue
        log "releasing stale claim on $id"
        bd update "$id" --status open >/dev/null 2>&1
      done
}

# ---------- throttles ----------
in_flight() {  # stories whose review issue is not yet closed, minus those stalled on a needs-human issue
  bd list --json 2>/dev/null | jq '
    [ .[]? | select(.status != "closed") ] as $open
    | ($open | map({key: .id, value: ((.labels // []) | index("needs-human") != null)}) | from_entries) as $nh
    | ( [ $open[]
          | select(($nh[.id]) or ([ (.dependencies // [])[] | select(.type == "blocks") | $nh[.depends_on_id] ] | any))
          | (.labels // [])[] | select(startswith("story:")) ] | unique ) as $stalled
    | [ $open[]
        | select((.labels // []) | index("role:reviewer"))
        | select(([ (.labels // [])[] | select(startswith("story:")) ] | any(. as $s | $stalled | index($s))) | not)
      ] | length' 2>/dev/null
}
wip_ok() { [ "$ROLE" != "po" ] || [ "$(in_flight)" -lt "$WIP_LIMIT" ] 2>/dev/null; }

spent_today() { cat "$CONTROL"/cost/*."$(date +%F)" 2>/dev/null | awk '{s+=$1} END{printf "%.2f", s+0}'; }
budget_ok()   { [ -z "$DAILY_BUDGET_USD" ] || awk -v s="$(spent_today)" -v b="$DAILY_BUDGET_USD" 'BEGIN{exit !(s<b)}'; }

# ---------- usage limits ----------
# Claude Code plan usage limits (not $DAILY_BUDGET_USD, which is our own spend cap) are a
# temporary, external condition, not a bug in the issue or the agent's work on it - so hitting
# one must never count as a failed attempt (record_failure/MAX_ATTEMPTS_PER_ISSUE) or trip the
# consecutive-failure circuit breaker. Detected by text match, but ONLY against trusted sources:
# the CLI's own stderr for this run (quota_hit_message, given just $errfile) and the final
# is_error `result` event of this run's stream-json (quota_hit_from_stream, given this run's
# own $outfile, never the cumulative $logfile). The jsonl transcript as raw text holds the agent's own conversation, including whatever it read - and a false match
# there once genuinely happened: the agent read this very file, whose text a few lines up
# literally contains the words "usage limit", and got treated as a real hit. Matching against the
# raw stderr of a single `claude` invocation can't false-positive on a file the agent chose to
# read, since that never goes through stderr. The [^"]{0,200} cap bounds the extracted text even
# if grep's match runs long for some other reason - never dump an unbounded blob into a tmux pane.
quota_hit_message() {  # quota_hit_message FILE -> first matching line (bounded, single-line), or empty
  grep -ihEo 'hit your [a-z]+ limit[^"]{0,200}|usage limit[^"]{0,200}|limit reached[^"]{0,200}|rate limit exceeded[^"]{0,200}' "$@" 2>/dev/null \
    | head -1 | tr -d '\r' | tr '\n\t' '  ' | cut -c1-200
}

quota_hit_from_stream() {  # quota_hit_from_stream FILE -> limit message if the run ENDED in an error result, or empty
  # The CLI reports a session limit only on stdout: a synthetic assistant message carrying the
  # text, then a result event with is_error:true. Only "hit your ... limit" wording is accepted.
  jq -Rn '[inputs | fromjson? | select(type=="object")] as $e
          | ($e | map(select(.type=="result")) | last) as $r
          | select($r.is_error == true)
          | ($r.result // ""), ($e | map(select(.type=="assistant")) | last | [.message.content[]? | .text? // empty] | join(" "))' "$1" 2>/dev/null \
    | grep -ihEo 'hit your [a-z]+ limit[^"]{0,200}' | head -1 | tr -d '\r' | tr '\n\t' '  ' | cut -c1-200
}

usage_limit_wait_seconds() {  # usage_limit_wait_seconds "<message text>" -> seconds to sleep
  # The CLI's wording for this varies ("...resets 5:50pm (UTC)", "...continuing automatically at
  # 6:50pm", etc.) so the time is matched wherever it appears, not anchored to specific lead-in
  # words - just an H:MMam/pm clock time. Interpreted as the container's local time, which is UTC
  # by default in this image (see Dockerfile) and matches the CLI's own likely rendering, with or
  # without an explicit "(UTC)" label.
  local msg="$1" h m ap now epoch wait
  if [[ "$msg" =~ ([0-9]{1,2}):([0-9]{2})[[:space:]]*([AaPp][Mm]) ]]; then
    h="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; ap="${BASH_REMATCH[3],,}"
    [ "$ap" = pm ] && [ "$h" -ne 12 ] && h=$((h+12))
    [ "$ap" = am ] && [ "$h" -eq 12 ] && h=0
    now=$(date +%s)
    epoch=$(date -d "today $h:$m" +%s 2>/dev/null) || epoch=""
    if [ -n "$epoch" ]; then
      # just-passed reset (clock skew) -> retry shortly rather than rolling to tomorrow
      if [ "$epoch" -le "$now" ] && [ $((now - epoch)) -lt 600 ]; then echo 60; return; fi
      [ "$epoch" -le "$now" ] && epoch=$((epoch + 86400))  # already passed today -> tomorrow
      wait=$((epoch - now + 60))                            # +60s buffer past the reset
      if [ "$wait" -gt 0 ] && [ "$wait" -le 86400 ]; then echo "$wait"; return; fi
    fi
  fi
  echo "$QUOTA_RETRY_INTERVAL"   # couldn't parse a reset time - poll instead
}

# ---------- git ----------
sync_repo() {  # clean slate each iteration: anything not committed AND pushed does not survive
  git -C "$REPO" fetch -q --prune origin || return 1
  git -C "$REPO" reset -q --hard
  git -C "$REPO" clean -qfd
  git -C "$REPO" checkout -q -f main 2>/dev/null || git -C "$REPO" checkout -q -f -B main origin/main
  git -C "$REPO" reset -q --hard origin/main
}

# ---------- running claude ----------
# Turns stream-json events into readable one-liners for the tmux window (raw stream goes to the log).
RENDER='fromjson? | select(type=="object") |
  ( if .type=="assistant" then
      (.message.content[]? |
        if .type=="text" then "  " + (.text | gsub("\n";" ") | .[0:300])
        elif .type=="tool_use" then "  > " + .name + " " + ((.input.command // .input.file_path // .input.pattern // .input.description // "") | tostring | gsub("\n";" ") | .[0:140])
        else empty end)
    elif .type=="result" then "  = finished: turns=\(.num_turns // "?") cost=$\(.total_cost_usd // "?") \(.subtype // "")"
    else empty end )'

build_prompt() {
  cat "$KIT_DIR/agents/$ROLE.md"
  printf '\n\n---\nYour assigned issue: %s\nRepository: %s (your own clone; remote "origin"). Shared conventions are in CLAUDE.md.\nStart with: bd show %s\n' "$1" "$REPO" "$1"
}

run_agent() {  # sets LAST_RUN_QUOTA_MSG (empty unless this run hit a usage limit)
  local id=$1 logfile errfile outfile cost
  logfile="$LOGDIR/$(date +%F).$id.jsonl"
  errfile=$(mktemp); outfile=$(mktemp)
  local args=(-p "$(build_prompt "$id")" --dangerously-skip-permissions --max-turns "$MAX_TURNS"
              --output-format stream-json --verbose)
  [ -n "$MODEL" ] && args+=(--model "$MODEL")
  ( cd "$REPO" && timeout "$ITERATION_TIMEOUT" claude "${args[@]}" 2>"$errfile" ) \
    | tee -a "$logfile" "$outfile" | jq -R -r --unbuffered "$RENDER" 2>/dev/null
  cost=$(jq -rs '[.[] | select(.type=="result")] | last | .total_cost_usd // 0' "$logfile" 2>/dev/null)
  echo "${cost:-0}" >> "$CONTROL/cost/$ROLE.$(date +%F)"
  cat "$errfile" >> "$LOGDIR/claude-err.log"
  LAST_RUN_QUOTA_MSG=$(quota_hit_message "$errfile")   # stderr, else this run's final error result
  [ -n "$LAST_RUN_QUOTA_MSG" ] || LAST_RUN_QUOTA_MSG=$(quota_hit_from_stream "$outfile")
  rm -f "$errfile" "$outfile"
}

# ---------- outcome handling ----------
handle_outcome() {  # 0 = the agent did something legitimate with the issue, 1 = it did not
  local id=$1 st
  st=$(issue_field "$id" status)
  if [ "$st" = "closed" ]; then log "$id closed (handed off)"; return 0; fi
  if has_label "$id" needs-human; then
    # CLAUDE.project.md tells the agent to --append-notes what it needs BEFORE labelling
    # needs-human - but that's an instruction to an LLM, not a guarantee. Back it up mechanically:
    # if it labelled needs-human without a note (issue_field's "// empty" also catches a JSON
    # null, which is what an unset field reads as), `bd show` would otherwise be a dead end for
    # a human trying to figure out what's actually needed.
    if [ -z "$(issue_field "$id" notes)" ]; then
      bd update "$id" --append-notes "agent-loop: $AGENT_ID labelled this needs-human but left no note explaining what it needs - see the session transcript. Transcript: $LOGDIR/$(date +%F).$id.jsonl" >/dev/null 2>&1
      alert "$id flagged needs-human WITHOUT an explanation from the agent - see the transcript"
    else
      alert "$id flagged needs-human by the agent"
    fi
    return 0
  fi
  if [ "$st" = "open" ] && ! is_ready "$id"; then log "$id parked behind new blockers (rework/handoff)"; return 0; fi
  return 1
}

record_failure() {
  local id=$1 f="$STATE/attempts.$1" n
  n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"
  bd update "$id" --status open >/dev/null 2>&1
  if [ "$n" -ge "$MAX_ATTEMPTS_PER_ISSUE" ]; then
    # This is agent-loop.sh escalating on its own (attempt cap, not the agent choosing to stop),
    # so it can't explain WHY in the way the agent itself could - but a bd show with nothing on
    # it is still a dead end, so at least point at the transcript.
    bd update "$id" --append-notes "agent-loop: not completed after $n attempt(s) by $AGENT_ID (session ended without closing or explaining why). Transcript: $LOGDIR/$(date +%F).$id.jsonl" >/dev/null 2>&1
    bd label add "$id" needs-human >/dev/null 2>&1
    alert "$id not completed after $n attempts; labelled needs-human"
  else
    log "$id not completed (attempt $n/$MAX_ATTEMPTS_PER_ISSUE); released for retry"
  fi
}

# ---------- host config sync ----------
# docker-compose.yml mounts host ~/.claude, ~/.ai-dev-kit and ~/.agents read-only at *-host (same
# convention, and same three directories, as claude-code-sandbox's own entrypoint.sh). Copying
# each into its live, writable counterpart here reproduces that sync for these headless
# containers. ~/.claude is per-role (its own volume, so roles never share or race on it) and
# reusing it is what lets these agents run on your logged-in Claude Code plan session with no
# ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN needed. ~/.ai-dev-kit and ~/.agents are shared,
# writable volumes across all 5 roles, same as the sandbox shares them across sessions - so all 5
# containers starting together would otherwise run `cp -a` into them at once and race each other
# (concurrent unlink+create on the same paths -> spurious "File exists" errors, or worse). The
# flock in sync_configs() serializes every role's sync through a lock file on the shared CONTROL
# mount, so only one copy runs at a time.
sync_dir() {  # sync_dir HOST_PATH LIVE_PATH LABEL
  local host="$1" live="$2" label="$3"
  if [ ! -d "$host" ] || [ -z "$(ls -A "$host" 2>/dev/null)" ]; then
    log "no host $label mounted; skipping sync"
  else
    cp -a --remove-destination "${host}/." "${live}/"
    log "synced host $label into $live"
  fi
}

sync_configs() {
  (
    flock -w 120 9 || { log "sync lock timed out; skipping host-config sync"; return 1; }
    sync_dir "$CONTAINER_HOME/.claude-host" "${CLAUDE_CONFIG_DIR:-$CONTAINER_HOME/.claude}" "~/.claude"
    sync_dir "$CONTAINER_HOME/.ai-dev-kit-host" "$CONTAINER_HOME/.ai-dev-kit" "~/.ai-dev-kit"
    sync_dir "$CONTAINER_HOME/.agents-host" "$CONTAINER_HOME/.agents" "~/.agents"
  ) 9>"$CONTROL/sync.lock"
}

# ---------- startup ----------
sync_configs
git config --global user.name "$AGENT_ID"
git config --global user.email "$AGENT_ID@factory.local"
git config --global --add safe.directory '*'
[ -d "$REPO/.git" ] || git clone -q "$ORIGIN" "$REPO" || { alert "cannot clone $ORIGIN"; exit 3; }
cd "$REPO" || exit 3

if [ "$PREFLIGHT" = 1 ]; then
  bd ready --json >/dev/null 2>&1 || { alert "preflight: bd cannot reach the Beads database"; exit 3; }
  while :; do
    preflight_out=$(timeout 180 claude -p "Reply with the single word OK." --dangerously-skip-permissions --max-turns 1 2>&1)
    [ $? -eq 0 ] && break
    preflight_hit=$(quota_hit_message <(printf '%s' "$preflight_out"))
    if [ -n "$preflight_hit" ]; then
      wait_s=$(usage_limit_wait_seconds "$preflight_hit")
      alert "preflight: usage limit hit ($preflight_hit); waiting ${wait_s}s before retrying startup"
      sleep "$wait_s"
      continue
    fi
    alert "preflight: claude failed to run (check API key/token): ${preflight_out:0:200}"
    exit 3
  done
fi

release_stale
log "started: role=$ROLE model=${MODEL:-default} max_turns=$MAX_TURNS timeout=$ITERATION_TIMEOUT"

# ---------- main loop ----------
fails=0
idle_logged=0
while :; do
  if stopping; then log "STOP requested; exiting"; exit 0; fi
  if ! budget_ok; then alert "daily budget reached ($(spent_today) USD); pausing 30 min"; sleep 1800; continue; fi
  if ! wip_ok; then sleep "$IDLE_SLEEP"; continue; fi

  id=$(next_issue)
  if [ -z "$id" ]; then
    [ "$idle_logged" = 1 ] || { log "queue empty; idling"; idle_logged=1; }
    sleep "$IDLE_SLEEP"; continue
  fi
  idle_logged=0

  if ! claim "$id"; then log "could not claim $id"; sleep 5; continue; fi
  if ! sync_repo; then
    log "git sync failed; releasing $id"; bd update "$id" --status open >/dev/null 2>&1
    fails=$((fails+1))
    if [ "$fails" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then alert "circuit breaker: git sync failing; stopping"; exit 2; fi
    sleep 30; continue
  fi

  log "START $id: $(issue_field "$id" title)"
  run_agent "$id"

  if [ -n "$LAST_RUN_QUOTA_MSG" ]; then
    wait_s=$(usage_limit_wait_seconds "$LAST_RUN_QUOTA_MSG")
    bd update "$id" --status open >/dev/null 2>&1   # release for retry; stays assigned to us
    alert "$id: usage limit hit ($LAST_RUN_QUOTA_MSG); waiting ${wait_s}s to retry - not counted as a failed attempt"
    sleep "$wait_s"
    continue
  fi

  if handle_outcome "$id"; then
    fails=0; rm -f "$STATE/attempts.$id"
  else
    record_failure "$id"
    fails=$((fails+1)); log "consecutive failures: $fails"
    if [ "$fails" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
      alert "circuit breaker: $fails consecutive failures; stopping $AGENT_ID"; exit 2
    fi
  fi
  sleep 5
done
