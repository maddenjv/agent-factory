#!/usr/bin/env bash
# Acceptance tests for agent-factory-vzt: qa's verify stage runs the whole accumulated test suite.
# One function per acceptance criterion in docs/stories/agent-factory-vzt.md (test_acN_...).
# The behaviour lives in qa's instructions (agents/qa.md, stage:verify section), so tests inspect that text.
# Run directly: bash tests/agent-factory-vzt_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# Text of the stage:verify section only (from its heading up to the stage:rework heading).
verify_section() {
  awk '/^\*\*stage:verify\*\*/{on=1} /^\*\*stage:rework\*\*/{on=0} on' agents/qa.md
}
V="$(verify_section)"

test_ac0_verify_section_present() {
  [ -n "$V" ] && pass "ac0: qa.md has a stage:verify section" || fail "ac0: no stage:verify section in agents/qa.md"
}

test_ac1_run_every_script_under_tests_and_record_per_script() {
  echo "$V" | grep -qE 'tests/' \
    && echo "$V" | grep -qiE '(every|all|each)[^.]*(script|test)' \
    && echo "$V" | grep -qiE "(not only|not just|including|other|earlier|all stories)[^.]*stor" \
    || { fail "ac1: verify does not say to run every script under tests/ across all stories"; return; }
  echo "$V" | grep -qiE 'per-script|each script|per script|for each script|every script' \
    && echo "$V" | grep -qiE 'pass(/| or |ed)?.{0,6}fail|pass.*fail' \
    && echo "$V" | grep -qi 'bd comment' \
    || { fail "ac1: verify does not say to record per-script pass/fail in the bd comment"; return; }
  pass "ac1: run all tests/ scripts and record per-script results"
}

test_ac2_earlier_story_failure_is_regression_bug_and_no_close() {
  echo "$V" | grep -qi 'regression' \
    && echo "$V" | grep -qE 'role:engineer,stage:rework' \
    || { fail "ac2: verify does not describe filing a regression role:engineer,stage:rework bug"; return; }
  echo "$V" | grep -qiE 'regression[^.]*(name|script)|(name|script)[^.]*regression' \
    && echo "$V" | grep -qiE 'behaviou?r[^.]*(protect|guard)|(protect|guard)[^.]*behaviou?r' \
    || { fail "ac2: bug must name the failing script and the behaviour it protects"; return; }
  echo "$V" | grep -qiE 'do not close|don.t close|not close' \
    || { fail "ac2: verify must say not to close the issue"; return; }
  pass "ac2: regression bug naming script + protected behaviour; verify stays open"
}

test_ac3_deliberate_change_stated_explicitly_not_edit_old_test() {
  echo "$V" | grep -qiE 'deliberate|intended|intentionally' \
    && echo "$V" | grep -qi 'needs-human' \
    || { fail "ac3: verify does not cover deliberately-changed earlier behaviour with bug/needs-human note"; return; }
  echo "$V" | grep -qiE "(do not|don.t|never|not)[^.]*(edit|delete|modify|change|remove)[^.]*(old|earlier|other|that|those)?[^.]*test" \
    || { fail "ac3: verify must forbid silently editing/deleting the old test"; return; }
  pass "ac3: deliberate-change case is stated explicitly; old test not silently edited"
}

test_ac4_handoff_states_count_and_none_failed() {
  echo "$V" | grep -qiE '(how many|number|count)[^.]*(script|test)' \
    && echo "$V" | grep -qiE 'none failed|no failures|0 failed|zero fail|none fail' \
    || { fail "ac4: closing comment must state how many scripts ran and that none failed"; return; }
  pass "ac4: handoff comment states script count and none failed"
}

test_ac5_usage_limit_test_named_and_failure_is_regression() {
  echo "$V" | grep -qiE 'usage-limit|usage limit|quota' \
    && echo "$V" | grep -qE 'agent-factory-stg' \
    || { fail "ac5: verify does not name the usage-limit/quota test from agent-factory-stg"; return; }
  echo "$V" | grep -qiE '(usage|quota)[^.]*regression|regression[^.]*(usage|quota)|(usage|quota)[^.]*(fail|missing)' \
    || { fail "ac5: failure of the usage-limit test must be reported as a regression"; return; }
  pass "ac5: usage-limit test called out; failure = regression"
}

test_out_of_scope_tests_and_rework_procedures_unchanged() {
  local t r
  t=$(awk '/^\*\*stage:tests\*\*/{on=1} /^\*\*stage:verify\*\*/{on=0} on' agents/qa.md)
  r=$(awk '/^\*\*stage:rework\*\*/{on=1} on' agents/qa.md)
  echo "$t" | grep -q 'Read the story ONLY' && echo "$r" | grep -qi 'fix the tests directly' \
    && pass "scope: stage:tests and stage:rework procedures intact" \
    || fail "scope: stage:tests / stage:rework procedures were altered"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
