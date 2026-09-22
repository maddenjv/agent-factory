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
in_flight() {  # stories whose review issue is not yet closed
  bd list --json 2>/dev/null | jq '[ .[]? | select(.status != "closed") | select((.labels // []) | index("role:reviewer")) ] | length' 2>/dev/null
}
wip_ok() { [ "$ROLE" != "po" ] || [ "$(in_flight)" -lt "$WIP_LIMIT" ] 2>/dev/null; }

spent_today() { cat "$CONTROL"/cost/*."$(date +%F)" 2>/dev/null | awk '{s+=$1} END{printf "%.2f", s+0}'; }
budget_ok()   { [ -z "$DAILY_BUDGET_USD" ] || awk -v s="$(spent_today)" -v b="$DAILY_BUDGET_USD" 'BEGIN{exit !(s<b)}'; }

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

run_agent() {
  local id=$1 logfile cost
  logfile="$LOGDIR/$(date +%F).$id.jsonl"
  local args=(-p "$(build_prompt "$id")" --dangerously-skip-permissions --max-turns "$MAX_TURNS"
              --output-format stream-json --verbose)
  [ -n "$MODEL" ] && args+=(--model "$MODEL")
  ( cd "$REPO" && timeout "$ITERATION_TIMEOUT" claude "${args[@]}" 2>>"$LOGDIR/claude-err.log" ) \
    | tee -a "$logfile" | jq -R -r --unbuffered "$RENDER" 2>/dev/null
  cost=$(jq -rs '[.[] | select(.type=="result")] | last | .total_cost_usd // 0' "$logfile" 2>/dev/null)
  echo "${cost:-0}" >> "$CONTROL/cost/$ROLE.$(date +%F)"
}

# ---------- outcome handling ----------
handle_outcome() {  # 0 = the agent did something legitimate with the issue, 1 = it did not
  local id=$1 st
  st=$(issue_field "$id" status)
  if [ "$st" = "closed" ]; then log "$id closed (handed off)"; return 0; fi
  if has_label "$id" needs-human; then alert "$id flagged needs-human by the agent"; return 0; fi
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
    sync_dir /home/john/.claude-host "${CLAUDE_CONFIG_DIR:-/home/john/.claude}" "~/.claude"
    sync_dir /home/john/.ai-dev-kit-host /home/john/.ai-dev-kit "~/.ai-dev-kit"
    sync_dir /home/john/.agents-host /home/john/.agents "~/.agents"
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
  timeout 180 claude -p "Reply with the single word OK." --dangerously-skip-permissions --max-turns 1 >/dev/null 2>&1 \
    || { alert "preflight: claude failed to run (check API key/token)"; exit 3; }
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
