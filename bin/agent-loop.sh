#!/usr/bin/env bash
# agent-loop.sh - one autonomous agent (one role), running in its own container.
#
# Pull-based: find the next ready Beads issue labelled role:$ROLE, claim it, run ONE fresh
# Claude Code session on it, check what happened, repeat. Beads is the only memory.
set -uo pipefail

ROLE="${ROLE:?ROLE must be set (po|architect|qa|engineer|reviewer|team-lead)}"
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
THROTTLE_STALE_SECS="${THROTTLE_STALE_SECS:-900}"        # how often team-lead re-assesses
THROTTLE_ALERT_STALE_SECS="${THROTTLE_ALERT_STALE_SECS:-3600}"  # alert if it falls further behind than this
DAILY_BUDGET_USD="${DAILY_BUDGET_USD:-}"
PREFLIGHT="${PREFLIGHT:-1}"
QUOTA_RETRY_INTERVAL="${QUOTA_RETRY_INTERVAL:-900}"  # fallback poll interval when a reset time can't be parsed
CONTAINER_HOME="${CONTAINER_HOME:-$HOME}"
if [ "$CONTAINER_HOME" != "$HOME" ]; then
  echo "error: CONTAINER_HOME ($CONTAINER_HOME) != image HOME ($HOME). Set HOST_USER (and CONTAINER_HOME=/home/<HOST_USER>) in .env - re-run bin/init.sh after removing a stale CONTAINER_HOME line - then rebuild: docker compose build agent" >&2
  exit 1
fi
HARNESS="${HARNESS:-claude-code}"
case "$HARNESS" in
  claude-code|copilot) ;;
  *) echo "error: HARNESS=$HARNESS not recognized (expected claude-code or copilot) - re-run bin/init.sh --harness=<value>" >&2; exit 1 ;;
esac
# ---------- model resolution ----------
# Two tiers: team-lead (coordination/triage) gets the most capable model; the five execution
# roles get a lower-capability default. Change these two values if the mapping drifts - no other
# call site hardcodes a model name. An explicit MODEL_<ROLE> (below) always overrides its tier.
# Claude Code's tier names (sonnet/opus) aren't valid Copilot CLI model identifiers, so under
# HARNESS=copilot the defaults are left empty unless the operator sets one - Copilot CLI then
# falls back to its own built-in default model (see run_harness_session's --model handling).
if [ "$HARNESS" = "copilot" ]; then
  TIER_TEAM_LEAD="${TIER_TEAM_LEAD:-}"
  TIER_STANDARD="${TIER_STANDARD:-}"
else
  TIER_TEAM_LEAD="${TIER_TEAM_LEAD:-opus}"
  TIER_STANDARD="${TIER_STANDARD:-sonnet}"
fi

# ROLE can contain a hyphen (team-lead); "-" is not legal in a bash variable name, so sanitize
# before building the indirect-expansion name (MODEL_TEAM_LEAD, not MODEL_TEAM-LEAD).
model_key="${ROLE^^}"; model_key="${model_key//-/_}"
model_var="MODEL_${model_key}"
MODEL="${!model_var:-}"
if [ -z "$MODEL" ]; then
  if [ "$ROLE" = "team-lead" ]; then MODEL="$TIER_TEAM_LEAD"; else MODEL="$TIER_STANDARD"; fi
fi

mkdir -p "$LOGDIR" "$STATE" "$CONTROL/cost"
# shellcheck disable=SC1091
source "$KIT_DIR/bin/env.sh"
# shellcheck disable=SC1091
source "$KIT_DIR/bin/bdjson.sh"

# ---------- logging / alerting ----------
log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$AGENT_ID" "$*" | tee -a "$LOGDIR/loop.log"; }
alert() {
  printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$AGENT_ID" "$*" >> "$CONTROL/alerts.log"
  log "ALERT: $*"
  if [ -n "${NOTIFY_URL:-}" ]; then curl -fsS -m 10 -d "[$AGENT_ID] $*" "$NOTIFY_URL" >/dev/null 2>&1 || true; fi
}
stopping() { [ -f "$CONTROL/STOP" ] || [ -f "$CONTROL/STOP.$ROLE" ]; }

# ---------- beads helpers ----------
show_json()   { bd show "$1" --json 2>/dev/null | bd_unwrap | jq -c 'if type=="array" then .[0] else . end' 2>/dev/null; }
issue_field() { show_json "$1" | jq -r --arg f "$2" '.[$f] // empty' 2>/dev/null; }
has_label()   { show_json "$1" | jq -e --arg l "$2" '(.labels // []) | index($l)' >/dev/null 2>&1; }
is_ready()    { bd ready --limit 200 --json 2>/dev/null | bd_unwrap | jq -e --arg id "$1" '[.[]? | select(.id == $id)] | length > 0' >/dev/null 2>&1; }

# A build role that escalates with needs-team-lead leaves its own claim on the issue; team-lead
# treats an assignee matching a build-role identity that is also the issue's own role:<x> label
# (AGENT_ID may carry a suffix, e.g. engineer-2) as that stale claim. Any other assignee is left alone.
BUILD_ROLE_RE='^(po|architect|engineer|qa|reviewer)([-_.].*)?$'

next_issue() {
  if [ "$ROLE" = "team-lead" ]; then
    bd list --limit 200 --json 2>>"$LOGDIR/bd-err.log" | bd_unwrap | jq -r --arg me "$AGENT_ID" --arg re "$BUILD_ROLE_RE" '
      def stale_escalator: (.assignee // "") as $a | ($a | test($re)) and ([(.labels // [])[] | select(startswith("role:")) | .[5:]] | any(. as $r | $a == $r or ($a | startswith($r + "-") or startswith($r + "_") or startswith($r + "."))));
      [ .[]?
        | select(.status != "closed")
        | select(((.labels // []) | index("needs-human")) | not)
        | select( (((.labels // []) | index("needs-team-lead"))
                   and (((.assignee // "") == "") or (.assignee == $me) or stale_escalator))
                  or ( ((((.labels // []) | any(startswith("role:"))) | not)
                        or ((.labels // []) | index("needs-chain")))
                       and (((.assignee // "") == "") or (.assignee == $me)) ) ) ]
      | .[0].id // empty' 2>/dev/null
    return
  fi
  bd ready --label "role:$ROLE" --limit 50 --json 2>>"$LOGDIR/bd-err.log" | bd_unwrap | jq -r --arg me "$AGENT_ID" '
    [ .[]?
      | select(((.labels // []) | (index("needs-human") != null or index("needs-team-lead") != null)) | not)
      | select(((.assignee // "") == "") or (.assignee == $me)) ]
    | .[0].id // empty' 2>/dev/null
}

claim() {  # atomic claim when unassigned; resume if it was already ours
  local id=$1 who
  who=$(issue_field "$id" assignee)
  if [ -z "$who" ]; then bd update "$id" --claim --assignee "$AGENT_ID" >/dev/null 2>&1
  elif [ "$who" = "$AGENT_ID" ]; then bd update "$id" --status in_progress >/dev/null 2>&1
  elif [ "$ROLE" = team-lead ] && [[ "$who" =~ $BUILD_ROLE_RE ]] && has_label "$id" needs-team-lead \
       && show_json "$id" | jq -e --arg a "$who" '[(.labels // [])[] | select(startswith("role:")) | .[5:]] | any(. as $r | $a == $r or ($a | test("^" + $r + "[-_.]")))' >/dev/null 2>&1; then
    # take over the escalating role's stale claim (compare-and-swap; --force overrides its live claim)
    bd update "$id" --if-assignee "$who" --assignee "$AGENT_ID" --status in_progress --force >/dev/null 2>&1
  else return 1; fi
}

release_stale() {  # anything still in_progress under our name at startup is left over from a crash
  bd list --json 2>/dev/null \
    | bd_unwrap \
    | jq -r --arg me "$AGENT_ID" '.[]? | select(.status=="in_progress" and (.assignee // "")==$me) | .id' \
    | while read -r id; do
        [ -n "$id" ] || continue
        log "releasing stale claim on $id"
        bd update "$id" --status open >/dev/null 2>&1
      done
}

# ---------- throttles ----------
# team-lead-driven WIP throttle (agent-factory-q4tj): po and architect - top-of-funnel - start new
# work only while team-lead judges the engineer/qa/reviewer backlog has room and usage quota is
# likely to last. team-lead is never throttled by this (it has to keep running to produce the
# assessment), and engineer/qa/reviewer are never throttled by it either - only po/architect are
# top-of-funnel. The judgment itself lives entirely in team-lead's own Claude Code session
# (agents/team-lead.md's "Assess the po/architect throttle") - nothing here second-guesses it;
# this is just the plumbing that reads its last recorded decision and keeps it fresh.
THROTTLE_FILE="$CONTROL/throttle.json"

throttle_age() {  # seconds since the last recorded assessment, or a large number if there is none
  local ts epoch
  ts=$(jq -r '.assessed_at // empty' "$THROTTLE_FILE" 2>/dev/null)
  [ -n "$ts" ] || { echo 999999; return; }
  epoch=$(date -d "$ts" +%s 2>/dev/null) || { echo 999999; return; }
  echo $(( $(date +%s) - epoch ))
}

throttle_ok() {  # false only for po/architect, and only once team-lead has recorded idle:true.
                  # No assessment yet (fresh run, or team-lead falling behind) fails OPEN - po and
                  # architect proceed. Deliberate: DAILY_BUDGET_USD and the Claude Code plan usage
                  # limit (both enforced unconditionally elsewhere in this loop) are the hard stops
                  # against runaway spend; this is a softer "don't start work you can't finish"
                  # layer on top of those, and a missing/stale file must not silently wedge the
                  # whole factory at the top of the funnel just because team-lead's own loop
                  # hiccuped - see throttle_stale_alert() below for how a human finds out that
                  # happened instead.
  case "$ROLE" in po|architect) ;; *) return 0 ;; esac
  [ -f "$THROTTLE_FILE" ] || return 0
  jq -e '.idle != true' "$THROTTLE_FILE" >/dev/null 2>&1
}

throttle_stale_alert() {  # team-lead only, see main loop - alerts once when assessments stop
                           # arriving, resets once they resume so a later real staleness re-alerts
  local age; age=$(throttle_age)
  if [ "$age" -ge "$THROTTLE_ALERT_STALE_SECS" ]; then
    [ "$throttle_stale_alerted" = 1 ] || alert "throttle assessment stale (${age}s > ${THROTTLE_ALERT_STALE_SECS}s) - po/architect are running unthrottled in the meantime"
    throttle_stale_alerted=1
  else
    throttle_stale_alerted=0
  fi
}

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
quota_hit_message() {  # quota_hit_message FILE... -> first matching line (bounded, single-line), or empty
  local pattern
  if [ "$HARNESS" = "copilot" ]; then
    pattern='quota_exceeded|you have no quota[^"]{0,200}|exceeded your [a-z]+ rate limit[^"]{0,200}|reached the rate limit[^"]{0,200}'
  else
    pattern='hit your [a-z]+ limit[^"]{0,200}|usage limit[^"]{0,200}|limit reached[^"]{0,200}|rate limit exceeded[^"]{0,200}'
  fi
  grep -ihEo "$pattern" "$@" 2>/dev/null \
    | head -1 | tr -d '\r' | tr '\n\t' '  ' | cut -c1-200
}

quota_hit_from_stream() {  # Claude Code only (stream-json's structured result event has no Copilot
                           # equivalent - see run_harness_session, which never calls this for copilot).
                           # quota_hit_from_stream FILE -> limit message if the run ENDED in an error result, or empty
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

build_throttle_prompt() {
  cat "$KIT_DIR/agents/team-lead.md"
  printf '\n\n---\nNo bd issue this session: assess the po/architect throttle now (see "Assess the po/architect throttle" above), then record it with bin/set-throttle.sh - that is the only place this decision is recorded, so do not skip it.\nRepository: %s (your own clone; remote "origin"). Shared conventions are in CLAUDE.md. KIT_DIR=%s PROJECT_DIR=%s\n' "$REPO" "$KIT_DIR" "$PROJECT_DIR"
}

run_harness_session() {  # run_harness_session LOGNAME PROMPT -> sets LAST_RUN_QUOTA_MSG (empty
                         # unless this run hit a usage limit); shared by run_agent() (one bd issue)
                         # and run_throttle_assessment() (no bd issue).
  local logname=$1 prompt=$2 logfile errfile outfile cost
  errfile=$(mktemp); outfile=$(mktemp)
  if [ "$HARNESS" = "copilot" ]; then
    logfile="$LOGDIR/$(date +%F).$logname.log"   # plain text, not stream-json - see README
    local args=(-p "$prompt" --allow-all-tools --no-ask-user -s)
    [ -n "$MODEL" ] && args+=(--model "$MODEL")
    ( cd "$REPO" && timeout "$ITERATION_TIMEOUT" copilot "${args[@]}" 2>"$errfile" ) \
      | tee -a "$logfile" "$outfile"
    cost=0   # Copilot CLI reports no per-session USD figure - see README "Guardrails built in"
    LAST_RUN_QUOTA_MSG=$(quota_hit_message "$errfile")
  else
    logfile="$LOGDIR/$(date +%F).$logname.jsonl"
    local args=(-p "$prompt" --dangerously-skip-permissions --max-turns "$MAX_TURNS"
                --output-format stream-json --verbose)
    [ -n "$MODEL" ] && args+=(--model "$MODEL")
    ( cd "$REPO" && timeout "$ITERATION_TIMEOUT" claude "${args[@]}" 2>"$errfile" ) \
      | tee -a "$logfile" "$outfile" | jq -R -r --unbuffered "$RENDER" 2>/dev/null
    cost=$(jq -rs '[.[] | select(.type=="result")] | last | .total_cost_usd // 0' "$logfile" 2>/dev/null)
    LAST_RUN_QUOTA_MSG=$(quota_hit_message "$errfile")   # stderr, else this run's final error result
    [ -n "$LAST_RUN_QUOTA_MSG" ] || LAST_RUN_QUOTA_MSG=$(quota_hit_from_stream "$outfile")
  fi
  echo "${cost:-0}" >> "$CONTROL/cost/$ROLE.$(date +%F)"
  cat "$errfile" >> "$LOGDIR/claude-err.log"
  rm -f "$errfile" "$outfile"
}

run_agent() { run_harness_session "$1" "$(build_prompt "$1")"; }               # sets LAST_RUN_QUOTA_MSG
run_throttle_assessment() { run_harness_session throttle "$(build_throttle_prompt)"; }  # sets LAST_RUN_QUOTA_MSG

# ---------- outcome handling ----------
is_conflict_rework() { has_label "$1" stage:rework && has_label "$1" merge-conflict; }
restart_story() {  # restart_story ID REASON - see bin/restart-story.sh
  "$KIT_DIR/bin/restart-story.sh" "$1" "$2" >>"$LOGDIR/loop.log" 2>&1 \
    && alert "$1: merge-conflict rework failed ($2); story restarted" \
    || alert "$1: restart-story.sh failed ($2); needs a human"
}
handle_outcome() {  # 0 = the agent did something legitimate with the issue, 1 = it did not
  local id=$1 st
  st=$(issue_field "$id" status)
  if [ "$st" = "closed" ]; then log "$id closed (handed off)"; return 0; fi
  if is_conflict_rework "$id" && { has_label "$id" conflict-unresolvable || has_label "$id" needs-human; }; then
    restart_story "$id" unresolvable; return 0
  fi
  # Backstop for both escalation labels; needs-team-lead skipped for ROLE=team-lead (its own queue).
  local esc
  for esc in needs-human needs-team-lead; do
    [ "$esc" = needs-team-lead ] && [ "$ROLE" = team-lead ] && continue
    has_label "$id" "$esc" || continue
    if [ -z "$(issue_field "$id" notes)" ]; then
      bd update "$id" --append-notes "agent-loop: $AGENT_ID labelled this $esc but left no note explaining what it needs - see the session transcript. Transcript: $LOGDIR/$(date +%F).$id.jsonl" >/dev/null 2>&1
      alert "$id flagged $esc WITHOUT an explanation from the agent - see the transcript"
    else
      alert "$id flagged $esc by the agent"
    fi
    return 0
  done
  if [ "$st" = "open" ] && ! is_ready "$id"; then log "$id parked behind new blockers (rework/handoff)"; return 0; fi
  if [ "$ROLE" = "team-lead" ] && ! has_label "$id" needs-team-lead; then
    # hand the issue back to the role it was rerouted to: our claim would hide it from its queue
    if show_json "$id" | jq -e --arg me "$AGENT_ID" '.assignee == $me and ((.labels // []) | any(startswith("role:")))' >/dev/null 2>&1; then
      bd update "$id" --if-assignee "$AGENT_ID" --assignee "" --status open >/dev/null 2>&1
    fi
    log "$id triaged (needs-team-lead cleared)"; return 0
  fi
  return 1
}

record_failure() {
  local id=$1 f="$STATE/attempts.$1" n esc_label
  n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"
  bd update "$id" --status open >/dev/null 2>&1
  if [ "$n" -ge "$MAX_ATTEMPTS_PER_ISSUE" ]; then
    # team-lead keeps needs-human (agent-factory-dx0); the five build roles get needs-team-lead.
    esc_label="needs-team-lead"; [ "$ROLE" = "team-lead" ] && esc_label="needs-human"
    bd update "$id" --append-notes "agent-loop: not completed after $n attempt(s) by $AGENT_ID (session ended without closing or explaining why). Transcript: $LOGDIR/$(date +%F).$id.jsonl" >/dev/null 2>&1
    bd label add "$id" "$esc_label" >/dev/null 2>&1
    alert "$id not completed after $n attempts; labelled $esc_label"
    if is_conflict_rework "$id"; then restart_story "$id" attempt-cap; fi
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
    sync_dir "$CONTAINER_HOME/.copilot-host" "$CONTAINER_HOME/.copilot" "~/.copilot"
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
    if [ "$HARNESS" = "copilot" ]; then
      preflight_out=$(timeout 180 copilot -p "Reply with the single word OK." --allow-all-tools --no-ask-user -s 2>&1)
    else
      preflight_out=$(timeout 180 claude -p "Reply with the single word OK." --dangerously-skip-permissions --max-turns 1 2>&1)
    fi
    [ $? -eq 0 ] && break
    preflight_hit=$(quota_hit_message <(printf '%s' "$preflight_out"))
    if [ -n "$preflight_hit" ]; then
      wait_s=$(usage_limit_wait_seconds "$preflight_hit")
      alert "preflight: usage limit hit ($preflight_hit); waiting ${wait_s}s before retrying startup"
      sleep "$wait_s"
      continue
    fi
    alert "preflight: harness failed to run (check auth): ${preflight_out:0:200}"
    exit 3
  done
fi

release_stale
log "started: role=$ROLE harness=$HARNESS model=${MODEL:-<harness default>} max_turns=$MAX_TURNS timeout=$ITERATION_TIMEOUT"

# ---------- main loop ----------
fails=0
idle_logged=0
throttle_idle_logged=0
throttle_stale_alerted=0
while :; do
  if stopping; then log "STOP requested; exiting"; exit 0; fi
  if ! budget_ok; then alert "daily budget reached ($(spent_today) USD); pausing 30 min"; sleep 1800; continue; fi

  [ "$ROLE" = "team-lead" ] && throttle_stale_alert

  if ! throttle_ok; then
    if [ "$throttle_idle_logged" != 1 ]; then
      log "idle: team-lead throttle holding $ROLE back ($(jq -r '.reason // "no reason recorded"' "$THROTTLE_FILE" 2>/dev/null))"
      throttle_idle_logged=1
    fi
    sleep "$IDLE_SLEEP"; continue
  fi
  throttle_idle_logged=0

  id=$(next_issue)
  if [ -z "$id" ]; then
    if [ "$ROLE" = "team-lead" ] && [ "$(throttle_age)" -ge "$THROTTLE_STALE_SECS" ]; then
      log "no triage work; throttle assessment due (last one $(throttle_age)s ago)"
      if sync_repo; then
        run_throttle_assessment
        if [ -n "$LAST_RUN_QUOTA_MSG" ]; then
          wait_s=$(usage_limit_wait_seconds "$LAST_RUN_QUOTA_MSG")
          alert "throttle assessment: usage limit hit ($LAST_RUN_QUOTA_MSG); waiting ${wait_s}s"
          sleep "$wait_s"; continue
        fi
      else
        log "git sync failed; throttle assessment skipped this cycle"
      fi
      sleep "$IDLE_SLEEP"; continue
    fi
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
