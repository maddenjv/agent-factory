#!/usr/bin/env bash
# Acceptance tests for agent-factory-tox: hyphenated track branch names.
# One function per acceptance criterion in docs/stories/agent-factory-tox.md (test_acN_...).
# Run directly: bash tests/agent-factory-tox_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

NESTED='story/<(story-)?id>/(design|tests)'

test_ac1_design_branch_hyphenated_in_architect_and_engineer() {
  local f
  for f in architect engineer; do
    grep -q 'story/<story-id>-design' "agents/$f.md" || { fail "ac1: agents/$f.md lacks story/<story-id>-design"; return; }
  done
  if grep -qE 'story/<(story-)?id>/design' agents/*.md; then
    fail "ac1: a prompt still contains nested story/<story-id>/design"; return
  fi
  pass "ac1: architect/engineer name story/<story-id>-design; no nested design name in prompts"
}

test_ac2_tests_branch_hyphenated_in_qa() {
  grep -q 'story/<story-id>-tests' agents/qa.md || { fail "ac2: agents/qa.md lacks story/<story-id>-tests"; return; }
  if grep -qE 'story/<(story-)?id>/tests' agents/*.md; then
    fail "ac2: a prompt still contains nested story/<story-id>/tests"; return
  fi
  pass "ac2: qa names story/<story-id>-tests; no nested tests name in prompts"
}

test_ac3_track_branches_coexist_with_story_branch_local_and_origin() {
  local d; d=$(mktemp -d)
  if ( set -e; cd "$d"; git init -q --bare origin.git; git init -q w; cd w
       git config user.email t@t; git config user.name t
       git commit -q --allow-empty -m init; git checkout -q -b story/X
       git remote add origin ../origin.git; git push -q origin story/X
       git checkout -q -b story/X-design story/X; git push -q origin story/X-design
       git checkout -q -b story/X-tests story/X; git push -q origin story/X-tests
       git ls-remote --heads origin | grep -q 'story/X-design'
       git ls-remote --heads origin | grep -q 'story/X-tests' ) >/dev/null 2>&1; then
    pass "ac3: story/X-design and story/X-tests can be created and pushed alongside story/X"
  else
    fail "ac3: creating/pushing hyphenated track branches failed"
  fi
  rm -rf "$d"
}

test_ac3_prompts_create_track_branches_from_story_branch() {
  grep -qE 'story/<story-id>-design' agents/architect.md && grep -qE 'story/<story-id>-tests' agents/qa.md \
    && grep -qE 'create it from `story/<story-id>`' agents/architect.md agents/qa.md \
    && pass "ac3: architect and qa prompts create their track branch from story/<story-id>" \
    || fail "ac3: architect/qa prompts don't create the track branch from story/<story-id>"
}

test_ac4_engineer_merge_uses_hyphenated_design_branch() {
  grep -E 'git merge' agents/engineer.md | grep -q 'story/<story-id>-design' \
    && pass "ac4: engineer merge command references story/<story-id>-design" \
    || fail "ac4: engineer.md has no git merge of story/<story-id>-design"
}

test_ac4_qa_verify_merge_uses_hyphenated_tests_branch() {
  local sect; sect=$(sed -n '/stage:verify/,$p' agents/qa.md)
  echo "$sect" | grep -E 'git merge' | grep -q 'story/<story-id>-tests' || { fail "ac4: qa verify has no git merge of story/<story-id>-tests"; return; }
  echo "$sect" | grep 'git merge' | grep -q -e '--no-ff' || { fail "ac4: qa verify merge lost --no-ff"; return; }
  pass "ac4: qa verify merges story/<story-id>-tests with --no-ff (behaviour unchanged)"
}

test_ac5_readme_and_architecture_use_hyphenated_names_only() {
  if grep -qE "$NESTED" README.md docs/ARCHITECTURE.md; then
    fail "ac5: nested track names in README.md or docs/ARCHITECTURE.md"; return
  fi
  if grep -qE 'story/<[a-z-]+>/(design|tests)|story/[A-Za-z0-9_-]+/(design|tests)\b' README.md docs/ARCHITECTURE.md; then
    fail "ac5: nested-form track branch in README/ARCHITECTURE"; return
  fi
  pass "ac5: README and ARCHITECTURE contain no nested track branch names"
}

test_ac6_icv_acceptance_test_asserts_hyphenated_names_and_passes() {
  local f=tests/agent-factory-icv_test.sh
  grep -q 'story/<story-id>-design' "$f" && grep -q 'story/<story-id>-tests' "$f" \
    || { fail "ac6: $f doesn't assert hyphenated names"; return; }
  if grep -nE 'story/<[a-z-]+>/(design|tests)' "$f" | grep -v 'story/<(story-)?id>' | grep -q .; then
    fail "ac6: $f still asserts nested names"; return
  fi
  bash "$f" >/dev/null 2>&1 && pass "ac6: icv acceptance test passes with hyphenated names" \
    || fail "ac6: $f fails when run"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "---"; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
