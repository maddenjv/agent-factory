#!/usr/bin/env bash
# Acceptance tests for agent-factory-zf0i: a role picks up an issue team-lead routed to it
# (role:<x> label) even when team-lead left its claim on it.
# One function per acceptance criterion in docs/stories/agent-factory-zf0i.md (test_acN_...).
#
# Functional: next_issue()/claim()/handle_claim_failure() are extracted from bin/agent-loop.sh (same
# range as tests/agent-factory-rcjb_test.sh) and run against a stubbed `bd` serving a fixture for
# `bd list`, `bd ready` and `bd show`. The stub's `bd ready` hides fixture issues flagged
# blocked:true (as real bd does); `bd list` does not, so the code must not rely on list alone.
# Assumption for ac6: a running team-lead session is recognised by a live bd lease on the issue
# (lease_expires_at in the future), as `bd show` reports for every in-progress claim.
# Written before the implementation: ac1/ac2/ac7 are expected to FAIL today.
#
# Run directly: bash tests/agent-factory-zf0i_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FNS="$TMP/fns.sh"
sed -n '/^log()/,/^sync_dir()/{/^sync_dir()/d; p}' bin/agent-loop.sh > "$FNS"
cat bin/bdjson.sh >> "$FNS"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/bd" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list) cat "$FIXTURE";;
  ready) jq -c '[.[] | select((.blocked // false) | not)]' "$FIXTURE";;
  show) jq -c --arg id "$2" '.[] | select(.id == $id)' "$FIXTURE";;
  update) echo "$*" >> "$BDLOG"; [ -z "${FAIL_UPDATE:-}" ] || { echo "simulated bd failure" >&2; exit 1; };;
esac
exit 0
STUB
chmod +x "$TMP/bin/bd"

# issue ID STATUS ASSIGNEE LABELS_CSV [blocked|live] -> one bd-shaped JSON object
issue() {
  local extra=${5:-}
  jq -n --arg id "$1" --arg st "$2" --arg a "$3" --arg l "$4" --arg x "$extra" \
    --arg exp "$(date -u -d '+5 minutes' +%FT%TZ)" --arg now "$(date -u +%FT%TZ)" \
    '{id:$id, status:$st, assignee:$a, labels:($l|split(","))}
     + (if $x == "blocked" then {blocked:true, dependency_count:1} else {} end)
     + (if $x == "live" then {lease_expires_at:$exp, heartbeat_at:$now} else {} end)'
}

run_next_issue() {  # run_next_issue ROLE < fixture-issues
  local role=$1 fixture="$TMP/f.$RANDOM.json" w="$TMP/log.$RANDOM"; mkdir -p "$w"
  jq -s . > "$fixture"
  FIXTURE="$fixture" PATH="$TMP/bin:$PATH" AGENT_ID="$role" ROLE="$role" LOGDIR="$w" \
    bash -c 'source "$1"; next_issue' _ "$FNS"
}

# run_fn ROLE FUNCTION ID < fixture-issues: prints "rc=N" then every `bd update` call made.
run_fn() {
  local role=$1 fn=$2 id=$3 fixture="$TMP/f.$RANDOM.json" w="$TMP/log.$RANDOM"; mkdir -p "$w"
  jq -s . > "$fixture"
  local bdlog="$w/bd.log"; : > "$bdlog"
  FIXTURE="$fixture" BDLOG="$bdlog" PATH="$TMP/bin:$PATH" AGENT_ID="$role" ROLE="$role" LOGDIR="$w" \
    CONTROL="$w" STATE="$w" bash -c 'source "$1"; '"$fn"' "$2"; echo "rc=$?"' _ "$FNS" "$id" 2>/dev/null
  cat "$bdlog"
}
no_update() { ! grep -q 'update' <<<"$1"; }
ROLES="po architect engineer qa reviewer"

test_ac1_team_lead_routed_issue_selected_by_each_role() {
  local r got
  for r in $ROLES; do
    got=$(issue t-$r in_progress team-lead "role:$r,stage:implement,story:agent-factory-zzz" | run_next_issue $r)
    [ "$got" = "t-$r" ] || { fail "ac1: team-lead-held role:$r issue not selected by $r - got '$got'"; return; }
    got=$(issue u-$r open team-lead "role:$r" | run_next_issue $r)
    [ "$got" = "u-$r" ] || { fail "ac1: open team-lead-assigned role:$r issue not selected by $r - got '$got'"; return; }
  done
  pass "ac1: every role selects a team-lead-held issue labelled for it"
}

test_ac1_other_roles_label_not_selected() {
  local got
  got=$(issue o1 in_progress team-lead "role:engineer" | run_next_issue qa)
  [ -z "$got" ] || { fail "ac1: qa selected role:engineer issue - got '$got'"; return; }
  pass "ac1: a role does not take team-lead-held issues labelled for another role"
}

test_ac2_claim_takes_over_with_forced_reassign_to_in_progress() {
  local out r
  for r in $ROLES; do
    out=$(issue c-$r in_progress team-lead "role:$r" | run_fn $r claim c-$r)
    grep -q '^rc=0$' <<<"$out" || { fail "ac2: $r claim of team-lead-held issue returned non-zero: $out"; return; }
    grep -q -- "--assignee $r" <<<"$out" && grep -q -- '--status in_progress' <<<"$out" \
      && grep -q -- '--force' <<<"$out" && ! grep -q -- '--if-assignee' <<<"$out" \
      || { fail "ac2: expected bd update --assignee $r --status in_progress --force (no --if-assignee) - got: $out"; return; }
  done
  out=$(issue c-open open team-lead "role:qa" | run_fn qa claim c-open)
  grep -q '^rc=0$' <<<"$out" && grep -q -- '--assignee qa' <<<"$out" \
    || { fail "ac2: claim of open team-lead-assigned issue failed - got: $out"; return; }
  pass "ac2: claim reassigns to the role's agent id, in progress, forced (no leftover team-lead claim)"
}

test_ac2_claim_still_works_for_unassigned_and_own() {
  local out
  out=$(issue d1 open "" "role:qa" | run_fn qa claim d1)
  grep -q '^rc=0$' <<<"$out" && grep -q -- '--claim' <<<"$out" \
    || { fail "ac2: regression - unassigned claim broken: $out"; return; }
  out=$(issue d2 open qa "role:qa" | run_fn qa claim d2)
  grep -q '^rc=0$' <<<"$out" || { fail "ac2: regression - resume of own claim broken: $out"; return; }
  pass "ac2: unassigned and self-assigned claims unchanged"
}

test_ac3_needs_team_lead_or_chain_or_human_not_taken() {
  local lbl got out r
  for lbl in needs-team-lead needs-chain needs-human; do
    for r in $ROLES; do
      got=$(issue n1 in_progress team-lead "role:$r,$lbl" | run_next_issue $r)
      [ -z "$got" ] || { fail "ac3: $r selected team-lead-held issue labelled $lbl - got '$got'"; return; }
    done
    out=$(issue n2 in_progress team-lead "role:qa,$lbl" | run_fn qa claim n2)
    { grep -q '^rc=1$' <<<"$out" && no_update "$out"; } \
      || { fail "ac3: qa claim() took over team-lead's $lbl issue - got: $out"; return; }
  done
  pass "ac3: needs-team-lead / needs-chain / needs-human issues held by team-lead are not taken"
}

test_ac4_other_agents_issue_not_taken() {
  local got out
  got=$(issue a1 in_progress engineer "role:qa" | run_next_issue qa)
  [ -z "$got" ] || { fail "ac4: qa selected issue assigned to engineer - got '$got'"; return; }
  got=$(issue a2 in_progress alice "role:qa" | run_next_issue qa)
  [ -z "$got" ] || { fail "ac4: qa selected issue assigned to alice - got '$got'"; return; }
  got=$(issue a3 in_progress team-lead-2 "role:qa" | run_next_issue qa)
  [ -z "$got" ] || { fail "ac4: qa selected issue assigned to lookalike 'team-lead-2' - got '$got'"; return; }
  out=$(issue a4 in_progress engineer "role:qa" | run_fn qa claim a4)
  { grep -q '^rc=1$' <<<"$out" && no_update "$out"; } \
    || { fail "ac4: qa claim() took over engineer's issue - got: $out"; return; }
  out=$(issue a5 in_progress qa-2 "role:qa" | run_fn qa claim a5)
  { grep -q '^rc=1$' <<<"$out" && no_update "$out"; } \
    || { fail "ac4: qa claim() took over qa-2's issue - got: $out"; return; }
  got=$(issue a6 in_progress qa "role:qa" | run_next_issue qa)
  [ "$got" = a6 ] || { fail "ac4: regression - own in-progress issue no longer selected - got '$got'"; return; }
  pass "ac4: only team-lead's (or own) claim is taken; other agents' issues are left alone"
}

test_scope_team_lead_queue_unchanged() {
  local got
  got=$(issue l1 in_progress team-lead "role:qa" | run_next_issue team-lead)
  [ -z "$got" ] || { fail "scope: team-lead picked its own routed role:qa issue - got '$got'"; return; }
  pass "scope: team-lead's own queue unchanged (does not pick up role-labelled issues)"
}

test_ac5_blocked_issue_not_taken() {
  local r got
  for r in $ROLES; do
    got=$(issue k-$r in_progress team-lead "role:$r" blocked | run_next_issue $r)
    [ -z "$got" ] || { fail "ac5: $r selected team-lead-held issue still blocked by an open dependency - got '$got'"; return; }
  done
  got=$( { issue k1 in_progress team-lead "role:qa" blocked; issue k2 in_progress team-lead "role:qa"; } | run_next_issue qa)
  [ "$got" = k2 ] || { fail "ac5: expected only the unblocked k2 - got '$got'"; return; }
  pass "ac5: blocked team-lead-held issues are not taken; unblocked sibling is"
}

test_ac6_running_team_lead_session_not_preempted() {
  local r got
  for r in $ROLES; do
    got=$(issue g-$r in_progress team-lead "role:$r" live | run_next_issue $r)
    [ -z "$got" ] || { fail "ac6: $r took issue out from under a live team-lead session (live lease) - got '$got'"; return; }
  done
  got=$(issue g1 in_progress team-lead "role:qa" live | run_fn qa claim g1)
  no_update "$got" || { fail "ac6: claim() issued a bd update against a live team-lead session - got: $got"; return; }
  pass "ac6: issue with a live team-lead lease is not taken by role x"
}

test_ac6_expired_lease_is_stale() {
  local got exp
  exp=$(date -u -d '-10 minutes' +%FT%TZ)
  got=$(issue e1 in_progress team-lead "role:qa" | jq -c --arg e "$exp" '. + {lease_expires_at:$e, heartbeat_at:$e}' | run_next_issue qa)
  [ "$got" = e1 ] || { fail "ac6: expired team-lead lease should count as stale and be taken - got '$got'"; return; }
  pass "ac6: team-lead claim with an expired lease is taken over"
}

test_ac7_failed_takeover_is_logged_and_skipped() {
  local w="$TMP/log.ac7" fixture="$TMP/f.ac7.json" out
  mkdir -p "$w"; issue z1 in_progress team-lead "role:qa" | jq -s . > "$fixture"
  out=$(FIXTURE="$fixture" BDLOG="$w/bd.log" FAIL_UPDATE=1 PATH="$TMP/bin:$PATH" AGENT_ID=qa ROLE=qa \
    LOGDIR="$w" CONTROL="$w" STATE="$w" CLAIM_SKIP_SECS=600 bash -c '
      source "$1"
      first=$(next_issue)
      if claim "$first"; then echo "claim-ok"; else handle_claim_failure "$first"; fi
      echo "first=$first"
      echo "second=$(next_issue)"' _ "$FNS" 2>&1)
  grep -q '^first=z1$' <<<"$out" || { fail "ac7: setup - z1 not selected the first time (takeover missing) - got: $out"; return; }
  grep -q 'claim-ok' <<<"$out" && { fail "ac7: claim reported success although bd update failed - got: $out"; return; }
  grep -q 'could not claim z1' "$w/loop.log" || { fail "ac7: failed takeover was not logged - $(cat "$w/loop.log" 2>&1)"; return; }
  grep -q '^second=$' <<<"$out" || { fail "ac7: failed takeover retried immediately (not skipped) - got: $out"; return; }
  pass "ac7: failed takeover is logged and the issue skipped for the backoff window"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "--- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
