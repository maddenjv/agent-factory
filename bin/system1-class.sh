#!/usr/bin/env bash
# Usage: system1-class.sh <issue-id>
# Per-task model class (agent-factory-hcql): asks the System 1 model whether the issue needs a
# high, medium or low cost class of model. Prints exactly one of high|medium|low on stdout and exits 0;
# on ANY problem prints nothing on stdout, a one-line reason on stderr, exits 1. Never touches bd
# labels/notes. See docs/design/agent-factory-hcql.md.
set -uo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/bdjson.sh"

SYSTEM1_URL="${SYSTEM1_URL:-http://host.docker.internal:12434/v1}"
SYSTEM1_MODEL="${SYSTEM1_MODEL:-LiquidAI/d1-2B}"
SYSTEM1_API_KEY="${SYSTEM1_API_KEY:-}"
SYSTEM1_TIMEOUT="${SYSTEM1_TIMEOUT:-60}"
CAP=6000

SYSTEM_PROMPT='You choose which cost class of model a software task needs. low = trivial/mechanical (doc or comment edit, one-line fix, rename, config tweak). medium = ordinary feature, bug fix or test work in a known area. high = hard: new architecture or cross-cutting design, subtle debugging, security, large refactor. Reply with exactly one word: high, medium or low.'

die() { echo "$*" >&2; return 1; }

# parse_class TEXT -> prints high|medium|low, else returns 1.
# Accepts the bare word (case, whitespace, quotes, fences, trailing punctuation tolerated) or a JSON
# object whose class key (class|model_class|complexity|decision) holds the word (QA acceptance tests
# send JSON replies).
parse_class() {
  local t=$1 w
  t=$(printf '%s\n' "${t//$'\r'/}" | grep -v '^[[:space:]]*```')
  if [[ "$t" == *"{"* ]]; then
    w=$(printf '%s' "$t" | jq -er 'select(type=="object") | (.class // .model_class // .complexity // .decision) | select(type=="string")' 2>/dev/null) || return 1
  else
    w=$t
  fi
  w=$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]"'"'"'`' | sed -E 's/[[:punct:]]+$//')
  case "$w" in high|medium|low) printf '%s' "$w" ;; *) return 1 ;; esac
}

main() {
  local id=${1:-} issue body resp rc content args cls user
  [ -n "$id" ] || { die "usage: system1-class.sh <issue-id>"; return 1; }
  [ -n "$SYSTEM1_URL" ] && [ -n "$SYSTEM1_MODEL" ] || { die "not configured"; return 1; }
  issue=$(bd show "$id" --json 2>/dev/null | bd_unwrap | jq -c 'if type=="array" then .[0] else . end' 2>/dev/null)
  [ -n "$issue" ] && [ "$issue" != null ] || { die "cannot read issue"; return 1; }
  user=$(printf '%s' "$issue" | jq -r --argjson c "$CAP" \
    '"Issue: \(.id // "") \(.title // "")\nLabels: \((.labels // []) | join(", "))\nDescription:\n\((.description // "")[0:$c])\nNotes:\n\((.notes // "")[0:$c])"' 2>/dev/null) \
    || { die "cannot read issue"; return 1; }
  body=$(jq -n --arg m "$SYSTEM1_MODEL" --arg s "$SYSTEM_PROMPT" --arg u "$user" \
    '{model:$m,messages:[{role:"system",content:$s},{role:"user",content:$u}],temperature:0,stream:false}') \
    || { die "cannot build request"; return 1; }
  args=(-sS -f --connect-timeout 10 --max-time "$SYSTEM1_TIMEOUT" -H 'Content-Type: application/json')
  [ -n "$SYSTEM1_API_KEY" ] && args+=(-H "Authorization: Bearer $SYSTEM1_API_KEY")
  resp=$(printf '%s' "$body" | curl "${args[@]}" -d @- "${SYSTEM1_URL%/}/chat/completions" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || { die "request failed (curl exit $rc)"; return 1; }
  content=$(printf '%s' "$resp" | jq -er '.choices[0].message.content | select(type=="string")' 2>/dev/null) \
    || { die "response is not a chat completion"; return 1; }
  cls=$(parse_class "$content") || { die "unparseable answer: $(printf '%s' "$content" | tr '\n\r' '  ' | head -c 80)"; return 1; }
  printf '%s\n' "$cls"
}

[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
