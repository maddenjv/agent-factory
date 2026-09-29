#!/usr/bin/env bash
# Acceptance tests for agent-factory-rcjb: team-lead picks up every open `needs-team-lead` issue,
# whatever other role:*/stage:*/story:* labels or (stale) assignee it carries.
# One function per acceptance criterion in docs/stories/agent-factory-rcjb.md (test_acN_...).
#
# Functional: next_issue() is extracted from bin/agent-loop.sh (same range as
# tests/agent-factory-vfu3_test.sh) and run against a stubbed `bd` that serves a fixture for both
# `bd list` and `bd ready`. Written before the implementation: ac2 (stale claim by the escalating
# role) is expected to FAIL today, because team-lead's poll only accepts unassigned issues.
# ac7 is met by this file itself (ac1/ac2/ac3 reproduce the previously stuck cases).
#
# Run directly: bash tests/agent-factory-rcjb_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FNS="$TMP/fns.sh"
sed -n '/^log()/,/^sync_dir()/{/^sync_dir()/d; p}' bin/agent-loop.sh > "$FNS"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/bd" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list|ready) cat "$FIXTURE";;
  show) jq -c --arg id "$2" '.[] | select(.id == $id)' "$FIXTURE";;
  update) echo "$*" >> "$BDLOG";;
esac
exit 0
STUB
chmod +x "$TMP/bin/bd"

# issue ID STATUS ASSIGNEE LABELS_CSV -> one bd-shaped JSON object
issue() {
  jq -n --arg id "$1" --arg st "$2" --arg a "$3" --arg l "$4" \
    '{id:$id, status:$st, assignee:$a, labels:($l|split(","))}'
}

run_next_issue() {  # run_next_issue ROLE < fixture-issues (one JSON object per line)
  local role=$1 fixture="$TMP/f.$RANDOM.json" w="$TMP/log.$RANDOM"; mkdir -p "$w"
  jq -s . > "$fixture"
  FIXTURE="$fixture" PATH="$TMP/bin:$PATH" AGENT_ID="$role" ROLE="$role" LOGDIR="$w" \
    bash -c 'source "$1"; next_issue' _ "$FNS"
}

# run_fn ROLE FUNCTION ID < fixture-issues: runs claim()/handle_outcome() against the stub;
# prints "rc=N" then every `bd update` call it made.
run_fn() {
  local role=$1 fn=$2 id=$3 fixture="$TMP/f.$RANDOM.json" w="$TMP/log.$RANDOM"; mkdir -p "$w"
  jq -s . > "$fixture"
  local bdlog="$w/bd.log"; : > "$bdlog"
  FIXTURE="$fixture" BDLOG="$bdlog" PATH="$TMP/bin:$PATH" AGENT_ID="$role" ROLE="$role" LOGDIR="$w" \
    CONTROL="$w" STATE="$w" bash -c 'source "$1"; '"$fn"' "$2"; echo "rc=$?"' _ "$FNS" "$id" 2>/dev/null
  cat "$bdlog"
}
no_update() { ! grep -q 'update' <<<"$1"; }

test_claim_team_lead_takes_over_stale_escalator_claim() {
  local out
  out=$(issue c1 in_progress po "needs-team-lead,role:po" | run_fn team-lead claim c1)
  grep -q '^rc=0$' <<<"$out" || { fail "claim: takeover of po's stale claim returned non-zero: $out"; return; }
  grep -q -- '--if-assignee po' <<<"$out" && grep -q -- '--assignee team-lead' <<<"$out" \
    && grep -q -- '--force' <<<"$out" \
    || { fail "claim: expected bd update --if-assignee po --assignee team-lead --force - got: $out"; return; }
  pass "claim: team-lead takes over the escalating role's claim via compare-and-swap with --force"
}

test_claim_team_lead_does_not_steal_other_agents_issue() {
  local out
  out=$(issue c2 in_progress alice "needs-team-lead,role:po" | run_fn team-lead claim c2)
  { grep -q '^rc=1$' <<<"$out" && no_update "$out"; } \
    || { fail "claim: alice's issue should give rc=1 and no bd update - got: $out"; return; }
  out=$(issue c3 in_progress qa "needs-team-lead,role:engineer" | run_fn team-lead claim c3)
  { grep -q '^rc=1$' <<<"$out" && no_update "$out"; } \
    || { fail "claim: mismatched role (qa vs role:engineer) should give rc=1, no update - got: $out"; return; }
  out=$(issue c4 in_progress po "role:po" | run_fn team-lead claim c4)
  { grep -q '^rc=1$' <<<"$out" && no_update "$out"; } \
    || { fail "claim: po's issue without needs-team-lead should not be taken over - got: $out"; return; }
  pass "claim: non-escalator assignee, mismatched role, or missing needs-team-lead is not taken over"
}

test_claim_non_team_lead_role_never_takes_over() {
  local out r
  for r in po engineer qa; do
    out=$(issue c5 in_progress alice "needs-team-lead,role:$r" | run_fn $r claim c5)
    { grep -q '^rc=1$' <<<"$out" && no_update "$out"; } \
      || { fail "claim: $r took over alice's issue - got: $out"; return; }
  done
  out=$(issue c6 in_progress po "needs-team-lead,role:po" | run_fn engineer claim c6)
  { grep -q '^rc=1$' <<<"$out" && no_update "$out"; } \
    || { fail "claim: engineer took over po's stale claim - got: $out"; return; }
  pass "claim: only team-lead can take over a stale claim"
}

test_handle_outcome_team_lead_releases_rerouted_issue() {
  local out
  out=$(issue h1 in_progress team-lead "role:engineer,stage:rework" | run_fn team-lead handle_outcome h1)
  grep -q -- '--if-assignee team-lead' <<<"$out" && grep -q -- '--assignee  *--status open' <<<"$out" \
    && grep -q '^rc=0$' <<<"$out" \
    || { fail "handle_outcome: expected release (assignee cleared, status open) rc=0 - got: $out"; return; }
  pass "handle_outcome: team-lead releases a rerouted issue (needs-team-lead cleared, role:* present)"
}

test_handle_outcome_no_release_when_still_escalated_or_not_ours() {
  local out
  out=$(issue h2 in_progress team-lead "needs-team-lead,role:engineer" | run_fn team-lead handle_outcome h2)
  ! grep -q -- '--assignee' <<<"$out" \
    || { fail "handle_outcome: released issue still labelled needs-team-lead - got: $out"; return; }
  out=$(issue h3 in_progress engineer "role:engineer" | run_fn team-lead handle_outcome h3)
  ! grep -q -- '--assignee' <<<"$out" \
    || { fail "handle_outcome: cleared assignee that is not team-lead - got: $out"; return; }
  out=$(issue h4 in_progress team-lead "stage:design" | run_fn team-lead handle_outcome h4)
  ! grep -q -- '--assignee' <<<"$out" \
    || { fail "handle_outcome: released issue with no role:* label - got: $out"; return; }
  pass "handle_outcome: no release while still escalated, when assignee isn't team-lead, or without role:*"
}

test_ac1_unassigned_needs_team_lead_with_role_label_is_selected() {
  local r got
  for r in po architect engineer qa reviewer; do
    got=$(issue x-$r open "" "needs-team-lead,role:$r" | run_next_issue team-lead)
    [ "$got" = "x-$r" ] || { fail "ac1: unassigned needs-team-lead,role:$r not selected by team-lead - got '$got'"; return; }
  done
  pass "ac1: unassigned needs-team-lead issues carrying any role:* label are selected"
}

test_ac2_stale_claim_by_escalating_role_does_not_hide_issue() {
  local st got
  for st in open in_progress; do
    got=$(issue stale-$st $st po "needs-team-lead,role:po" | run_next_issue team-lead)
    [ "$got" = "stale-$st" ] \
      || { fail "ac2: $st needs-team-lead,role:po issue still assigned to po not selected - got '$got'"; return; }
  done
  pass "ac2: needs-team-lead issue still claimed by its escalating role is selected (open and in_progress)"
}

test_ac3_stage_and_story_labels_do_not_hide_issue() {
  local got
  got=$(issue s1 open "" "needs-team-lead,role:engineer,stage:implement,story:agent-factory-zzz" | run_next_issue team-lead)
  [ "$got" = s1 ] || { fail "ac3: unassigned needs-team-lead with stage:/story: labels not selected - got '$got'"; return; }
  got=$(issue s2 in_progress qa "needs-team-lead,role:qa,stage:verify,story:agent-factory-zzz" | run_next_issue team-lead)
  [ "$got" = s2 ] || { fail "ac3: claimed needs-team-lead with stage:/story: labels not selected - got '$got'"; return; }
  pass "ac3: needs-team-lead issues with stage:* and story:* labels are selected"
}

test_ac4_needs_human_still_excluded() {
  local got
  got=$( { issue h1 open "" "needs-team-lead,needs-human,role:po"
           issue h2 in_progress po "needs-team-lead,needs-human,role:po"; } | run_next_issue team-lead)
  [ -z "$got" ] || { fail "ac4: needs-team-lead+needs-human issue was selected - got '$got'"; return; }
  pass "ac4: needs-team-lead + needs-human is not selected"
}

test_ac5_other_live_agents_issue_not_stolen() {
  local got
  got=$(issue o1 in_progress engineer "needs-team-lead,role:po,story:agent-factory-zzz" | run_next_issue team-lead)
  [ -z "$got" ] || { fail "ac5: issue actively held by unrelated agent 'engineer' (escalating role is po) was selected - got '$got'"; return; }
  pass "ac5: needs-team-lead issue assigned to a non-escalating, non-team-lead agent is not stolen"
}

test_ac5b_no_regression_of_selection_among_mixed_queue() {
  local got
  got=$( { issue m1 open "" "role:po"                              # ordinary role work: not team-lead's
           issue m2 in_progress engineer "needs-team-lead,role:po"  # someone else's
           issue m3 in_progress po "needs-team-lead,role:po"; } | run_next_issue team-lead)  # target
  [ "$got" = m3 ] || { fail "ac5: expected m3 (only eligible issue) from a mixed queue - got '$got'"; return; }
  pass "ac5: in a mixed queue only the escalating role's stale claim is picked"
}

test_ac6_rerouted_issue_picked_up_by_role_queue() {
  local got
  got=$(issue r1 open "" "role:engineer,stage:rework,story:agent-factory-zzz" | run_next_issue engineer)
  [ "$got" = r1 ] || { fail "ac6: triaged/rerouted issue (needs-team-lead cleared) not picked by engineer queue - got '$got'"; return; }
  got=$(issue r2 open "" "needs-team-lead,role:engineer" | run_next_issue engineer)
  [ -z "$got" ] || { fail "ac6: engineer queue picked up an issue still labelled needs-team-lead - got '$got'"; return; }
  pass "ac6: rerouted issue is picked by its role queue; still-escalated one is not"
}

test_edge_suffixed_escalator_id_selected_but_lookalike_and_mismatched_role_not() {
  local got
  got=$(issue e1 in_progress engineer-2 "needs-team-lead,role:engineer" | run_next_issue team-lead)
  [ "$got" = e1 ] || { fail "edge: stale claim by suffixed id engineer-2 not selected - got '$got'"; return; }
  got=$(issue e2 in_progress engineerx "needs-team-lead,role:engineer" | run_next_issue team-lead)
  [ -z "$got" ] || { fail "edge: lookalike assignee 'engineerx' treated as stale claim - got '$got'"; return; }
  got=$(issue e3 in_progress qa "needs-team-lead,role:engineer" | run_next_issue team-lead)
  [ -z "$got" ] || { fail "edge: build role qa (not the escalating role:engineer) was overridden - got '$got'"; return; }
  got=$(issue e4 in_progress po "needs-team-lead,needs-human,role:po" | run_next_issue team-lead)
  [ -z "$got" ] || { fail "edge: needs-human + stale claim selected - got '$got'"; return; }
  got=$(issue e5 closed po "needs-team-lead,role:po" | run_next_issue team-lead)
  [ -z "$got" ] || { fail "edge: closed issue selected - got '$got'"; return; }
  pass "edge: suffixed escalator selected; lookalike, wrong-role, needs-human and closed are not"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "--- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
