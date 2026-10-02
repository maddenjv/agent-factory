#!/usr/bin/env bash
# Acceptance tests for agent-factory-7yn3: team-lead claims a needs-team-lead issue that is still
# assigned to the escalating build role (exact shape of agent-factory-ar5n), and never wedges on
# an issue it cannot claim. One function per acceptance criterion in
# docs/stories/agent-factory-7yn3.md (test_acN_...). Derived only from the story, not the design.
#
# Behavioural: runs the real bin/agent-loop.sh with ROLE=team-lead against a stateful stub `bd`
# (applies `bd update` to a JSON fixture; refuses --assignee over another actor's in_progress claim
# without --force, honours --if-assignee with exit 13) and a stub `claude` that records a run and
# stops the loop. Same harness style as tests/agent-factory-wnju_test.sh.
#
# Run directly: bash tests/agent-factory-7yn3_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

cat > "$TMP/stubs/bd" <<'STUB'
#!/usr/bin/env bash
echo "bd $*" >> "$W/bdlog"
F="$W/issues.json"
case "$1" in
  ready|list)
    label=""; args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do [ "${args[$i]}" = "--label" ] && label="${args[$((i + 1))]}"; done
    if [ -n "$label" ]; then jq -c --arg l "$label" '[.[] | select((.labels // []) | index($l))]' "$F"; else cat "$F"; fi ;;
  show) jq -c --arg id "$2" '[.[] | select(.id == $id)]' "$F" ;;
  update)
    id=$2; shift 2
    assignee=""; status=""; guard=""; have_guard=0; force=0; claim=0; set_a=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --assignee|-a) assignee=$2; set_a=1; shift 2;;
        --status|-s) status=$2; shift 2;;
        --if-assignee) guard=$2; have_guard=1; shift 2;;
        --force) force=1; shift;;
        --claim) claim=1; shift;;
        *) shift;;
      esac
    done
    cur=$(jq -r --arg id "$id" '.[] | select(.id==$id) | .assignee // ""' "$F")
    st=$(jq -r --arg id "$id" '.[] | select(.id==$id) | .status' "$F")
    if [ -n "${UPDATE_FAIL_ID:-}" ] && [ "$id" = "$UPDATE_FAIL_ID" ]; then echo "Error: cannot update $id" >&2; exit 1; fi
    if [ "$have_guard" = 1 ] && [ "$cur" != "$guard" ]; then echo "Error: assignee mismatch" >&2; exit 13; fi
    if [ "$claim" = 1 ] && [ -n "$cur" ] && [ "$cur" != "$assignee" ]; then echo "Error: already claimed by $cur" >&2; exit 1; fi
    if [ "$set_a" = 1 ] && [ "$st" = in_progress ] && [ -n "$cur" ] && [ "$cur" != "$assignee" ] && [ "$force" = 0 ]; then
      echo "Error: $id is claimed by $cur (use --force)" >&2; exit 1; fi
    [ "$set_a" = 1 ] && jq --arg id "$id" --arg a "$assignee" 'map(if .id==$id then .assignee=$a else . end)' "$F" > "$F.t" && mv "$F.t" "$F"
    [ -n "$status" ] && jq --arg id "$id" --arg s "$status" 'map(if .id==$id then .status=$s else . end)' "$F" > "$F.t" && mv "$F.t" "$F"
    ;;
esac
exit 0
STUB
chmod +x "$TMP/stubs/bd"

cat > "$TMP/stubs/claude" <<'STUB'
#!/usr/bin/env bash
echo x >> "$W/claude_runs"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0}'
touch "$W/data/control/STOP"
exit 0
STUB
chmod +x "$TMP/stubs/claude"

ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN" && git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# run_loop ISSUES_JSON [TIMEOUT] [UPDATE_FAIL_ID]
run_loop() {
  W="$TMP/run.$RANDOM"; mkdir -p "$W/data/control" "$W/home"; : > "$W/bdlog"; : > "$W/claude_runs"
  printf '%s' "$1" > "$W/issues.json"
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home" UPDATE_FAIL_ID="${3:-}"
    PATH="$TMP/stubs:$PATH" ROLE=team-lead KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 IDLE_SLEEP=1 \
      timeout "${2:-30}" bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || true
}
assignee_of() { jq -r --arg id "$1" '.[] | select(.id==$id) | .assignee // ""' "$W/issues.json"; }
ran_triage() { grep -q "\] START " "$W/out"; }

# agent-factory-ar5n's exact shape; $3 = labels JSON array, $2 = assignee
stuck() {  # stuck ID ASSIGNEE LABELS_JSON
  jq -nc --arg id "$1" --arg a "$2" --argjson l "$3" \
    '{id:$id,status:"in_progress",assignee:$a,type:"task",labels:$l,lease_expires_at:"2020-01-01T00:00:00Z"}'
}
AR5N_LABELS='["needs-team-lead","role:qa","stage:verify","story:agent-factory-lv8s"]'

check_claimed() {  # check_claimed NAME EXPECTED_ASSIGNED_ID
  if ran_triage && [ "$(assignee_of "$2")" = team-lead ]; then pass "$1"
  else fail "$1 - assignee='$(assignee_of "$2")' triage_ran=$(ran_triage && echo yes || echo no); bdlog: $(cat "$W/bdlog"); out: $(tail -5 "$W/out")"; fi
}

test_ac1_team_lead_claims_issue_assigned_to_escalating_build_role() {
  local role
  for role in qa engineer architect reviewer po; do
    run_loop "[$(stuck x1 "$role" "[\"needs-team-lead\",\"role:$role\"]")]"
    check_claimed "ac1: team-lead claims in_progress needs-team-lead issue assigned to $role" x1
  done
}

test_ac1_ar5n_exact_shape() {
  run_loop "[$(stuck agent-factory-ar5n qa "$AR5N_LABELS")]"
  check_claimed "ac1: exact agent-factory-ar5n shape (qa, needs-team-lead, role:qa, stage:verify, story:...) is claimed" agent-factory-ar5n
}

test_ac1_suffixed_assignee() {
  run_loop "[$(stuck x2 engineer-2 '["needs-team-lead","role:engineer","stage:implement","story:s"]')]"
  check_claimed "ac1: assignee with instance suffix (engineer-2) is claimed" x2
}

test_ac2_expired_lease_never_blocks_takeover() {
  run_loop "[$(stuck x3 qa "$AR5N_LABELS")]"
  check_claimed "ac2: issue whose assignee lease expired is claimed" x3
}

test_ac3_stage_and_story_labels_do_not_matter() {
  run_loop "[$(stuck x4 qa '["needs-team-lead","role:qa","stage:rework","story:abc","merge-conflict","extra"]')]"
  check_claimed "ac3: extra stage:*/story:* and other labels do not block the claim" x4
}

test_ac4_other_live_agent_is_not_taken() {
  run_loop "[$(stuck x5 some-other-agent '["needs-team-lead","role:qa","stage:verify","story:s"]')]" 8
  if ! ran_triage && [ "$(assignee_of x5)" = some-other-agent ]; then pass "ac4: issue held by a non-team-lead, non-escalating agent is left alone"
  else fail "ac4: issue held by some-other-agent was taken: assignee='$(assignee_of x5)'"; fi
  # escalating role's name but a different role:* label: also not the escalating role
  run_loop "[$(stuck x6 engineer '["needs-team-lead","role:qa","stage:verify","story:s"]')]" 8
  if ! ran_triage && [ "$(assignee_of x6)" = engineer ]; then pass "ac4: issue held by engineer but labelled role:qa is left alone"
  else fail "ac4: issue held by engineer with role:qa was taken: assignee='$(assignee_of x6)'"; fi
}

test_ac5_failed_claim_is_logged_with_reason_and_loop_moves_on() {
  local issues
  issues="[$(stuck bad1 qa "$AR5N_LABELS"),$(jq -nc '{id:"good1",status:"open",assignee:"",type:"task",labels:["needs-team-lead","role:engineer","stage:implement","story:s2"]}')]"
  run_loop "$issues" 40 bad1
  if grep -qE 'could not claim bad1.*[A-Za-z0-9]{3,}.*[A-Za-z0-9]{3,}' "$W/out" && ! grep -qE 'could not claim bad1\s*$' "$W/out"; then
    pass "ac5: failed claim is logged with a reason"
  else fail "ac5: failed claim of bad1 not logged with a reason; log: $(grep -i claim "$W/out" | head -3)"; fi
  if ran_triage && [ "$(assignee_of good1)" = team-lead ]; then pass "ac5: loop moved on and triaged the other issue instead of retrying bad1"
  else fail "ac5: loop did not move on to good1 (assignee='$(assignee_of good1)'); claim attempts on bad1: $(grep -c 'could not claim bad1' "$W/out")"; fi
  local n; n=$(grep -c 'could not claim bad1' "$W/out")
  if [ "$n" -le 1 ]; then pass "ac5: unclaimable issue not retried forever (logged $n time)"
  else fail "ac5: unclaimable issue retried $n times"; fi
}

test_ac6_this_file_reproduces_ar5n_shape() {
  grep -q 'agent-factory-ar5n' "${BASH_SOURCE[0]}" && grep -q 'role:qa' "${BASH_SOURCE[0]}" \
    && pass "ac6: automated test covers the exact ar5n assignee/label shape" || fail "ac6: missing"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
