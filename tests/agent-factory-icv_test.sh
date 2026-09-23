#!/usr/bin/env bash
# Acceptance tests for agent-factory-icv: parallel design/implement + write-tests tracks.
# One function per acceptance criterion in docs/stories/agent-factory-icv.md (test_acN_...).
# Graph tests run bin/new-story.sh with a stub `bd` on PATH that records creates and dep edges.
# Run directly: bash tests/agent-factory-icv_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/bd" <<'STUB'
#!/usr/bin/env bash
# Stub: `create` -> issue-N (log "create N|labels|desc"); `dep add A B` -> log "dep A B"; else no-op.
n=$(cat "$STUB_DIR/n" 2>/dev/null || echo 0)
case "$1" in
  create)
    n=$((n+1)); echo "$n" > "$STUB_DIR/n"
    labels=""; desc=""; shift
    while [ $# -gt 0 ]; do
      case "$1" in -l) labels=$2; shift;; -d) desc=$2; shift;; esac; shift
    done
    echo "create issue-$n|$labels|$desc" >> "$STUB_DIR/log"
    echo "{\"id\":\"issue-$n\"}";;
  dep) [ "$2" = add ] && echo "dep $3 $4" >> "$STUB_DIR/log";;
esac
exit 0
STUB
chmod +x "$TMP/bin/bd"

# Runs new-story.sh; sets globals D T I V R and LOG (path).
run_new_story() {
  rm -f "$TMP/n" "$TMP/log"
  STUB_DIR="$TMP" PATH="$TMP/bin:$PATH" bash bin/new-story.sh smoke "smoke" >/dev/null 2>&1
  LOG="$TMP/log"
  id_for() { grep '^create' "$LOG" | grep "stage:$1" | head -1 | sed 's/^create \([^|]*\)|.*/\1/'; }
  D=$(id_for design); T=$(id_for tests); I=$(id_for implement); V=$(id_for verify); R=$(id_for review)
}
# deps_of X -> sorted space-joined list of issues X depends on
deps_of() { grep "^dep $1 " "$LOG" | awk '{print $3}' | sort | tr '\n' ' ' | sed 's/ $//'; }
sorted() { printf '%s\n' "$@" | sort | tr '\n' ' ' | sed 's/ $//'; }

test_ac1_design_and_tests_are_independent_roots() {
  run_new_story
  [ -n "$D" ] && [ -n "$T" ] || { fail "ac1: could not find design/tests issues"; return; }
  [ -z "$(deps_of "$D")" ] || { fail "ac1: design has deps: $(deps_of "$D")"; return; }
  [ -z "$(deps_of "$T")" ] || { fail "ac1: tests has deps: $(deps_of "$T")"; return; }
  pass "ac1: design and write-tests have no dependencies (both ready)"
}

test_ac2_write_tests_scoped_to_acceptance_criteria_only() {
  run_new_story
  local desc; desc=$(grep "^create $T|" "$LOG" | cut -d'|' -f3-)
  if echo "$desc" | grep -q 'docs/design'; then
    # Allowed only as an explicit prohibition.
    echo "$desc" | grep -qiE "(do not|don't|not) (read|depend|reference|use)[^.]*docs/design" \
      || { fail "ac2: tests description references docs/design without prohibiting it"; return; }
  fi
  echo "$desc" | grep -qi 'acceptance criteria' || { fail "ac2: description doesn't mention acceptance criteria"; return; }
  echo "$desc" | grep -qi 'only' || { fail "ac2: description lacks 'only' scoping wording"; return; }
  pass "ac2: write-tests description scoped to acceptance criteria only"
}

test_ac2_qa_prompt_tests_stage_does_not_read_design() {
  local sect; sect=$(sed -n '/stage:tests/,/stage:verify/p' agents/qa.md)
  echo "$sect" | grep -qiE 'not[^.]*docs/design' || { fail "ac2: qa.md stage:tests doesn't forbid reading the design"; return; }
  pass "ac2: qa.md stage:tests forbids reading the design doc"
}

test_ac3_implement_depends_only_on_design() {
  run_new_story
  [ "$(deps_of "$I")" = "$D" ] && pass "ac3: implement depends only on design" \
    || fail "ac3: implement deps='$(deps_of "$I")' expected '$D'"
}

test_ac4_verify_depends_on_implement_and_tests() {
  run_new_story
  [ "$(deps_of "$V")" = "$(sorted "$I" "$T")" ] && pass "ac4: verify depends on implement AND write-tests" \
    || fail "ac4: verify deps='$(deps_of "$V")' expected '$(sorted "$I" "$T")'"
}

test_ac5_review_depends_only_on_verify() {
  run_new_story
  [ "$(deps_of "$R")" = "$V" ] && pass "ac5: review depends only on verify" \
    || fail "ac5: review deps='$(deps_of "$R")' expected '$V'"
}

test_ac6_tracks_use_own_branches() {
  local ok=1
  grep -q 'story/<story-id>/design' agents/architect.md || { fail "ac6: architect.md lacks story/<story-id>/design"; ok=0; }
  grep -q 'story/<story-id>/tests' agents/qa.md || { fail "ac6: qa.md lacks story/<story-id>/tests"; ok=0; }
  grep -q 'story/<story-id>/design' agents/engineer.md || { fail "ac6: engineer.md lacks design track branch"; ok=0; }
  grep -q '/design' agents/CLAUDE.project.md && grep -q '/tests' agents/CLAUDE.project.md \
    || { fail "ac6: CLAUDE.project.md doesn't document track branches"; ok=0; }
  [ "$ok" = 1 ] && pass "ac6: each track has its own branch in role prompts + conventions"
}

test_ac7_engineer_merges_design_branch_before_closing() {
  grep -qE 'git merge[^\n]*story/<story-id>/design' agents/engineer.md \
    && pass "ac7: engineer.md merges story/<story-id>/design into story/<story-id>" \
    || fail "ac7: engineer.md has no merge of the design branch"
}

test_ac8_qa_merges_tests_branch_at_verify() {
  local sect; sect=$(sed -n '/stage:verify/,$p' agents/qa.md)
  echo "$sect" | grep -qE 'git merge[^\n]*story/<story-id>/tests' \
    && pass "ac8: qa.md verify merges story/<story-id>/tests before running tests" \
    || fail "ac8: qa.md verify has no merge of the tests branch"
}

test_ac9_reviewer_design_defect_targets_architect() {
  grep -q 'role:architect,stage:rework' agents/reviewer.md || { fail "ac9: reviewer.md can't file role:architect rework"; return; }
  grep -q 'stage:rework' agents/architect.md || { fail "ac9: architect.md has no stage:rework flow"; return; }
  grep -q 'role:engineer,stage:rework' agents/architect.md || { fail "ac9: architect rework doesn't chain an engineer issue"; return; }
  pass "ac9: design defects route reviewer -> architect -> engineer"
}

test_ac10_reviewer_impl_defect_targets_engineer_only() {
  grep -q 'role:engineer,stage:rework' agents/reviewer.md && grep -qiE 'implementation' agents/reviewer.md \
    && pass "ac10: reviewer.md files engineer-only rework for implementation defects" \
    || fail "ac10: reviewer.md lacks implementation-only engineer rework path"
}

test_ac11_qa_rework_path_and_engineer_on_retest_failure() {
  grep -q 'role:qa,stage:rework' agents/reviewer.md || { fail "ac11: reviewer.md can't file role:qa rework"; return; }
  grep -qE 'stage:rework' agents/qa.md && grep -q 'Your issue is `stage:tests`, `stage:verify`, or `stage:rework`' agents/qa.md \
    || { fail "ac11: qa.md has no stage:rework handling"; return; }
  sed -n '/stage:rework/,$p' agents/qa.md | grep -q 'role:engineer,stage:rework' \
    || { fail "ac11: qa rework doesn't file engineer rework when corrected tests still fail"; return; }
  pass "ac11: qa rework path; failing corrected tests file engineer rework"
}

readme_flow() { sed -n '/^## Flow/,/^## Setup/p' README.md; }

test_ac12_readme_mermaid_diagram() {
  local m; m=$(sed -n '/```mermaid/,/```/p' README.md)
  [ -n "$m" ] || { fail "ac12: no mermaid block in README.md"; return; }
  local n
  for n in po architect engineer qa reviewer; do
    echo "$m" | grep -qw "$n" || { fail "ac12: mermaid diagram lacks '$n'"; return; }
  done
  echo "$m" | grep -qE 'po[^ ]* *--> *[^ ]*(architect)' && echo "$m" | grep -qE 'po[^ ]* *--> *[^ ]*qa' \
    || { fail "ac12: po does not fork to architect and qa"; return; }
  local back; back=$(echo "$m" | grep -cE 'reviewer[^-]*-- *"[^"]+" *--> *[^ ]*(architect|engineer|qa)')
  [ "$back" -ge 3 ] || { fail "ac12: expected 3 labelled reviewer->{architect,engineer,qa} arrows, found $back"; return; }
  pass "ac12: mermaid diagram with fork, join, three labelled rework arrows"
}

test_ac13_readme_flow_prose_describes_parallel_tracks() {
  local f; f=$(readme_flow)
  if echo "$f" | grep -q 'design -> tests -> implement -> verify -> review'; then
    fail "ac13: Flow still describes the linear chain"; return
  fi
  echo "$f" | grep -qi 'parallel' || { fail "ac13: Flow doesn't mention parallel tracks"; return; }
  echo "$f" | grep -qi 'merge' || { fail "ac13: Flow doesn't mention merging before review"; return; }
  echo "$f" | grep -qi 'rework' && echo "$f" | grep -qi 'architect' && echo "$f" | grep -qi 'qa' \
    || { fail "ac13: Flow doesn't describe rework paths (architect/engineer/qa)"; return; }
  pass "ac13: Flow describes parallel tracks, merge point, rework paths"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "---"; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
