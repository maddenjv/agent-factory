#!/usr/bin/env bash
# Acceptance tests for agent-factory-h71: reviewer routes merge conflicts to rework.
# One function per acceptance criterion in docs/stories/agent-factory-h71.md (test_acN_...).
# The "code" under test is the role prompts, so these are content checks on agents/*.md,
# scoped to the reviewer's merge-conflict handling (not the rest of the prompt).
# Run directly: bash tests/agent-factory-h71_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# Reviewer text from the first line mentioning conflicts up to the "Request changes" section.
conflict_section() {
  awk '/[Cc]onflict/ && !on {on=1} /Request changes/ && on {exit} on' agents/reviewer.md
}
# Same, from the engineer/qa prompt: only the lines from a "conflict" mention to the next blank/bullet break
# is too brittle, so use the whole stage:rework section of the file.
rework_section() { awk '/stage:rework/ {on=1} on' "agents/$1.md"; }

test_ac1_conflict_does_not_use_needs_human() {
  local s; s=$(conflict_section)
  [ -n "$s" ] || { fail "ac1: no merge-conflict handling found in agents/reviewer.md"; return; }
  # Any mention of needs-human in the conflict text must be a prohibition.
  local bad
  bad=$(echo "$s" | grep -i 'needs-human' | grep -viE 'never|not|no |instead of|don.t' || true)
  [ -z "$bad" ] || { fail "ac1: conflict handling routes to needs-human: $bad"; return; }
  echo "$s" | grep -qiE 'rework' || { fail "ac1: conflict handling does not mention rework"; return; }
  # The old behaviour ("labels its issue needs-human" on conflict) must be gone from the approve step.
  if grep -iE 'conflict' agents/reviewer.md | grep -iE 'needs-human' | grep -qviE 'never|not|instead|no '; then
    fail "ac1: a conflict line in reviewer.md still sends to needs-human"; return
  fi
  pass "ac1: merge conflict is routed to rework, not needs-human"
}

test_ac2_non_test_conflicts_go_to_engineer() {
  local s; s=$(conflict_section)
  echo "$s" | grep -q 'role:engineer' && echo "$s" | grep -q 'stage:rework' && echo "$s" | grep -q 'story:<story-id>' \
    || { fail "ac2: conflict rework issue not labelled role:engineer,stage:rework,story:<story-id>"; return; }
  echo "$s" | grep -qiE 'non-test|code|docs' || { fail "ac2: no rule mapping non-test/code/docs files to engineer"; return; }
  echo "$s" | grep -qiE '(non-test|code|docs)[^.]*(->|→|=>|:|go|goes|route|to)[^.]*role:engineer' \
    || { fail "ac2: engineer not tied to non-test files"; return; }
  pass "ac2: non-test conflicts -> role:engineer rework"
}

test_ac3_test_only_conflicts_go_to_qa() {
  local s; s=$(conflict_section)
  echo "$s" | grep -q 'role:qa' || { fail "ac3: no role:qa routing in conflict handling"; return; }
  echo "$s" | grep -qiE '(all|only)[^.]*test[^.]*(->|→|=>|:|go|goes|route|to)[^.]*role:qa' \
    || { fail "ac3: role:qa not tied to all-test conflicts"; return; }
  pass "ac3: all-test conflicts -> role:qa rework"
}

test_ac4_mixed_conflicts_go_to_engineer() {
  local s; s=$(conflict_section)
  echo "$s" | grep -qiE '(mixed|both|code and tests?|tests? and code)[^.]*(->|→|=>|:|go|goes|route|to)[^.]*role:engineer' \
    || { fail "ac4: mixed code+test conflicts not routed to role:engineer"; return; }
  pass "ac4: mixed conflicts -> role:engineer rework"
}

test_ac5_description_names_files_commits_and_asks_for_update() {
  local s; s=$(conflict_section)
  echo "$s" | grep -qiE 'conflicting files|files in conflict|--diff-filter=U' || { fail "ac5: description does not name conflicting files"; return; }
  echo "$s" | grep -qiE 'commits' || { fail "ac5: description does not name commits involved"; return; }
  echo "$s" | grep -q 'origin/main' || { fail "ac5: no request to update against origin/main"; return; }
  echo "$s" | grep -qiE 'resolv' || { fail "ac5: no request to resolve conflicts"; return; }
  echo "$s" | grep -qiE 'push' || { fail "ac5: no request to push the branch"; return; }
  pass "ac5: description names files, commits, and asks to merge origin/main, resolve, push"
}

test_ac6_linked_dependent_and_reopened() {
  local s; s=$(conflict_section)
  echo "$s" | grep -q 'discovered-from' || { fail "ac6: no discovered-from link"; return; }
  echo "$s" | grep -qE 'bd dep add <your-issue> <' || { fail "ac6: review issue not made to depend on rework issue"; return; }
  echo "$s" | grep -qE 'status open' || { fail "ac6: review issue not set back to open"; return; }
  pass "ac6: discovered-from link, review depends on rework, review reopened"
}

test_ac7_merge_aborted_main_clean_nothing_pushed() {
  local s; s=$(conflict_section)
  echo "$s" | grep -q 'git merge --abort' || { fail "ac7: no git merge --abort"; return; }
  echo "$s" | grep -qiE 'clean' || { fail "ac7: no check that main is left clean"; return; }
  echo "$s" | grep -qiE 'never[^.]*push|not push|do not push|don.t push|nothing[^.]*pushed' \
    || { fail "ac7: does not say nothing is pushed after failed merge"; return; }
  # abort must come before the rework issue is filed / issue reopened
  local a c
  a=$(echo "$s" | grep -n 'merge --abort' | head -1 | cut -d: -f1)
  c=$(echo "$s" | grep -n 'bd create' | head -1 | cut -d: -f1)
  [ -n "$c" ] && [ "$a" -le "$c" ] || { fail "ac7: merge --abort not before bd create"; return; }
  pass "ac7: merge aborted, main verified clean, nothing pushed"
}

test_ac8_engineer_and_qa_prompts_handle_conflict_rework() {
  local r s
  for r in engineer qa; do
    s=$(rework_section "$r")
    echo "$s" | grep -qiE 'conflict' || { fail "ac8: $r rework section does not cover conflict resolution"; return; }
    echo "$s" | grep -qE 'git (merge|rebase) origin/main|merge origin/main|rebase origin/main' \
      || { fail "ac8: $r prompt does not say to merge/rebase origin/main"; return; }
    echo "$s" | grep -qiE 'resolve' || { fail "ac8: $r prompt does not say to resolve conflicts"; return; }
    echo "$s" | grep -qiE 'suite|tests' || { fail "ac8: $r prompt does not say to re-run the test suite"; return; }
    echo "$s" | grep -qiE 'push' || { fail "ac8: $r prompt does not say to push"; return; }
  done
  pass "ac8: engineer and qa prompts cover conflict-resolution rework"
}

test_ac_out_of_scope_rework_cap_and_request_changes_intact() {
  grep -q 'Request changes' agents/reviewer.md && grep -qE 'role:architect,stage:rework' agents/reviewer.md \
    && grep -qE '2 or more `stage:rework`' agents/reviewer.md \
    || { fail "regression: request-changes flow or 2-rework cap removed from reviewer.md"; return; }
  pass "regression: request-changes flow and 2-rework cap still present"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
