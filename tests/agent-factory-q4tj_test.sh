#!/usr/bin/env bash
# Acceptance tests for agent-factory-q4tj: team-lead decides when po and architect go idle, not a
# fixed WIP heuristic. One function per acceptance criterion in
# docs/stories/agent-factory-q4tj.md (test_acN_...).
#
# This story is deliberately "no fixed rubric" (out of scope: "A numeric formula or fixed rubric
# for backlog too large... the same way stage-chain sizing (agent-factory-x8wj) has no fixed
# rubric") AND deliberately leaves the mechanism by which the decision reaches po/architect's loop
# unspecified (out of scope: "The exact mechanism... a new team-lead poll trigger, a control file,
# a bd label or synthetic issue - that is architect's design call for this story"). So none of
# this is something a fixture can drive through canned `claude`/`bd` stubs the way
# tests/agent-factory-dx0_test.sh or tests/agent-factory-m7af_test.sh exercise mechanical polling
# logic, or the way tests/agent-factory-x8wj_test.sh's AC7 pins bin/new-story.sh's unchanged
# output shape - there is no "guaranteed unchanged" deterministic code path here to pin, and no
# fixed threshold to assert against. Every AC below is instead a content check on
# agents/team-lead.md, the same style tests/agent-factory-x8wj_test.sh already uses for AC1-AC6
# there: team-lead.md must document making this judgment call (which stories/backlog it weighs,
# how quota/budget factor in, that it idles only po/architect, that the assessment is re-evaluated
# rather than a one-time snapshot, and that a reason is left somewhere a human can find it) -
# whatever concrete mechanism architect's design chooses to carry that judgment to po/architect's
# loop, team-lead.md is where a human or another role would read the decision and its rationale
# back, exactly as x8wj required for the stage-chain sizing call.
#
# Written BEFORE implementation: expect every test below to fail right now, for the legitimate
# reason that agents/team-lead.md says nothing about po/architect idling, backlog size, or quota
# at all yet (confirmed by reading the file: it only covers the needs-team-lead triage, the
# needs-chain stage-chain sizing from agent-factory-x8wj, and the no-role-label sweep - grepping it
# for po|architect|idle|backlog|quota|budget|throughput|capacity turns up only incidental mentions
# of po filing the needs-chain issue, nothing about throttling either role).
#
# Run directly: bash tests/agent-factory-q4tj_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TL="agents/team-lead.md"
tl_content=$(cat "$TL")

# ============================================================
# AC1 - when team-lead judges the engineer/qa/reviewer backlog has room, po or architect finishing
# its current issue is allowed to claim and start another ready issue.
# ============================================================

test_ac1_team_lead_judges_backlog_room_lets_po_and_architect_start_more_work() {
  echo "$tl_content" | grep -qiE '\bpo\b.{0,80}\barchitect\b|\barchitect\b.{0,80}\bpo\b' \
    || { fail "ac1: agents/team-lead.md never names po and architect together in a throttling/throughput context"; return; }
  echo "$tl_content" | grep -qiE 'backlog|engineer.{0,20}(/|,| and ).{0,20}qa.{0,20}(/|,| and ).{0,20}review' \
    || { fail "ac1: agents/team-lead.md doesn't mention the engineer/qa/reviewer backlog at all"; return; }
  echo "$tl_content" | grep -qiE 'room|has (capacity|space)|not (too |grown )?large|start (more|another|new) (work|stor(y|ies)|issue)' \
    || { fail "ac1: agents/team-lead.md doesn't say po/architect may start new work when the backlog has room"; return; }
  pass "ac1: agents/team-lead.md documents letting po/architect start new work when it judges the engineer/qa/reviewer backlog has room"
}

# ============================================================
# AC2 - when team-lead judges the backlog too large, po or architect goes idle instead of claiming
# new work. Engineer, qa, and reviewer are never idled by this policy.
# ============================================================

test_ac2_team_lead_idles_only_po_and_architect_never_downstream_roles() {
  echo "$tl_content" | grep -qiE 'idle' \
    || { fail "ac2: agents/team-lead.md never mentions idling po/architect at all"; return; }
  echo "$tl_content" | grep -qiE 'too large|grown too large|too much backlog' \
    || { fail "ac2: agents/team-lead.md doesn't describe a 'backlog too large' judgment that idles po/architect"; return; }
  echo "$tl_content" | grep -qiE 'never idle|only (po|architect)|not (engineer|qa|review)|engineer.{0,30}qa.{0,30}review(er)?.{0,40}(never|not).{0,20}idle' \
    || { fail "ac2: agents/team-lead.md doesn't state that engineer/qa/reviewer are never idled by this policy - only po/architect are"; return; }
  pass "ac2: agents/team-lead.md documents idling po/architect (and only po/architect) when the backlog is judged too large"
}

# ============================================================
# AC3 - "too large" is not a fixed count of stories with an open role:reviewer issue or any other
# hardcoded number; team-lead assesses it per situation, the same way it already sizes a story's
# stage chain (agent-factory-x8wj).
# ============================================================

test_ac3_no_fixed_count_or_hardcoded_threshold() {
  # Scoped to text near "too large"/"backlog", not just any judgment-call language elsewhere in
  # the file (e.g. the unrelated, pre-existing "no fixed rubric" wording for stage-chain sizing).
  local near; near=$(echo "$tl_content" | grep -iB3 -A3 -E 'too large|backlog')
  [ -n "$near" ] || { fail "ac3: agents/team-lead.md has no 'too large'/backlog language to check for a fixed threshold"; return; }
  echo "$near" | grep -qiE 'no fixed (rubric|number|count|threshold)|not a fixed (number|count)|per situation|judgment call|use judgment' \
    || { fail "ac3: agents/team-lead.md's backlog-too-large text doesn't say it's a per-situation judgment call, not a fixed rubric/number"; return; }
  pass "ac3: agents/team-lead.md states the backlog-too-large call is a per-situation judgment, not a fixed/hardcoded threshold"
}

# ============================================================
# AC4 - when remaining usage quota or budget is low enough that new work is unlikely to finish,
# team-lead holds po/architect back from starting new work, favoring completion of in-flight
# stories over starting new ones.
# ============================================================

test_ac4_low_quota_or_budget_favors_finishing_in_flight_work_over_starting_new() {
  echo "$tl_content" | grep -qiE 'quota|budget' \
    || { fail "ac4: agents/team-lead.md never mentions quota or budget as an input to the throttling decision"; return; }
  echo "$tl_content" | grep -qiE 'favor(ing)?.{0,60}(finish|complet)|(finish|complet).{0,60}favor|before.{0,40}(run(s)? out|exhaust)|unlikely to finish' \
    || { fail "ac4: agents/team-lead.md doesn't say low quota/budget favors finishing in-flight work over starting new work"; return; }
  pass "ac4: agents/team-lead.md ties low remaining quota/budget to holding back new starts in favor of finishing in-flight stories"
}

# ============================================================
# AC5 - a story that currently has only team-lead's role:team-lead,needs-chain issue open (no
# stage issue yet) is accounted for as occupying capacity when team-lead assesses backlog size.
# ============================================================

test_ac5_needs_chain_only_story_counts_as_occupying_capacity() {
  echo "$tl_content" | grep -qiE 'needs-chain' \
    || { fail "ac5: agents/team-lead.md doesn't mention needs-chain issues in the backlog-assessment context"; return; }
  echo "$tl_content" | grep -qiE 'count(s|ed)? (as|toward)|occup(y|ies|ying)|before.{0,40}(design|write-tests|implement|verify|review).{0,40}exists|no stage issue' \
    || { fail "ac5: agents/team-lead.md doesn't say a needs-chain-only story (no stage issue yet) still counts toward the backlog assessment"; return; }
  pass "ac5: agents/team-lead.md accounts for a story that only has its needs-chain issue as occupying backlog capacity"
}

# ============================================================
# AC6 - the assessment is re-evaluated as conditions change (backlog shrinks, quota recovers,
# backlog grows) - not a one-time snapshot fixed earlier in the run.
# ============================================================

test_ac6_assessment_is_reevaluated_not_a_onetime_snapshot() {
  echo "$tl_content" | grep -qiE 're-?(evaluat|assess|check)|each time|every (time|cycle|poll)|as (conditions|things|it) change|not a one-time|updated assessment' \
    || { fail "ac6: agents/team-lead.md doesn't say the backlog/quota assessment is re-evaluated over time rather than a one-time snapshot"; return; }
  pass "ac6: agents/team-lead.md documents the assessment as being re-evaluated over time, not fixed once"
}

# ============================================================
# AC7 - when po or architect is idle because of this policy, a human inspecting the system
# (logs/alerts/bd show or equivalent) can find a stated reason (backlog too large / quota too low).
# ============================================================

test_ac7_idle_reason_is_recorded_somewhere_a_human_can_find_it() {
  # Scoped to text near "idle", not just any bd comment/reason wording elsewhere in the file (e.g.
  # the unrelated, pre-existing needs-team-lead/sweep recording steps).
  local near; near=$(echo "$tl_content" | grep -iB3 -A3 -E '\bidle')
  [ -n "$near" ] || { fail "ac7: agents/team-lead.md has no 'idle' language to check for a recorded reason"; return; }
  echo "$near" | grep -qiE 'bd comment|bd update.{0,40}(notes|label)|log\b|alert\b' \
    || { fail "ac7: agents/team-lead.md's idling text doesn't describe recording anything (bd comment/notes/label/log/alert)"; return; }
  echo "$near" | grep -qiE 'reason|why|explain' \
    || { fail "ac7: agents/team-lead.md's idling text doesn't require stating WHY po/architect were idled (backlog too large / quota too low)"; return; }
  pass "ac7: agents/team-lead.md requires a discoverable, stated reason whenever po/architect are idled by this policy"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
