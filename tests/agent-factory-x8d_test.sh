#!/usr/bin/env bash
# Acceptance tests for agent-factory-x8d: restart implementation when conflict rework is unresolvable.
# One function per acceptance criterion in docs/stories/agent-factory-x8d.md (test_acN_...).
# The "code" under test is bin/*.sh and the role prompts, so these are content checks. They are
# deliberately independent of WHERE the restart logic lives: it may be in agent-loop.sh, a new
# bin/ script, or the role prompts, so they inspect the "restart corpus" - every bin/*.sh and
# agents/*.md file that mentions restarting a story.
# Run directly: bash tests/agent-factory-x8d_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# Files that implement or describe the restart (case-insensitive "restart" near story/implement).
restart_files() { grep -liE 'restart' bin/*.sh agents/*.md 2>/dev/null | grep -v 'bin/\(start\|stop\|init\|ops-shell\|smoke-test\)\.sh' || true; }
corpus() { local f; for f in $(restart_files); do cat "$f"; echo; done; }
# Lines mentioning restart (and the 3 following lines for context).
restart_ctx() { corpus | grep -iE -A3 'restart'; }

need_corpus() { [ -n "$(restart_files)" ] || { fail "$1: no bin/*.sh or agents/*.md file implements a story restart"; return 1; }; }

test_ac1_unresolvable_conflict_rework_restarts_story() {
  need_corpus ac1 || return
  local r s
  for r in engineer qa; do
    s=$(awk '/stage:rework/ {on=1} on' "agents/$r.md")
    echo "$s" | grep -qiE 'unresolv' || { fail "ac1: $r rework section has no 'unresolvable' path"; return; }
    echo "$s" | grep -qiE 'restart' || { fail "ac1: $r rework section does not trigger a restart when unresolvable"; return; }
    echo "$s" | grep -qiE 'note|--append-notes|reason' || { fail "ac1: $r unresolvable path does not require a note saying why"; return; }
  done
  # The unresolvable path must not end in needs-human for the story.
  for r in engineer qa; do
    if awk '/[Uu]nresolv/ {on=1} on' "agents/$r.md" | grep -iE 'unresolv[^.]*needs-human' | grep -qviE 'not|never|instead'; then
      fail "ac1: $r unresolvable path still labels needs-human"; return
    fi
  done
  pass "ac1: unresolvable conflict rework (engineer/qa) restarts the story, with a note"
}

test_ac2_attempt_cap_on_conflict_rework_restarts_story() {
  need_corpus ac2 || return
  grep -qE 'MAX_ATTEMPTS_PER_ISSUE' bin/agent-loop.sh || { fail "ac2: agent-loop.sh lost the attempt cap"; return; }
  # record_failure must consult conflict-rework status / restart before (or instead of) needs-human.
  local rf; rf=$(awk '/^record_failure\(\)/ {on=1} on {print} on && /^}/ {exit}' bin/agent-loop.sh)
  echo "$rf" | grep -qiE 'restart|conflict' || { fail "ac2: record_failure does not restart a story whose conflict rework hit the cap"; return; }
  echo "$rf" | grep -qE 'needs-human' || { fail "ac2: record_failure no longer labels needs-human for ordinary issues (AC8 regression)"; return; }
  pass "ac2: attempt cap on a conflict rework triggers restart in agent-loop.sh"
}

test_ac3_new_implement_verify_review_chain() {
  need_corpus ac3 || return
  local c; c=$(corpus)
  echo "$c" | grep -qE 'role:engineer,stage:implement|mk engineer implement' || { fail "ac3: no role:engineer,stage:implement issue created"; return; }
  echo "$c" | grep -qE 'role:qa,stage:verify|mk qa verify' || { fail "ac3: no role:qa,stage:verify issue created"; return; }
  echo "$c" | grep -qE 'role:reviewer,stage:review|mk reviewer review' || { fail "ac3: no role:reviewer,stage:review issue created"; return; }
  echo "$c" | grep -qE 'story:\$\{?[a-z_]+\}?|story:<story-id>|story:<id>' || { fail "ac3: new issues not labelled story:<id>"; return; }
  [ "$(echo "$c" | grep -cE 'bd dep add')" -ge 2 ] || { fail "ac3: fewer than 2 'bd dep add' calls (need verify->implement, review->verify)"; return; }
  pass "ac3: implement -> verify -> review chain created with roles/labels"
}

test_ac4_old_issues_closed_with_restart_reason() {
  need_corpus ac4 || return
  local c; c=$(corpus)
  echo "$c" | grep -qE 'bd close[^\n]*(--reason|-r)[^\n]*[Rr]estart' || { fail "ac4: old issues not closed with a reason referencing the restart"; return; }
  echo "$c" | grep -qiE 'implement' && echo "$c" | grep -qiE 'verify' && echo "$c" | grep -qiE 'review' \
    && echo "$c" | grep -qiE 'rework' || { fail "ac4: not all of implement/verify/review/rework named as closed"; return; }
  pass "ac4: old implement/verify/review/rework issues closed with restart reason"
}

test_ac5_new_implement_description() {
  need_corpus ac5 || return
  local c; c=$(corpus)
  echo "$c" | grep -q 'origin/main' || { fail "ac5: description does not mention origin/main"; return; }
  echo "$c" | grep -qiE 'discard|throw away|abandon|from scratch|fresh' || { fail "ac5: does not say to discard the old implementation"; return; }
  echo "$c" | grep -qE 'docs/design/' || { fail "ac5: does not point at docs/design/<id>.md"; return; }
  echo "$c" | grep -qiE 'acceptance tests' || { fail "ac5: does not mention making existing acceptance tests pass"; return; }
  pass "ac5: new implement description covers origin/main, discard, design doc, acceptance tests"
}

test_ac6_no_design_or_tests_issue_and_comment_recorded() {
  need_corpus ac6 || return
  local c; c=$(corpus)
  # Only bin/ scripts create issues; role prompts (e.g. qa.md) legitimately mention their own stages.
  cat $(restart_files | grep '^bin/') | grep -qE 'stage:design|stage:tests|mk (architect|qa) (design|tests)' \
    && { fail "ac6: restart logic creates design/tests issues"; return; }
  echo "$c" | grep -qE 'bd comment' || { fail "ac6: restart is not recorded with bd comment"; return; }
  echo "$c" | grep -qiE 'unresolvable' && echo "$c" | grep -qiE 'attempt cap|attempts' \
    || { fail "ac6: comment does not distinguish reasons (unresolvable / attempt cap)"; return; }
  pass "ac6: no design/tests issue; restart recorded via bd comment with reason"
}

test_ac7_second_restart_escalates_to_needs_human() {
  need_corpus ac7 || return
  local c; c=$(corpus)
  echo "$c" | grep -qiE 'already (been )?restarted|restarted (once|before|already)|second restart|restart(ed)? (a )?(second|twice)|only once|not (be )?restart(ed)? again|never restart(ed)? twice' \
    || { fail "ac7: no guard against restarting a story twice"; return; }
  echo "$c" | grep -qE 'needs-human' || { fail "ac7: repeat failure does not label needs-human"; return; }
  echo "$c" | grep -qE 'append-notes' || { fail "ac7: repeat failure does not leave an explanatory note"; return; }
  pass "ac7: second restart is refused; review issue gets needs-human with a note"
}

test_ac8_non_conflict_rework_unchanged() {
  need_corpus ac8 || return
  local c; c=$(corpus)
  echo "$c" | grep -qiE 'not (a )?(merge[- ])?conflict|non-conflict|only (for )?(a )?(merge[- ])?conflict|ordinary|request.changes|other rework' \
    || { fail "ac8: restart logic does not restrict itself to merge-conflict rework"; return; }
  # Existing needs-human escalation path intact.
  grep -q 'needs-human' bin/agent-loop.sh && grep -q 'MAX_ATTEMPTS_PER_ISSUE' bin/agent-loop.sh \
    || { fail "ac8: needs-human/attempt-cap escalation removed from agent-loop.sh"; return; }
  grep -qE 'bd label add "\$id" needs-human' bin/agent-loop.sh \
    || { fail "ac8: agent-loop.sh no longer labels needs-human at the cap"; return; }
  pass "ac8: restart restricted to conflict rework; ordinary escalation intact"
}

test_regression_new_story_and_reviewer_rework_intact() {
  grep -q 'implement' bin/new-story.sh && grep -q 'Request changes' agents/reviewer.md \
    || { fail "regression: new-story.sh stage graph or reviewer request-changes flow damaged"; return; }
  pass "regression: new-story.sh and reviewer request-changes still present"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
