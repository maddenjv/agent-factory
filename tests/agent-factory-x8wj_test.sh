#!/usr/bin/env bash
# Acceptance tests for agent-factory-x8wj: team-lead sizes each story's stage chain to its
# complexity. One function per acceptance criterion in docs/stories/agent-factory-x8wj.md
# (test_acN_...).
#
# This story is deliberately "no fixed rubric" (out of scope: no formal/numeric rubric for
# simple vs complex) - the actual decision of which stages to include is an LLM judgment call by
# team-lead, not something a fixture can drive through canned `claude`/`bd` stubs the way
# tests/agent-factory-dx0_test.sh or tests/agent-factory-m7af_test.sh exercise their mechanical
# polling logic. So AC1-AC6 here are content checks on agents/po.md (which must stop
# unconditionally building the full chain itself) and agents/team-lead.md (which must gain the
# sizing responsibility, its bias rules, and its recording requirement) - the same style
# tests/agent-factory-dx0_test.sh and tests/agent-factory-m7af_test.sh already use for prose
# instructions that drive a role's decision-making rather than deterministic code.
#
# AC7 is the one part of this story that IS deterministic code today: "a fully complex story ends
# up with exactly the same five-stage chain... this story changes nothing about the chain for work
# that genuinely needs every stage" - i.e. bin/new-story.sh's own output for the no-stages-skipped
# case must stay byte-for-byte the same shape it is today. That's run directly, the same way
# tests/agent-factory-icv_test.sh already pins new-story.sh's graph shape: a stub `bd` on PATH
# records `create`/`dep add` calls, `bin/new-story.sh` runs for real, and the resulting dependency
# graph is asserted. Unlike every other test in this file, this one is expected to PASS already
# (no code has to change for the "chain doesn't shrink" case) - it's a regression guard, not a
# not-yet-implemented check: if a later change to new-story.sh's default (no-stage-skipped) output
# shape breaks it, that's exactly the AC7 regression this test exists to catch.
#
# Written BEFORE implementation: expect every AC1-AC6 test below to fail right now, for the
# legitimate reason that neither agents/po.md nor agents/team-lead.md mentions team-lead sizing a
# new story's stage chain at all yet (confirmed by reading both files: po.md step 6 unconditionally
# runs `new-story.sh` with no team-lead involvement, and team-lead.md only knows about the
# needs-team-lead triage and no-role-label sweep from agent-factory-dx0/agent-factory-m7af).
#
# Run directly: bash tests/agent-factory-x8wj_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

PO="agents/po.md"
TL="agents/team-lead.md"
po_content=$(cat "$PO")
tl_content=$(cat "$TL")

# ============================================================
# AC1 - team-lead, not po and not a fixed default, decides which stages a story's chain includes,
# before any of that story's stage issues is ready for its role's queue.
# ============================================================

test_ac1_po_no_longer_unconditionally_builds_the_full_chain_itself() {
  # po.md step 6 today reads only: "Create the stage chain: $KIT_DIR/bin/new-story.sh <id> ...".
  # That's po applying a fixed default with no team-lead involvement - exactly what AC1 forbids.
  local step6; step6=$(echo "$po_content" | sed -n '/^6\./,/^7\./p')
  [ -n "$step6" ] || { fail "ac1: agents/po.md has no numbered step 6 to inspect"; return; }
  echo "$step6" | grep -qi 'team-lead' \
    && pass "ac1: agents/po.md step 6 hands the stage-chain decision to team-lead rather than applying a fixed default itself" \
    || fail "ac1: agents/po.md step 6 still just runs new-story.sh unconditionally with no mention of team-lead deciding anything: $step6"
}

test_ac1_team_lead_prompt_owns_the_chain_sizing_decision() {
  echo "$tl_content" | grep -qiE 'stage chain|which (of the )?(five )?stages' \
    || { fail "ac1: agents/team-lead.md never mentions deciding a story's stage chain / which stages it needs"; return; }
  echo "$tl_content" | grep -qiE 'new stor(y|ies)|(a )?story is (first )?created|before.{0,40}(stage )?issue.{0,40}ready|ready for.{0,40}(role.?s )?queue' \
    || { fail "ac1: agents/team-lead.md doesn't tie the sizing decision to a new story, made before any stage issue is ready for its role's queue"; return; }
  pass "ac1: agents/team-lead.md documents owning the new-story stage-chain sizing decision"
}

# ============================================================
# AC2 - when team-lead judges the work complex, unclear in scope, or is simply unsure, it includes
# design and write-tests rather than skipping them.
# ============================================================

test_ac2_favors_including_design_and_tests_when_unsure() {
  echo "$tl_content" | grep -qiE 'complex|unclear|unsure|in doubt' \
    || { fail "ac2: agents/team-lead.md has no language about complexity/uncertainty driving the sizing decision"; return; }
  echo "$tl_content" | grep -qiE 'includ|favor|err (on the side|toward)' \
    || { fail "ac2: agents/team-lead.md doesn't say to favor including stages when unsure"; return; }
  echo "$tl_content" | grep -qiE '\bdesign\b.{0,60}\b(write-)?tests\b|\b(write-)?tests\b.{0,60}\bdesign\b' \
    || { fail "ac2: agents/team-lead.md doesn't name design and write-tests together as the stages favored under uncertainty"; return; }
  pass "ac2: agents/team-lead.md favors including design and write-tests whenever the story is complex, unclear, or the call is unsure"
}

# ============================================================
# AC3 - existing tests already covering the behavior being changed is the ONLY basis, within this
# story, for skipping write-tests.
# ============================================================

test_ac3_write_tests_skipped_only_when_existing_tests_already_cover_the_behavior() {
  echo "$tl_content" | grep -qiE 'existing tests?.{0,60}(already )?cover' \
    || { fail "ac3: agents/team-lead.md doesn't mention skipping write-tests when existing tests already cover the behavior"; return; }
  echo "$tl_content" | grep -qiE 'only\b.{0,80}(skip|basis)|(skip|basis)\b.{0,80}\bonly\b' \
    || { fail "ac3: agents/team-lead.md doesn't say this is the ONLY basis for skipping write-tests (not a general default)"; return; }
  pass "ac3: agents/team-lead.md restricts skipping write-tests to existing-tests-already-cover-it, stated as the only basis"
}

# ============================================================
# AC4 - when design is skipped, implement proceeds without waiting on a design issue or
# docs/design/<id>.md; no dependency is left pointing at a stage that was never created.
# ============================================================

test_ac4_skipping_design_leaves_no_dangling_dependency_on_it() {
  echo "$tl_content" | grep -qiE 'skip.{0,40}design|design.{0,40}skip' \
    || { fail "ac4: agents/team-lead.md has no explicit handling for the case where design is skipped"; return; }
  echo "$tl_content" | grep -qiE 'no dependency|without waiting|remove.{0,30}depend|dep remove' \
    || { fail "ac4: agents/team-lead.md doesn't describe leaving implement free of a dependency on a design stage that was never created"; return; }
  pass "ac4: agents/team-lead.md ensures implement never waits on a design issue/dependency that was skipped"
}

# ============================================================
# AC5 - implement, verify, and review are always present, regardless of which stages were skipped.
# ============================================================

test_ac5_implement_verify_and_review_are_always_present() {
  echo "$tl_content" | grep -qiE '\bimplement\b.{0,80}\bverify\b.{0,80}\breview\b|\breview\b.{0,80}\bverify\b.{0,80}\bimplement\b' \
    || { fail "ac5: agents/team-lead.md never names implement, verify and review together"; return; }
  echo "$tl_content" | grep -qiE 'always (present|include|creat)|never (skip|omit)' \
    || { fail "ac5: agents/team-lead.md doesn't say implement/verify/review are always included and never skipped"; return; }
  pass "ac5: agents/team-lead.md states implement, verify, and review are always present, never skipped"
}

# ============================================================
# AC6 - the sizing decision (which stages included/skipped, and why) is recorded on the story's
# issues so it doesn't need to be re-derived from scratch later.
# ============================================================

test_ac6_sizing_decision_is_recorded_for_later_reading() {
  # Scope to a `bd comment` mentioned close to the sizing decision itself, not just any of the
  # several unrelated `bd comment` steps this file already has for the needs-team-lead/sweep flows.
  local near; near=$(echo "$tl_content" | grep -B3 -A3 -E 'bd comment[^s]')
  echo "$near" | grep -qiE 'skip|which stages|stages? (it |were |was )?(included|chosen|decided)' \
    || { fail "ac6: agents/team-lead.md has no bd comment step recorded near the stage-chain sizing decision (only pre-existing, unrelated bd comment steps found)"; return; }
  echo "$near" | grep -qiE 'why|reason|rationale' \
    || { fail "ac6: agents/team-lead.md doesn't require recording WHY stages were included/skipped near that bd comment, not just which"; return; }
  pass "ac6: agents/team-lead.md requires recording which stages were included/skipped and why, via bd comment"
}

# ============================================================
# AC7 - a fully-complex story ends up with exactly today's five-stage chain (design and
# write-tests in parallel, each feeding implement and verify, then review). This is the one
# deterministic, directly-runnable part of the story: bin/new-story.sh's own default output shape
# for the "nothing skipped" case must not change. Same stub-bd-on-PATH harness as
# tests/agent-factory-icv_test.sh, which already pins this exact graph.
# ============================================================

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

run_new_story() {
  rm -f "$TMP/n" "$TMP/log"
  STUB_DIR="$TMP" PATH="$TMP/bin:$PATH" bash bin/new-story.sh smoke "smoke" >/dev/null 2>&1
  LOG="$TMP/log"
  id_for() { grep '^create' "$LOG" | grep "stage:$1" | head -1 | sed 's/^create \([^|]*\)|.*/\1/'; }
  D=$(id_for design); T=$(id_for tests); I=$(id_for implement); V=$(id_for verify); R=$(id_for review)
}
deps_of() { grep "^dep $1 " "$LOG" | awk '{print $3}' | sort | tr '\n' ' ' | sed 's/ $//'; }
sorted() { printf '%s\n' "$@" | sort | tr '\n' ' ' | sed 's/ $//'; }

test_ac7_fully_complex_story_gets_the_unchanged_five_stage_chain() {
  run_new_story
  [ -n "$D" ] && [ -n "$T" ] && [ -n "$I" ] && [ -n "$V" ] && [ -n "$R" ] \
    || { fail "ac7: not all five stage issues were created by bin/new-story.sh: design=$D tests=$T implement=$I verify=$V review=$R"; return; }
  [ -z "$(deps_of "$D")" ] || { fail "ac7: design has deps: $(deps_of "$D") - expected none (parallel root)"; return; }
  [ -z "$(deps_of "$T")" ] || { fail "ac7: write-tests has deps: $(deps_of "$T") - expected none (parallel root)"; return; }
  [ "$(deps_of "$I")" = "$D" ] || { fail "ac7: implement deps='$(deps_of "$I")' expected '$D' (design only)"; return; }
  [ "$(deps_of "$V")" = "$(sorted "$I" "$T")" ] || { fail "ac7: verify deps='$(deps_of "$V")' expected '$(sorted "$I" "$T")' (implement AND write-tests)"; return; }
  [ "$(deps_of "$R")" = "$V" ] || { fail "ac7: review deps='$(deps_of "$R")' expected '$V' (verify only)"; return; }
  pass "ac7: bin/new-story.sh's default (nothing-skipped) output is still the unchanged five-stage fork/join chain"
}

test_ac7_team_lead_prompt_names_the_full_chain_for_complex_work() {
  echo "$tl_content" | grep -qiE 'five.?stage|design.{0,40}write-tests.{0,80}parallel|all five stages' \
    && pass "ac7: agents/team-lead.md documents that fully complex work gets the standard five-stage chain" \
    || fail "ac7: agents/team-lead.md doesn't say a fully complex story gets the unchanged five-stage chain"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
