#!/usr/bin/env bash
# Acceptance tests for agent-factory-m7af: team-lead sweeps the board for unassigned issues.
# One function per acceptance criterion in docs/stories/agent-factory-m7af.md (test_acN_...).
#
# AC1/AC2 (queue-widening/exclusion behaviour) run the real bin/agent-loop.sh with ROLE=team-lead
# against a stub `bd`, a stub `claude`, and a scratch git origin - same harness style as
# tests/agent-factory-dx0_test.sh (this story reuses/widens the polling that story built). The
# stub `bd list`/`bd ready` filters by whatever --label argument (if any) it's given, or returns
# every issue when none is given, mirroring the real CLI - so the test doesn't assume which exact
# `bd` invocation the implementation uses to build its widened queue. It only asserts the outcome
# AC1/AC2 require: an issue with no role:* label at all (and no needs-human/needs-team-lead) gets
# claimed, an ordinary role:*-labelled issue never does, a needs-human issue never does, and the
# pre-existing needs-team-lead path still works alongside the new one.
#
# AC3-AC6 (investigate/reroute/role:po-default/escalate/handoff-comment behaviour for issues found
# via this sweep) are content checks on agents/team-lead.md, the same way
# tests/agent-factory-dx0_test.sh checks prose instructions for a role's decision-making - that
# behaviour is the LLM following its prompt, not code we can run directly.
#
# Written BEFORE implementation: expect every test below to fail right now, for legitimate
# reasons rather than a broken harness: (a) bin/agent-loop.sh's next_issue() for ROLE=team-lead
# still only queries `bd list --label needs-team-lead` (confirmed by reading bin/agent-loop.sh),
# so an issue with no role:* label at all is never found; and (b) agents/team-lead.md has no
# mention yet of the no-role-label sweep, the role:po default, or explaining "no role assignment"
# in the handoff comment.
#
# Run directly: bash tests/agent-factory-m7af_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# ============================================================
# AC1 / AC2 - polling: a no-role:*-label issue (not needs-human/needs-team-lead) is claimed as
# part of team-lead's own queue; an ordinary role:*-labelled issue or a needs-human issue is
# never claimed or modified via this sweep; the pre-existing needs-team-lead path still works.
# ============================================================

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

# issue-F: no role:* label at all, not needs-human/needs-team-lead -> must be claimed (AC1).
# issue-G: an ordinary role:qa issue (has a role:* label) -> must never be claimed (AC2).
# issue-I: no role:* label, but needs-human -> must never be claimed (AC2's explicit exclusion).
cat > "$TMP/issues_ac1.json" <<'JSON'
[
  {"id":"issue-F","status":"open","assignee":"","labels":[]},
  {"id":"issue-G","status":"open","assignee":"","labels":["role:qa","stage:verify"]},
  {"id":"issue-I","status":"open","assignee":"","labels":["needs-human"]}
]
JSON

# issue-H: the pre-existing needs-team-lead path (agent-factory-dx0) - this story only widens the
# queue, it must not stop finding issues the old way.
cat > "$TMP/issues_ac1_alongside.json" <<'JSON'
[
  {"id":"issue-H","status":"open","assignee":"","labels":["needs-team-lead","role:qa","stage:verify"]}
]
JSON

cat > "$TMP/stubs/bd" <<'STUB'
#!/usr/bin/env bash
echo "bd $*" >> "$W/bdlog"
case "$1" in
  ready|list)
    label=""
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      [ "${args[$i]}" = "--label" ] && label="${args[$((i + 1))]}"
    done
    if [ -n "$label" ]; then
      jq -c --arg l "$label" '[.[] | select((.labels // []) | index($l))]' "$W/issues.json"
    else
      cat "$W/issues.json"
    fi
    ;;
  show)
    jq -c --arg id "$2" '[.[] | select(.id == $id)]' "$W/issues.json"
    ;;
  *) ;;
esac
exit 0
STUB
chmod +x "$TMP/stubs/bd"

# Stub claude: never claims/reroutes/comments anything itself (that's outside code-level scope
# for AC1/AC2) - it just marks that it ran, then stops the loop after one issue.
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

# run_loop FIXTURE: one pass of bin/agent-loop.sh ROLE=team-lead against the stubs above; sets W
# and RC. IDLE_SLEEP is shortened so an empty-queue pass doesn't waste the timeout budget.
run_loop() {
  W="$TMP/run.$RANDOM"; mkdir -p "$W/data/control" "$W/home"; : > "$W/bdlog"; : > "$W/claude_runs"
  cp "$1" "$W/issues.json"
  RC=0
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home"
    PATH="$TMP/stubs:$PATH" ROLE=team-lead KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 IDLE_SLEEP=1 \
      timeout 30 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
}
claimed() { grep -qE "bd update $1 --claim" "$W/bdlog"; }
modified() { grep -qE "^bd (update|label|comment) $1\b" "$W/bdlog"; }

# issues_ac1.json exercises AC1's new-sweep claim and both of AC2's exclusions at once (issue-F
# claimed, issue-G/issue-I never touched) - run it once and share the result across those three
# tests instead of paying the idle-queue timeout three times.
run_loop_ac1_once() {
  [ -n "${AC1_W:-}" ] && return
  run_loop "$TMP/issues_ac1.json"
  AC1_W="$W"
}

test_ac1_claims_issue_with_no_role_label_at_all() {
  run_loop_ac1_once; W="$AC1_W"
  claimed issue-F \
    && pass "ac1: claimed issue-F, which carries no role:* label and no needs-human/needs-team-lead label" \
    || fail "ac1: issue-F (no role:* label at all) was never claimed - queue was not widened to include it. bdlog:$(cat "$W/bdlog") out:$(cat "$W/out")"
}

test_ac1_still_claims_needs_team_lead_alongside_the_new_sweep() {
  run_loop "$TMP/issues_ac1_alongside.json"
  claimed issue-H \
    && pass "ac1: still claims a needs-team-lead-labelled issue - the sweep widens the queue, it doesn't replace the existing path" \
    || fail "ac1: issue-H (needs-team-lead) was not claimed after widening the queue - the pre-existing path regressed. bdlog:$(cat "$W/bdlog") out:$(cat "$W/out")"
}

test_ac2_never_claims_an_ordinary_role_labelled_issue() {
  run_loop_ac1_once; W="$AC1_W"
  if claimed issue-G; then
    fail "ac2: claimed issue-G, which carries a role:* label (role:qa) - only issues with no role:* label at all are in scope for this sweep"
    return
  fi
  if modified issue-G; then
    fail "ac2: modified issue-G (role:qa), which this sweep must not touch: $(grep issue-G "$W/bdlog")"
    return
  fi
  pass "ac2: ordinary role:qa issue-G was never claimed or modified by the sweep"
}

test_ac2_never_claims_a_needs_human_issue_even_with_no_role_label() {
  run_loop_ac1_once; W="$AC1_W"
  if claimed issue-I; then
    fail "ac2: claimed issue-I, which is labelled needs-human (even though it has no role:* label)"
    return
  fi
  if modified issue-I; then
    fail "ac2: modified issue-I (needs-human): $(grep issue-I "$W/bdlog")"
    return
  fi
  pass "ac2: needs-human issue-I was never claimed or modified by the sweep, despite having no role:* label"
}

# ============================================================
# AC3-AC6 - investigate/reroute/role:po-default/escalate/handoff-comment for issues found via
# this sweep: prose checks on agents/team-lead.md, the role prompt that drives this
# decision-making (not directly executable code). This story explicitly reuses the
# investigate/reroute/escalate mechanics agent-factory-dx0 already built and
# tests/agent-factory-dx0_test.sh already pins - these tests check only what's new: that the
# sweep case is described, and the two new outcomes (role:po default, escalate-on-ambiguous-case)
# are covered.
# ============================================================

TL="agents/team-lead.md"

test_ac3_sweep_found_story_issue_gets_full_investigation_like_needs_team_lead() {
  [ -f "$TL" ] || { fail "ac3: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$TL")
  echo "$c" | grep -qiE 'no role:\* ?label|no role[- ]label|role:\* label' \
    || { fail "ac3: no mention of issues carrying no role:* label at all (the sweep this story adds)"; return; }
  echo "$c" | grep -qE 'story:<story-id>' \
    || { fail "ac3: no instruction to check a sweep-found issue for a story:<story-id> label"; return; }
  echo "$c" | grep -qiE 'same (way|process|steps|mechanics)|steps? 1-?4|as (you|it) (already|would)' \
    || { fail "ac3: no instruction to reuse the existing read-broadly/diagnose process for a sweep-found story issue"; return; }
  pass "ac3: prompt directs a sweep-found issue that carries a story:<story-id> label through the same investigate/diagnose process as a needs-team-lead issue"
}

test_ac4_no_story_context_defaults_to_role_po() {
  [ -f "$TL" ] || { fail "ac4: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$TL")
  echo "$c" | grep -qE 'role:po' \
    || { fail "ac4: no instruction to label a no-story-context sweep issue role:po"; return; }
  echo "$c" | grep -qiE 'no story:<story-id>|no story context|unfiled|raw (feature|bug) report' \
    || { fail "ac4: no guidance for the case where a sweep-found issue carries no story:<story-id> label"; return; }
  echo "$c" | grep -qE 'bd comment' \
    || { fail "ac4: no instruction to leave a bd comment on this default-to-po outcome"; return; }
  pass "ac4: prompt directs a no-story-context sweep issue to role:po with a comment explaining why"
}

test_ac5_escalates_exactly_as_before_when_the_case_is_undiagnosable() {
  [ -f "$TL" ] || { fail "ac5: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$TL")
  echo "$c" | grep -qE -- '--append-notes' \
    || { fail "ac5: no --append-notes escalation step"; return; }
  echo "$c" | grep -qE 'needs-human' \
    || { fail "ac5: no needs-human labelling on escalation"; return; }
  echo "$c" | tr '\n' ' ' | grep -qiE "story:<story-id>[^.]{0,200}(doesn.t exist|does not exist)|docs/stories/<story-id>\.md[^.]{0,200}(doesn.t exist|does not exist)" \
    || { fail "ac5: no mention of the specific undiagnosable case AC5 names - a story:<story-id> label pointing at a docs/stories/<id>.md that doesn't exist"; return; }
  pass "ac5: prompt covers escalating a sweep-found issue exactly like an undiagnosable needs-team-lead issue (append-notes, needs-human, stop)"
}

test_ac6_handoff_comment_explains_why_the_issue_had_no_role_assignment() {
  [ -f "$TL" ] || { fail "ac6: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$TL")
  echo "$c" | grep -qiE 'no role (assignment|label)' \
    || { fail "ac6: no requirement to state, in the handoff comment/notes, why the issue had no role assignment"; return; }
  echo "$c" | grep -qiE 'no other context|without other context|understandable' \
    || { fail "ac6: no requirement that this be understandable with no other context - same handoff bar as every other outcome"; return; }
  pass "ac6: prompt requires the handoff comment/notes to explain why the issue had no role assignment and what team-lead decided"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
