#!/usr/bin/env bash
# Usage: system1-class.sh <issue-id>
# Per-task model class (agent-factory-hcql): asks the System 1 model whether the issue needs a
# high, medium or low cost class of model. Prints exactly one of high|medium|low on stdout and exits 0;
# on ANY problem prints nothing on stdout, a one-line reason on stderr, exits 1. Never touches bd
# labels/notes. See docs/design/agent-factory-hcql.md.
set -uo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/bdjson.sh"

SYSTEM1_URL="${SYSTEM1_URL:-http://host.docker.internal:8080}"
SYSTEM1_MODEL="${SYSTEM1_MODEL:-ggml-org/vllm-d3-mini-GGUF}"
SYSTEM1_API_KEY="${SYSTEM1_API_KEY:-}"
SYSTEM1_TIMEOUT="${SYSTEM1_TIMEOUT:-60}"
CAP=6000

QUESTIONS='{"class":{"type":"choice","instructions":"Choose which cost class of model a software task needs.","criteria":{"low":"trivial/mechanical (doc or comment edit, one-line fix, rename, config tweak)","medium":"ordinary feature, bug fix or test work in a known area","high":"hard: new architecture or cross-cutting design, subtle debugging, security, large refactor"}}}'

die() { echo "$*" >&2; return 1; }

# parse_class RESPONSE_BODY -> prints high|medium|low (from .answers.class.choice), else returns 1.
parse_class() {
  local w
  w=$(printf '%s' "$1" | jq -er '.answers.class.choice | select(type=="string")' 2>/dev/null) || return 1
  w=$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  case "$w" in high|medium|low) printf '%s' "$w" ;; *) return 1 ;; esac
}

main() {
  local id=${1:-} issue body resp rc args cls user base ep
  [ -n "$id" ] || { die "usage: system1-class.sh <issue-id>"; return 1; }
  [ -n "$SYSTEM1_URL" ] && [ -n "$SYSTEM1_MODEL" ] || { die "not configured"; return 1; }
  issue=$(bd show "$id" --json 2>/dev/null | bd_unwrap | jq -c 'if type=="array" then .[0] else . end' 2>/dev/null)
  [ -n "$issue" ] && [ "$issue" != null ] || { die "cannot read issue"; return 1; }
  user=$(printf '%s' "$issue" | jq -r --argjson c "$CAP" \
    '"Issue: \(.id // "") \(.title // "")\nLabels: \((.labels // []) | join(", "))\nDescription:\n\((.description // "")[0:$c])\nNotes:\n\((.notes // "")[0:$c])"' 2>/dev/null) \
    || { die "cannot read issue"; return 1; }
  body=$(jq -n --arg m "$SYSTEM1_MODEL" --arg st "$user" --argjson q "$QUESTIONS" '{model:$m,state:$st,questions:$q}') \
    || { die "cannot build request"; return 1; }
  args=(-sS -f --connect-timeout 10 --max-time "$SYSTEM1_TIMEOUT" -H 'Content-Type: application/json')
  [ -n "$SYSTEM1_API_KEY" ] && args+=(-H "Authorization: Bearer $SYSTEM1_API_KEY")
  base="${SYSTEM1_URL%/}"
  case "$base" in */systemone) ep="$base" ;; *) ep="$base/v1/systemone" ;; esac
  resp=$(printf '%s' "$body" | curl "${args[@]}" -d @- "$ep" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || { die "request failed (curl exit $rc)"; return 1; }
  cls=$(parse_class "$resp") || { die "unparseable answer: $(printf '%s' "$resp" | tr '\n\r' '  ' | head -c 80)"; return 1; }
  printf '%s\n' "$cls"
}

[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
