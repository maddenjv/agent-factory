#!/usr/bin/env bash
# Acceptance tests for agent-factory-vfu3: a documented, lightweight merge path to `main` for
# small, storyless `discovered-from` follow-up work done on a `fix/<issue-id>` branch, so it
# never strands unmerged the way fix/agent-factory-367, fix/agent-factory-3lg and
# fix/agent-factory-wqd did.
# One function per acceptance criterion in docs/stories/agent-factory-vfu3.md (test_acN_...).
#
# Written BEFORE the design/implementation exist: none of CLAUDE.md, agents/CLAUDE.project.md,
# docs/ARCHITECTURE.md or agents/reviewer.md mention a `fix/` branch today, and all three stranded
# branches are still unmerged - so ac1-ac6 are expected to FAIL until that lands. That is failing
# for the right reason (the behaviour/documentation doesn't exist yet), not a broken test. The
# mechanical half of ac2 (bd's label-based routing already doesn't require a `story:` label)
# should already pass - it needs no code change, only documentation.
#
# ac1, ac3, ac4, ac5, ac7 are content checks across the docs this story is expected to touch
# (CLAUDE.md, agents/CLAUDE.project.md, docs/ARCHITECTURE.md, agents/reviewer.md - checked
# together since AC5 leaves the exact split "as appropriate" to the architect). ac2 combines a
# content check with a functional check of next_issue(), extracted from bin/agent-loop.sh the
# same way tests/agent-factory-ulq_test.sh does. ac6 inspects real git history on `origin` for the
# three named branches - no bd dependency, so it stays deterministic across environments.
#
# Run directly: bash tests/agent-factory-vfu3_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# ---------------------------------------------------------------------------
# shared: concatenated text of the docs this story is expected to touch (AC5: "CLAUDE.md,
# docs/ARCHITECTURE.md, agents/reviewer.md as appropriate" - agents/CLAUDE.project.md is the
# source template CLAUDE.md is synced from, see tests/agent-factory-ulq_test.sh).
# ---------------------------------------------------------------------------
DOCS_BLOB="$TMP/docs_blob.txt"
cat CLAUDE.md agents/CLAUDE.project.md docs/ARCHITECTURE.md agents/reviewer.md > "$DOCS_BLOB" 2>/dev/null

# ---------------------------------------------------------------------------
# ac1: finishing fix/<issue-id> work files a real, actionable merge-request issue - not a
# close-with-comment-only.
# ---------------------------------------------------------------------------
test_ac1_documents_filing_a_merge_request_issue() {
  grep -qE 'fix/<issue-id>' "$DOCS_BLOB" \
    || { fail "ac1: no doc mentions the fix/<issue-id> branch convention by name"; return; }
  grep -qiE 'bd create' "$DOCS_BLOB" \
    || { fail "ac1: no doc shows the bd create incantation for filing the merge-request issue"; return; }
  grep -qiE "(not|n't)[^.]{0,60}(only|just)[^.]{0,40}comment|comment[^.]{0,40}(alone|by itself)[^.]{0,40}(not|isn.t|doesn.t)[^.]{0,40}(enough|actionable|valid)" "$DOCS_BLOB" \
    || { fail "ac1: no doc explicitly rules out closing with only a comment as the way to request a merge"; return; }
  pass "ac1: docs require filing a real bd issue to request a fix/<issue-id> merge, not a comment-only close"
}

# ---------------------------------------------------------------------------
# ac2: the merge-request issue reaches the reviewer's normal queue without a story: label or a
# docs/stories/<id>.md file.
# ---------------------------------------------------------------------------

# Anchored to function-name boundaries (not line numbers), same range as
# tests/agent-factory-ulq_test.sh: everything from log() up to (not including) sync_dir(),
# covering next_issue()/is_ready() with no top-level execution, so sourcing it is side-effect-free.
FNS="$TMP/fns.sh"
sed -n '/^log()/,/^sync_dir()/{/^sync_dir()/d; p}' bin/agent-loop.sh > "$FNS"
cat bin/bdjson.sh >> "$FNS"  # bd_unwrap: agent-loop.sh sources it outside the extracted range

mkdir -p "$TMP/bin-ni"
cat > "$TMP/bin-ni/bd" <<'STUB'
#!/usr/bin/env bash
[ "$1" = ready ] && cat "$FIXTURE_READY"
exit 0
STUB
chmod +x "$TMP/bin-ni/bd"

# issue ID LABELS_CSV -> one bd-ready-shaped JSON object
storyless_issue() {
  local id=$1 labels=$2
  jq -n --arg id "$id" --arg labels "$labels" '{id:$id, assignee:"", labels:($labels|split(","))}'
}

run_next_issue() {  # run_next_issue ROLE < fixture-issues (one JSON object per line)
  local role=$1 fixture w; fixture="$TMP/ni.$RANDOM.json"; w="$TMP/ni-log.$RANDOM"; mkdir -p "$w"
  jq -s . > "$fixture"
  FIXTURE_READY="$fixture" PATH="$TMP/bin-ni:$PATH" AGENT_ID="$role" ROLE="$role" LOGDIR="$w" bash -c '
    source "$1"; next_issue' _ "$FNS"
}

test_ac2_reviewer_queue_does_not_require_a_story_label() {
  local got
  got=$(storyless_issue fix-1 "role:reviewer,stage:review" | run_next_issue reviewer)
  [ "$got" = fix-1 ] \
    || { fail "ac2 (mechanical): next_issue() did not return a role:reviewer,stage:review issue that carries no story: label - got '$got'"; return; }

  grep -qiE 'without[^.]{0,40}story:|no[^.]{0,20}story:[^.]{0,40}label|does not (need|require)[^.]{0,40}story:' "$DOCS_BLOB" \
    || { fail "ac2 (documented): no doc says a fix/<issue-id> merge-request issue needs no story: label / docs/stories file"; return; }
  pass "ac2: a storyless role:reviewer,stage:review issue is both mechanically picked up by next_issue() and documented as needing no story: label"
}

# ---------------------------------------------------------------------------
# ac3: the reviewer applies the same bar (scaled) and has the same two outcomes - merge
# fix/<issue-id> into main and push, or send it back with a blocking finding.
# ---------------------------------------------------------------------------
test_ac3_reviewer_bar_and_outcomes_documented_for_fix_branches() {
  grep -qiE 'fix/<issue-id>' agents/reviewer.md \
    || { fail "ac3: agents/reviewer.md does not mention the fix/<issue-id> path at all"; return; }
  grep -qiE 'merge[^.]{0,40}fix/<issue-id>[^.]{0,60}main|fix/<issue-id>[^.]{0,60}(into|to) main' agents/reviewer.md \
    || { fail "ac3: agents/reviewer.md does not document merging fix/<issue-id> into main"; return; }
  grep -qiE '(same|scaled)[^.]{0,80}bar|scaled to' "$DOCS_BLOB" \
    || { fail "ac3: no doc says the review bar for a fix/<issue-id> is the story bar, scaled to a small commit"; return; }
  pass "ac3: agents/reviewer.md documents merging fix/<issue-id> into main, and the review bar it applies"
}

# ---------------------------------------------------------------------------
# ac4: the merged commit + closed issue leave a documented trail, matching the story-review
# closing convention (commit message, bd comment, close).
# ---------------------------------------------------------------------------
test_ac4_closing_trail_documented_for_fix_branches() {
  grep -qiE '\[<issue-id>\][^.]{0,40}[Mm]erge[^.]{0,40}fix/<issue-id>' agents/reviewer.md \
    || { fail "ac4: agents/reviewer.md does not give a [<issue-id>] Merge fix/<issue-id>-style commit message for the fix path"; return; }
  grep -qiE 'bd comment' agents/reviewer.md \
    || { fail "ac4: agents/reviewer.md's fix/<issue-id> path does not mention bd comment (no documented handoff trail)"; return; }
  pass "ac4: agents/reviewer.md documents a commit-message + bd comment trail for a merged fix/<issue-id>, matching the story-review convention"
}

# ---------------------------------------------------------------------------
# ac5: written conventions let an agent tell, unassisted, when work qualifies for fix/<issue-id>
# versus needing a full story - and how to file the merge-request issue either way.
# ---------------------------------------------------------------------------
test_ac5_eligibility_line_is_documented() {
  grep -qiE 'new design|new tests|full story' "$DOCS_BLOB" \
    || { fail "ac5: no doc draws the line between fix/<issue-id>-eligible work and work that needs a full story"; return; }
  grep -qE 'fix/<issue-id>' "$DOCS_BLOB" \
    || { fail "ac5: fix/<issue-id> convention is not documented anywhere in CLAUDE.md / agents/CLAUDE.project.md / docs/ARCHITECTURE.md / agents/reviewer.md"; return; }
  pass "ac5: docs state both the fix/<issue-id> convention and the line between it and full-story work"
}

# ---------------------------------------------------------------------------
# ac6: the three already-stranded branches are each merged to main via the new path, or
# explicitly discarded and deleted - none silently stranded. Checked purely against real git
# history on origin (no bd dependency, so this stays deterministic across environments).
# ---------------------------------------------------------------------------
test_ac6_stranded_branches_resolved() {
  local stranded=(agent-factory-367 agent-factory-3lg agent-factory-wqd)
  local id branch tip unresolved=()
  git fetch -q origin main 2>/dev/null
  for id in "${stranded[@]}"; do
    branch="fix/$id"
    if ! git rev-parse -q --verify "origin/$branch" >/dev/null 2>&1; then
      continue  # branch gone from origin: discarded (documented reason lives in the issue, not git)
    fi
    tip=$(git rev-parse "origin/$branch")
    if git merge-base --is-ancestor "$tip" origin/main 2>/dev/null; then
      continue  # tip commit is reachable from main: merged
    fi
    unresolved+=("$branch")
  done
  [ "${#unresolved[@]}" -eq 0 ] \
    && pass "ac6: fix/agent-factory-367, fix/agent-factory-3lg and fix/agent-factory-wqd are each merged into origin/main or deleted from origin" \
    || fail "ac6: still stranded on origin, neither merged into main nor deleted: ${unresolved[*]}"
}

# ---------------------------------------------------------------------------
# ac7: a future discovered-from issue needing only a small, already-scoped fix has the same
# documented path available - the convention lives in the shared, standing conventions file
# (CLAUDE.md), not only in this story's own docs, so it outlives this story.
# ---------------------------------------------------------------------------
test_ac7_convention_lives_in_shared_conventions_file() {
  grep -qE 'fix/<issue-id>' CLAUDE.md \
    || { fail "ac7: fix/<issue-id> convention is not in CLAUDE.md (the shared, standing conventions file every agent reads) - only documenting it in a per-story file would not survive past this story"; return; }
  grep -qiE 'discovered-from' CLAUDE.md \
    || { fail "ac7: CLAUDE.md's discovered-from guidance is missing entirely"; return; }
  pass "ac7: CLAUDE.md (the standing conventions file, not a per-story doc) documents the fix/<issue-id> path alongside discovered-from, so future storyless fixes have it without reinventing anything"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
