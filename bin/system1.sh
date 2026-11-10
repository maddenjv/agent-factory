#!/usr/bin/env bash
# Usage: system1.sh <issue-id>
# "System 1" team-lead (agent-factory-73cw): when SYSTEM1_ENABLED=1, bin/agent-loop.sh runs this
# instead of a capable-model team-lead session for an issue-driven decision. A small model (served by
# an OpenAI-compatible chat API: Docker Model Runner locally, or any hosted endpoint) is asked for ONE
# JSON decision; this script validates it and applies it with bd/git. Any failure -> needs-human with
# a note (never the capable-model session). See docs/design/agent-factory-73cw.md.
set -uo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/bdjson.sh"

KIT_DIR="${KIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REPO="${REPO:-$PWD}"
SYSTEM1_URL="${SYSTEM1_URL:-http://host.docker.internal:12434/engines/v1}"
SYSTEM1_MODEL="${SYSTEM1_MODEL:-hf.co/LiquidAI/d1-2B}"
SYSTEM1_API_KEY="${SYSTEM1_API_KEY:-}"
SYSTEM1_TIMEOUT="${SYSTEM1_TIMEOUT:-60}"
CAP=6000

ID="" ; RAW="" ; ISSUE="" ; KIND=""
PROV=""

log() { echo "[system1 $(date +%T)] $*"; }
trunc() { printf '%s' "$1" | head -c "${2:-$CAP}"; }

has_label() { printf '%s' "$ISSUE" | jq -e --arg l "$1" '(.labels // []) | index($l)' >/dev/null 2>&1; }
label_with_prefix() { printf '%s' "$ISSUE" | jq -r --arg p "$1" '(.labels // [])[] | select(startswith($p))' | head -1; }

fail() {  # fail MSG: terminal outcome = needs-human with the failure and raw model output
  local raw="${RAW:-}"; [ -n "$raw" ] || raw="(none)"
  log "FAIL $ID: $1"
  git -C "$REPO" checkout -q -f main 2>/dev/null
  bd update "$ID" --append-notes "System 1 ($SYSTEM1_MODEL) failed: $1. Raw output: $(trunc "$raw" 2000)" >/dev/null 2>&1
  bd label remove "$ID" needs-team-lead >/dev/null 2>&1
  bd label add "$ID" needs-human >/dev/null 2>&1
  exit 0
}

classify() {
  if has_label needs-team-lead; then KIND=route
  elif [ -z "$(label_with_prefix role:)" ]; then
    if [ -n "$(label_with_prefix story:)" ]; then KIND=route; else KIND=intake; fi
  else KIND=route   # routed already, no escalation: treat as a routing question
  fi
}

system_prompt() {
  case "$KIND" in
    route) echo 'You are the routing step of a software-factory. Decide which role should handle the issue next. Roles and stages: po (no stage), architect/design, qa/tests, engineer/implement, qa/verify, reviewer/review, or rework by architect|engineer|qa|reviewer. If you cannot decide, choose human. Reply with exactly one JSON object and no prose: {"decision":"route","role":"<role>","stage":"<stage or empty for po>","reason":"<why>"} or {"decision":"human","reason":"<why>"}.' ;;
    intake) echo 'You are the intake step of a software-factory. Decide how to handle a new unrouted issue. "po": it needs a product owner to write the story. "direct": it already has enough context (e.g. a bug with log snippets or a log path) to skip the product owner. "human": you cannot tell. Reply with exactly one JSON object and no prose: {"decision":"po"|"direct"|"human","reason":"<why>"}.' ;;
  esac
}

user_prompt() {
  local out
  out=$(printf '%s' "$ISSUE" | jq -r --argjson c "$CAP" '
    "Issue: \(.id // "") \(.title // "")\nLabels: \((.labels // []) | join(", "))\nDescription:\n\((.description // "")[0:$c])\nNotes:\n\((.notes // "")[0:$c])\nRecent comments:\n\(((.comments // []) | .[-10:] | map(if type=="object" then (.text // .body // tostring) else tostring end) | join("\n---\n"))[0:$c])"')
  local sid; sid=$(label_with_prefix story: | sed 's/^story://')
  if [ -n "$sid" ] && [ "$KIND" != intake ]; then
    local doc="$REPO/docs/stories/$sid.md"
    [ -f "$doc" ] && out="$out"$'\n\nStory doc header:\n'"$(head -20 "$doc")"
    out="$out"$'\n\nIssues in this story:\n'"$(bd list --label "story:$sid" --json 2>/dev/null | bd_unwrap | jq -r '.[]? | "\(.id) \(.status // "") \((.labels // []) | map(select(startswith("role:") or startswith("stage:"))) | join(","))"' 2>/dev/null)"
  fi
  trunc "$out" $((CAP * 2))
}

ask_model() {  # sets RAW to the model\ reply reply text; fail on any transport problem
  local body resp rc args content
  body=$(jq -n --arg m "$SYSTEM1_MODEL" --arg s "$(system_prompt)" --arg u "$(user_prompt)" \
    '{model:$m,messages:[{role:"system",content:$s},{role:"user",content:$u}],temperature:0,stream:false}')
  args=(-sS --connect-timeout 10 --max-time "$SYSTEM1_TIMEOUT" -H 'Content-Type: application/json')
  [ -n "$SYSTEM1_API_KEY" ] && args+=(-H "Authorization: Bearer $SYSTEM1_API_KEY")
  resp=$(printf '%s' "$body" | curl "${args[@]}" -f -d @- "${SYSTEM1_URL%/}/chat/completions" 2>&1); rc=$?
  RAW="$resp"
  [ "$rc" = 0 ] || fail "request to ${SYSTEM1_URL%/}/chat/completions failed (curl exit $rc)"
  content=$(printf '%s' "$resp" | jq -er '.choices[0].message.content' 2>/dev/null) || fail "response is not a chat completion with message content"
  RAW="$content"
  [ -n "${content//[[:space:]]/}" ] || fail "model returned empty content"
}

extract_json() {  # RAW -> DECISION (first {...} object, fences tolerated)
  local t
  t=$(printf '%s\n' "${RAW//$'\r'/}" | grep -v '^[[:space:]]*```')
  [[ "$t" == *"{"* && "$t" == *"}"* ]] || fail "model output contains no JSON object"
  t="{${t#*\{}"; t="${t%\}*}}"
  DECISION=$(printf '%s' "$t" | jq -ce 'select(type=="object")' 2>/dev/null) && [ -n "$DECISION" ] \
    || fail "model output is not a valid JSON object"
}

jget() { printf '%s' "$DECISION" | jq -r "$1" 2>/dev/null; }
reason_ok() { REASON=$(jget '.reason // empty | select(type=="string")'); [ -n "${REASON//[[:space:]]/}" ] || fail "decision has no reason"; }

stage_ok() {  # role stage -> 0 if consistent
  case "$1/$2" in
    po/|architect/design|qa/tests|qa/verify|engineer/implement|reviewer/review) return 0 ;;
    architect/rework|engineer/rework|qa/rework|reviewer/rework) return 0 ;;
  esac
  return 1
}

route_label_reset() {
  local l
  for l in $(printf '%s' "$ISSUE" | jq -r '(.labels // [])[] | select(startswith("role:") or startswith("stage:"))'); do
    bd label remove "$ID" "$l" >/dev/null 2>&1
  done
}

apply_human() {
  bd update "$ID" --append-notes "$PROV: needs a human - $REASON" >/dev/null 2>&1
  bd label remove "$ID" needs-team-lead >/dev/null 2>&1
  bd label add "$ID" needs-human >/dev/null 2>&1
  log "$ID -> needs-human"
}

do_route() {
  local d role stage
  d=$(jget '.decision // empty')
  reason_ok
  case "$d" in
    human) apply_human; return ;;
    route) ;;
    *) fail "invalid decision '$d' for a routing question" ;;
  esac
  role=$(jget '.role // empty'); stage=$(jget '.stage // empty')
  stage_ok "$role" "$stage" || fail "invalid role/stage pair '$role'/'$stage'"
  has_label needs-team-lead && bd label remove "$ID" needs-team-lead >/dev/null 2>&1
  route_label_reset
  bd label add "$ID" "role:$role" >/dev/null 2>&1
  [ -n "$stage" ] && bd label add "$ID" "stage:$stage" >/dev/null 2>&1
  bd comment "$ID" "$PROV routed to role:$role${stage:+ stage:$stage} - $REASON" >/dev/null 2>&1
  bd unclaim "$ID" >/dev/null 2>&1
  log "$ID -> role:$role stage:$stage"
}

story_doc() {  # story_doc TITLE DESCRIPTION
  cat <<DOC
> Generated without PO from issue $ID - System 1 judged the issue had enough context.

# $ID: $1

## Story
$1

## Context
$2

## Acceptance criteria
1. Given the request in Context, when the work is done, then what it describes is resolved; QA derives testable criteria from Context.

## Out of scope
- Anything the issue does not state.
DOC
}

direct_build() {
  local title desc doc out
  title=$(printf '%s' "$ISSUE" | jq -r '.title // ""'); desc=$(printf '%s' "$ISSUE" | jq -r '.description // ""')
  cd "$REPO" || fail "cannot enter $REPO"
  git fetch -q origin || fail "git fetch failed"
  if git rev-parse -q --verify "refs/remotes/origin/story/$ID" >/dev/null; then
    git checkout -q -f -B "story/$ID" "origin/story/$ID" || fail "cannot check out story/$ID"
  else
    git checkout -q -f -B "story/$ID" origin/main || fail "cannot create story/$ID from origin/main"
  fi
  doc="docs/stories/$ID.md"
  if [ ! -f "$doc" ]; then
    mkdir -p docs/stories
    story_doc "$title" "$desc" > "$doc"
    git add "$doc" && git commit -q -m "[$ID] Story generated without PO" || fail "git commit of $doc failed"
  fi
  git push -q -u origin "story/$ID" || fail "git push of story/$ID failed"
  git checkout -q -f main || fail "cannot return to main"
  out=$("$KIT_DIR/bin/new-story.sh" "$ID" "$title" 2>&1) || fail "new-story.sh failed: $(trunc "$out" 500)"
  bd label add "$ID" "story:$ID" >/dev/null 2>&1
  bd comment "$ID" "$PROV: no PO needed, built story doc and chain directly - $REASON. $(printf '%s' "$out" | head -1)" >/dev/null 2>&1
  bd close "$ID" >/dev/null 2>&1
  log "$ID -> direct story chain"
}

do_intake() {
  local d; d=$(jget '.decision // empty')
  reason_ok
  case "$d" in
    human) apply_human ;;
    po)
      bd label add "$ID" role:po >/dev/null 2>&1
      bd comment "$ID" "$PROV routed to role:po - $REASON" >/dev/null 2>&1
      bd unclaim "$ID" >/dev/null 2>&1
      log "$ID -> role:po" ;;
    direct) direct_build ;;
    *) fail "invalid decision '$d' for an intake question" ;;
  esac
}

main() {
  ID=${1:?usage: system1.sh <issue-id>}
  if [ "${SYSTEM1_ENABLED:-}" != 1 ]; then fail "System 1 enabled but not configured: SYSTEM1_ENABLED is not 1"; fi
  [ -n "$SYSTEM1_URL" ] && [ -n "$SYSTEM1_MODEL" ] || fail "System 1 enabled but not configured: SYSTEM1_URL/SYSTEM1_MODEL empty"
  ISSUE=$(bd show "$ID" --json 2>/dev/null | bd_unwrap | jq -c 'if type=="array" then .[0] else . end' 2>/dev/null)
  [ -n "$ISSUE" ] && [ "$ISSUE" != null ] || fail "cannot read issue $ID"
  PROV="System 1 ($SYSTEM1_MODEL @ $(printf '%s' "$SYSTEM1_URL" | sed -E 's#^[a-z]+://([^/]+).*#\1#'))"
  classify
  ask_model
  extract_json
  case "$KIND" in
    route) do_route ;;
    intake) do_intake ;;
  esac
}

[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
exit 0
