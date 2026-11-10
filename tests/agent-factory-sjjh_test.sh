#!/usr/bin/env bash
# Acceptance tests for agent-factory-sjjh: every story always gets the default five-stage chain;
# the needs-chain sizing step (and --skip-design/--skip-tests, no-design/no-tests) is removed.
# One function per acceptance criterion in docs/stories/agent-factory-sjjh.md (test_acN_...).
#
# Mechanism-agnostic: who builds the chain (po directly, or something else) is the architect's call,
# so AC1 checks po.md's observable contract (no needs-chain issue filed; chain built by new-story.sh)
# plus a real run of bin/new-story.sh under a stub `bd` (same harness as tests/agent-factory-x8wj_test.sh).
# AC3/AC5 are absence checks over code and prose. AC6 is covered by the whole-suite run in verify, plus
# a guard here that no test script still passes --skip-design/--skip-tests to new-story.sh.
# Written BEFORE implementation: most tests are expected to FAIL now.
#
# Run directly: bash tests/agent-factory-sjjh_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/bd" <<'STUB'
#!/usr/bin/env bash
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
  update) echo "update $*" >> "$STUB_DIR/log";;
esac
exit 0
STUB
chmod +x "$TMP/bin/bd"

LOG="$TMP/log"; NS_RC=0
run_new_story() {  # run_new_story [env=VAL ...] -- [args]
  rm -f "$TMP/n" "$LOG"; local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env "${envs[@]}" STUB_DIR="$TMP" PATH="$TMP/bin:$PATH" bash bin/new-story.sh smoke "smoke" "$@" >"$TMP/out" 2>&1
  NS_RC=$?; touch "$LOG"
  id_for() { grep '^create' "$LOG" | grep "stage:$1" | head -1 | sed 's/^create \([^|]*\)|.*/\1/'; }
  D=$(id_for design); T=$(id_for tests); I=$(id_for implement); V=$(id_for verify); R=$(id_for review)
}
deps_of() { grep "^dep $1 " "$LOG" | awk '{print $3}' | sort | tr '\n' ' ' | sed 's/ $//'; }
labels_of() { grep "^create $1|" "$LOG" | head -1 | cut -d'|' -f2; }
sorted() { printf '%s\n' "$@" | sort | tr '\n' ' ' | sed 's/ $//'; }

PO=agents/po.md
LIVE_DOCS=(agents/po.md agents/architect.md agents/engineer.md agents/qa.md agents/reviewer.md agents/team-lead.md README.md docs/ARCHITECTURE.md)

# AC1 - the full chain (same labels/deps/parallel tracks) exists after po, and po files no needs-chain issue.
test_ac1_default_chain_graph_unchanged() {
  run_new_story --
  [ "$NS_RC" = 0 ] || { fail "ac1: new-story.sh exited $NS_RC: $(cat "$TMP/out")"; return; }
  [ -n "$D" ] && [ -n "$T" ] && [ -n "$I" ] && [ -n "$V" ] && [ -n "$R" ] \
    || { fail "ac1: missing stage issue: design=$D tests=$T implement=$I verify=$V review=$R"; return; }
  [ -z "$(deps_of "$D")" ] && [ -z "$(deps_of "$T")" ] || { fail "ac1: design/tests must be parallel roots"; return; }
  [ "$(deps_of "$I")" = "$D" ] || { fail "ac1: implement deps='$(deps_of "$I")' expected '$D'"; return; }
  [ "$(deps_of "$V")" = "$(sorted "$I" "$T")" ] || { fail "ac1: verify deps wrong: '$(deps_of "$V")'"; return; }
  [ "$(deps_of "$R")" = "$V" ] || { fail "ac1: review deps='$(deps_of "$R")' expected '$V'"; return; }
  for pair in "$D:role:architect,stage:design" "$T:role:qa,stage:tests" "$I:role:engineer,stage:implement" \
              "$V:role:qa,stage:verify" "$R:role:reviewer,stage:review"; do
    local l; l=$(labels_of "${pair%%:*}")
    case ",$l," in *",${pair#*:},"*|*"${pair#*:}"*) ;; *) fail "ac1: ${pair%%:*} labels '$l' lack ${pair#*:}"; return;; esac
    echo "$l" | grep -q "story:smoke" || { fail "ac1: ${pair%%:*} labels '$l' lack story:smoke"; return; }
  done
  pass "ac1: new-story.sh builds the five-stage fork/join chain with role/stage/story labels"
}

test_ac1_no_needs_chain_issue_created_by_po_or_chain() {
  run_new_story --
  grep -q 'needs-chain' "$LOG" && { fail "ac1: chain build created an issue labelled needs-chain"; return; }
  grep -qE 'needs-chain' "$PO" && { fail "ac1: agents/po.md still mentions needs-chain"; return; }
  grep -q 'new-story.sh' "$PO" || { fail "ac1: agents/po.md no longer builds the chain via bin/new-story.sh (nothing else would)"; return; }
  grep -qE 'role:team-lead' "$PO" && { fail "ac1: agents/po.md still files a role:team-lead issue for the story"; return; }
  pass "ac1: po builds the chain itself via new-story.sh and files no needs-chain / team-lead sizing issue"
}

# AC2 - no skip options, no no-design/no-tests labels.
test_ac2_skip_flags_rejected() {
  local f
  for f in --skip-design --skip-tests; do
    run_new_story -- "$f"
    [ "$NS_RC" != 0 ] || { fail "ac2: new-story.sh accepted $f (exit 0)"; return; }
    [ -z "$D$T$I$V$R" ] || { fail "ac2: $f still created stage issues"; return; }
  done
  pass "ac2: --skip-design and --skip-tests are rejected, no issues created"
}

test_ac2_no_skip_labels_or_alt_descriptions_in_script() {
  grep -nE 'skip[-_]design|skip[-_]tests|no-design|no-tests' bin/new-story.sh >"$TMP/h" \
    && { fail "ac2: bin/new-story.sh still references skip/no-design/no-tests: $(head -3 "$TMP/h" | tr '\n' ' ')"; return; }
  run_new_story --
  grep -qE 'no-design|no-tests' "$LOG" && { fail "ac2: default chain carries no-design/no-tests"; return; }
  pass "ac2: new-story.sh has no skip options and the chain carries no no-design/no-tests label"
}

# AC3 - needs-chain is not a recognised label for polling/selection/capacity/System 1.
test_ac3_agent_loop_and_system1_ignore_needs_chain() {
  local f bad=""
  for f in bin/agent-loop.sh bin/system1.sh bin/system1-lib.sh bin/new-story.sh; do
    [ -f "$f" ] && grep -q 'needs-chain' "$f" && bad="$bad $f"
  done
  [ -z "$bad" ] || { fail "ac3: needs-chain still referenced in:$bad"; return; }
  grep -qE 'KIND=chain|chain\)' bin/system1.sh && { fail "ac3: bin/system1.sh still has a 'chain' decision kind"; return; }
  grep -qE 'skip_design|skip_tests' bin/system1.sh && { fail "ac3: bin/system1.sh still has skip_design/skip_tests decisions"; return; }
  pass "ac3: agent-loop.sh / system1.sh no longer recognise needs-chain or a chain decision kind"
}

test_ac3_team_lead_prompt_has_no_chain_sizing_task() {
  grep -qiE "needs-chain|size a new story|size the chain|chain.sizing" agents/team-lead.md \
    && { fail "ac3: agents/team-lead.md still describes chain sizing / needs-chain"; return; }
  pass "ac3: agents/team-lead.md has no chain sizing task"
}

# AC3 functional: an issue labelled needs-chain with role:team-lead is treated like any other
# team-lead-routed issue (not specially selected). Pin that next_issue's team-lead branch has no
# needs-chain special case -- covered by the grep above; nothing more to stub deterministically.

# AC4 - HUMAN_APPROVE_STORIES=1 still gates the design issue.
test_ac4_human_approve_gates_design() {
  run_new_story HUMAN_APPROVE_STORIES=1 --
  [ -n "$D" ] || { fail "ac4: no design issue"; return; }
  labels_of "$D" | grep -q 'needs-human' || { fail "ac4: design labels '$(labels_of "$D")' lack needs-human"; return; }
  for x in "$T" "$I" "$V" "$R"; do
    labels_of "$x" | grep -q needs-human && { fail "ac4: $x wrongly gated"; return; }
  done
  grep -q "^update .*$D.*HUMAN_APPROVE_STORIES" "$LOG" || { fail "ac4: design issue lacks the explanatory note"; return; }
  run_new_story HUMAN_APPROVE_STORIES=0 --
  labels_of "$D" | grep -q needs-human && { fail "ac4: gated without HUMAN_APPROVE_STORIES=1"; return; }
  pass "ac4: HUMAN_APPROVE_STORIES=1 gates only the design issue, with note; ungated otherwise"
}

# AC5 - docs/prompts describe none of the removed workflow.
test_ac5_docs_and_prompts_have_no_sizing_or_skip_handling() {
  local f hits=""
  for f in "${LIVE_DOCS[@]}"; do
    grep -nE 'needs-chain|no-design|no-tests|--skip-design|--skip-tests|skip(ped)? (the )?(design|write-tests)|chain sizing|size a new story|Size a new story' "$f" \
      | sed "s|^|$f:|" >>"$TMP/docs-hits" 2>/dev/null
  done
  [ ! -s "$TMP/docs-hits" ] || { fail "ac5: stale references: $(head -5 "$TMP/docs-hits" | cut -c1-110 | tr '\n' ';')"; return; }
  pass "ac5: role prompts, README and ARCHITECTURE.md carry no chain-sizing / skip-stage text"
}

test_ac5_engineer_qa_prompts_no_longer_branch_on_missing_stages() {
  grep -qE 'no-design' agents/engineer.md && { fail "ac5: engineer.md still handles no-design"; return; }
  grep -qE 'no-tests' agents/qa.md && { fail "ac5: qa.md still handles no-tests"; return; }
  pass "ac5: engineer/qa prompts have no no-design/no-tests branches"
}

# AC6 - no remaining test drives the removed behaviour (full-suite pass is checked in stage:verify).
test_ac6_no_test_still_uses_removed_flags() {
  local hits; hits=$(grep -lE 'new-story\.sh[^|]*--skip-(design|tests)|run_new_story --skip' tests/*.sh tests/acceptance/*.sh 2>/dev/null | grep -v agent-factory-sjjh_test.sh)
  [ -z "$hits" ] || { fail "ac6: tests still exercise removed skip flags: $(echo $hits)"; return; }
  hits=$(grep -lE "grep[^|]*(needs-chain|no-design|no-tests)" tests/*.sh 2>/dev/null | grep -v agent-factory-sjjh_test.sh | tr '\n' ' ')
  [ -z "$hits" ] || { fail "ac6: tests still assert needs-chain/no-design/no-tests behaviour: $hits"; return; }
  pass "ac6: no remaining test asserts the removed sizing behaviour"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "---"; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
