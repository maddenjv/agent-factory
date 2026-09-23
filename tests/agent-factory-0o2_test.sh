#!/usr/bin/env bash
# Acceptance tests for agent-factory-0o2: "Board accuracy".
#
# No test framework is used elsewhere in this repo (see docs/ARCHITECTURE.md's "Test strategy")
# so these are plain shell assertions, one function per acceptance criterion in
# docs/stories/agent-factory-0o2.md, following docs/design/agent-factory-0o2.md's approach:
# bin/board.sh gains three functions - ready_section, needs_human_section, blocked_section -
# each callable standalone after `source bin/board.sh` (the existing
# `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` guard from agent-factory-2do already keeps the render
# loop from starting on source).
#
# Written BEFORE that refactor exists: today bin/board.sh has no ready_section/
# needs_human_section/blocked_section functions at all - render() inlines the `bd ready`/
# `bd list` + jq pipelines directly. Every test here sources the script with a stub `bd` on
# PATH (so no live Beads state is touched) and asserts the named function is both defined and
# produces the right output. A missing-function result (rc 97, detected before the real
# assertion) is expected and correct until the design's functions land - it is failing for the
# right reason, not because of a typo in these tests.
#
# Run directly: bash tests/agent-factory-0o2_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

STUB_BD_DIR="$(mktemp -d)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_BD_DIR" "$FIXTURE_DIR"' EXIT

# Stub `bd` covering only the two calls docs/design/agent-factory-0o2.md's ready_section/
# needs_human_section/blocked_section rely on: `bd ready --limit 50 --json` and
# `bd list --json`. Content is read from files pointed to by READY_JSON_FILE / LIST_JSON_FILE so
# each test can supply its own fixture. Anything else exits non-zero, same as a real bd with no
# reachable DB.
cat > "$STUB_BD_DIR/bd" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "ready" ]; then
  cat "${READY_JSON_FILE:?READY_JSON_FILE not set}"
  exit 0
fi
if [ "$1" = "list" ]; then
  cat "${LIST_JSON_FILE:?LIST_JSON_FILE not set}"
  exit 0
fi
exit 1
STUBEOF
chmod +x "$STUB_BD_DIR/bd"

# --- Shared base fixture, covering AC1, AC2, AC3, AC5, AC6, and the blocks-vs-discovered-from
#     distinction in a single render. See the big comment block below for the reasoning behind
#     each issue.
#
# list.json (bd list --json, the full open+closed issue set):
#   nh-solo            - open, needs-human, no deps                          (AC1)
#   nh-blocker         - open, needs-human, no deps                         (AC2/AC3 blocker)
#   blocked-by-nh      - open, no label, blocks-depends on nh-blocker       (AC2/AC3 dependent)
#   plain-blocker      - open, no label, no deps                            (AC5 blocker)
#   blocked-by-plain   - open, no label, blocks-depends on plain-blocker    (AC5 dependent)
#   closed-nh          - CLOSED, needs-human, no deps                       (AC6)
#   dep-on-closed-nh   - open, no label, blocks-depends on closed-nh        (AC6, blocker closed)
#   nh-discovered      - open, needs-human, no deps               (discovered-from blocker)
#   discovered-from-dep- open, no label, discovered-from-depends on nh-discovered (not "blocks")
#
# ready.json (bd ready --json): bd's own dependency-driven blocking logic is out of scope for
# this story (see design's "Out of scope"), so this fixture is what a real `bd ready` would
# already return given the deps above - closed issues never appear, an issue with an open
# "blocks" dependency is excluded, an issue whose only dependency is "discovered-from" (not
# blocking) or points at a closed issue is included:
#   included: nh-solo, nh-blocker, plain-blocker, dep-on-closed-nh, nh-discovered,
#             discovered-from-dep
#   excluded: blocked-by-nh, blocked-by-plain (open "blocks" dep), closed-nh (closed)
cat > "$FIXTURE_DIR/list.json" <<'EOF'
[
  {"id":"nh-solo","title":"AC1 needs-human, unblocked","status":"open",
   "labels":["needs-human"],"dependencies":[]},
  {"id":"nh-blocker","title":"AC2/3 blocker","status":"open",
   "labels":["needs-human"],"dependencies":[]},
  {"id":"blocked-by-nh","title":"AC2/3 dependent","status":"open","labels":[],
   "dependencies":[{"issue_id":"blocked-by-nh","depends_on_id":"nh-blocker","type":"blocks"}]},
  {"id":"plain-blocker","title":"AC5 blocker (no label)","status":"open",
   "labels":[],"dependencies":[]},
  {"id":"blocked-by-plain","title":"AC5 dependent","status":"open","labels":[],
   "dependencies":[{"issue_id":"blocked-by-plain","depends_on_id":"plain-blocker","type":"blocks"}]},
  {"id":"closed-nh","title":"AC6 closed needs-human","status":"closed",
   "labels":["needs-human"],"dependencies":[]},
  {"id":"dep-on-closed-nh","title":"AC6 dependent on closed blocker","status":"open","labels":[],
   "dependencies":[{"issue_id":"dep-on-closed-nh","depends_on_id":"closed-nh","type":"blocks"}]},
  {"id":"nh-discovered","title":"discovered-from blocker","status":"open",
   "labels":["needs-human"],"dependencies":[]},
  {"id":"discovered-from-dep","title":"discovered-from dependent (not a block)","status":"open",
   "labels":[],
   "dependencies":[{"issue_id":"discovered-from-dep","depends_on_id":"nh-discovered","type":"discovered-from"}]}
]
EOF

cat > "$FIXTURE_DIR/ready.json" <<'EOF'
[
  {"id":"nh-solo","title":"AC1 needs-human, unblocked","labels":["needs-human"]},
  {"id":"nh-blocker","title":"AC2/3 blocker","labels":["needs-human"]},
  {"id":"plain-blocker","title":"AC5 blocker (no label)","labels":[]},
  {"id":"dep-on-closed-nh","title":"AC6 dependent on closed blocker","labels":[]},
  {"id":"nh-discovered","title":"discovered-from blocker","labels":["needs-human"]},
  {"id":"discovered-from-dep","title":"discovered-from dependent (not a block)","labels":[]}
]
EOF

# AC4 fixtures: "before" state (nh-blocker4/blocked-by-nh4, matching the base AC2/3 shape) plus
# two "after" variants - label removed from the blocker (still open), and the blocker closed.
cat > "$FIXTURE_DIR/list-ac4-label-removed.json" <<'EOF'
[
  {"id":"nh-blocker4","title":"AC4 blocker, label removed","status":"open","labels":[],
   "dependencies":[]},
  {"id":"blocked-by-nh4","title":"AC4 dependent","status":"open","labels":[],
   "dependencies":[{"issue_id":"blocked-by-nh4","depends_on_id":"nh-blocker4","type":"blocks"}]}
]
EOF
# Blocker is still open (just unlabelled): bd's real dependency logic still excludes the
# dependent from ready (unrelated to the label) - only nh-blocker4 itself is ready.
cat > "$FIXTURE_DIR/ready-ac4-label-removed.json" <<'EOF'
[
  {"id":"nh-blocker4","title":"AC4 blocker, label removed","labels":[]}
]
EOF

cat > "$FIXTURE_DIR/list-ac4-closed.json" <<'EOF'
[
  {"id":"nh-blocker4","title":"AC4 blocker, closed","status":"closed","labels":["needs-human"],
   "dependencies":[]},
  {"id":"blocked-by-nh4","title":"AC4 dependent","status":"open","labels":[],
   "dependencies":[{"issue_id":"blocked-by-nh4","depends_on_id":"nh-blocker4","type":"blocks"}]}
]
EOF
# Blocker is now closed: bd's real dependency logic resolves it, so the dependent is ready again.
cat > "$FIXTURE_DIR/ready-ac4-closed.json" <<'EOF'
[
  {"id":"blocked-by-nh4","title":"AC4 dependent","labels":[]}
]
EOF

# Sources bin/board.sh with the given list/ready fixtures and stub bd on PATH, then calls the
# named function ($1: ready_section | needs_human_section | blocked_section) and captures its
# stdout. Sets RESULT_OUT / RESULT_RC. A short timeout guards against any accidental hang (e.g.
# if a future change reintroduces an unguarded render loop).
run_section() {
  local fn="$1" list_file="$2" ready_file="$3"
  local out rc
  out="$(READY_JSON_FILE="$ready_file" LIST_JSON_FILE="$list_file" PATH="$STUB_BD_DIR:$PATH" \
    timeout 5 bash -c '
      source bin/board.sh
      if ! declare -f "'"$fn"'" >/dev/null; then
        echo "__FUNCTION_NOT_DEFINED__" >&2
        exit 97
      fi
      '"$fn"'
    ' 2>&1)"
  rc=$?
  RESULT_OUT="$out"
  RESULT_RC=$rc
}

not_implemented_reason() {
  local fn="$1"
  if [ "$RESULT_RC" -eq 97 ]; then
    echo "$fn() is not defined by bin/board.sh yet"
  elif [ "$RESULT_RC" -eq 124 ]; then
    echo "sourcing bin/board.sh timed out (unexpected - the render-loop guard should prevent this)"
  else
    echo "unexpected: rc=$RESULT_RC output=$RESULT_OUT"
  fi
}

assert_present() {
  local fn="$1" id="$2"
  if echo "$RESULT_OUT" | grep -q "^$id[[:space:]]"; then
    return 0
  fi
  fail "$fn: expected '$id' present, got:
$RESULT_OUT"
  return 1
}

assert_absent() {
  local fn="$1" id="$2"
  if echo "$RESULT_OUT" | grep -q "^$id[[:space:]]"; then
    fail "$fn: expected '$id' absent, got:
$RESULT_OUT"
    return 1
  fi
  return 0
}

# --- AC1: an open issue carrying needs-human does not appear in ready_section, only in
#     needs_human_section ---
test_ac1_needs_human_self_labelled_excluded_from_ready() {
  run_section ready_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac1: $(not_implemented_reason ready_section)"
    return
  fi
  local ok=1
  assert_absent ready_section nh-solo || ok=0
  assert_absent ready_section nh-blocker || ok=0
  assert_absent ready_section nh-discovered || ok=0
  [ "$ok" = 1 ] && pass "ac1: needs-human-labelled issues (present in raw 'bd ready' output) are excluded from ready_section"
}

test_ac1_needs_human_self_labelled_present_in_needs_human_section() {
  run_section needs_human_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac1 (needs_human_section): $(not_implemented_reason needs_human_section)"
    return
  fi
  local ok=1
  assert_present needs_human_section nh-solo || ok=0
  assert_present needs_human_section nh-blocker || ok=0
  assert_present needs_human_section nh-discovered || ok=0
  [ "$ok" = 1 ] && pass "ac1: needs-human-labelled issues appear in needs_human_section"
}

# --- AC2: an issue with an open unresolved dependency on a needs-human issue is excluded from
#     ready (already true via bd ready's own logic - blocked-by-nh is absent from ready.json) ---
test_ac2_dependent_on_needs_human_excluded_from_ready() {
  run_section ready_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac2: $(not_implemented_reason ready_section)"
    return
  fi
  assert_absent ready_section blocked-by-nh && \
    pass "ac2: issue blocked by an open needs-human issue is excluded from ready_section"
}

# --- AC3: that same dependent issue appears in the new blocked_section, naming its blocker ---
test_ac3_dependent_on_needs_human_appears_in_blocked_with_blocker_named() {
  run_section blocked_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac3: $(not_implemented_reason blocked_section)"
    return
  fi
  local line
  line="$(echo "$RESULT_OUT" | grep "^blocked-by-nh[[:space:]]" || true)"
  if [ -z "$line" ]; then
    fail "ac3: 'blocked-by-nh' missing from blocked_section, got:
$RESULT_OUT"
    return
  fi
  if echo "$line" | grep -q "nh-blocker"; then
    pass "ac3: blocked_section lists 'blocked-by-nh', naming 'nh-blocker' as what it's waiting on"
  else
    fail "ac3: blocked_section row for 'blocked-by-nh' doesn't name its blocker 'nh-blocker':
$line"
  fi
}

test_ac3_needs_human_dependent_not_in_needs_human_section() {
  run_section needs_human_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac3 (needs_human_section): $(not_implemented_reason needs_human_section)"
    return
  fi
  assert_absent needs_human_section blocked-by-nh && \
    pass "ac3: dependent issue (not itself needs-human labelled) does not appear in needs_human_section"
}

# --- AC4: once the blocking issue's needs-human label is removed (still open), the dependent
#     drops out of blocked_section (no longer a needs-human block, matches AC5's scope) ---
test_ac4_label_removed_drops_out_of_blocked() {
  run_section blocked_section "$FIXTURE_DIR/list-ac4-label-removed.json" "$FIXTURE_DIR/ready-ac4-label-removed.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac4 (label removed): $(not_implemented_reason blocked_section)"
    return
  fi
  assert_absent blocked_section blocked-by-nh4 && \
    pass "ac4: once the blocker's needs-human label is removed, the dependent no longer appears in blocked_section"
}

# --- AC4: once the blocking issue is closed, the dependent drops out of blocked_section AND
#     reappears in ready (it has no other open blockers) ---
test_ac4_blocker_closed_drops_out_of_blocked() {
  run_section blocked_section "$FIXTURE_DIR/list-ac4-closed.json" "$FIXTURE_DIR/ready-ac4-closed.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac4 (blocker closed, blocked_section): $(not_implemented_reason blocked_section)"
    return
  fi
  assert_absent blocked_section blocked-by-nh4 && \
    pass "ac4: once the blocker is closed, the dependent no longer appears in blocked_section"
}

test_ac4_blocker_closed_reappears_in_ready() {
  run_section ready_section "$FIXTURE_DIR/list-ac4-closed.json" "$FIXTURE_DIR/ready-ac4-closed.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac4 (blocker closed, ready_section): $(not_implemented_reason ready_section)"
    return
  fi
  assert_present ready_section blocked-by-nh4 && \
    pass "ac4: once the blocker is closed (and no other open blockers remain), the dependent reappears in ready_section"
}

# --- AC5: a dependency on a NON-needs-human-labelled issue is excluded from ready (existing
#     behavior) but must NOT appear in the new blocked_section (scoped to needs-human blocks) ---
test_ac5_plain_dependency_excluded_from_ready_and_blocked() {
  run_section ready_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac5 (ready_section): $(not_implemented_reason ready_section)"
    return
  fi
  local ok=1
  assert_absent ready_section blocked-by-plain || ok=0
  [ "$ok" = 1 ] && pass "ac5: issue blocked by a non-needs-human issue stays excluded from ready_section"

  run_section blocked_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac5 (blocked_section): $(not_implemented_reason blocked_section)"
    return
  fi
  assert_absent blocked_section blocked-by-plain && \
    pass "ac5: issue blocked by a non-needs-human issue does not appear in blocked_section"
}

# --- AC6: closed issues never appear in ready, needs-human, or blocked, regardless of label ---
test_ac6_closed_issue_absent_everywhere() {
  local ok=1

  run_section ready_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac6 (ready_section): $(not_implemented_reason ready_section)"
    return
  fi
  assert_absent ready_section closed-nh || ok=0

  run_section needs_human_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac6 (needs_human_section): $(not_implemented_reason needs_human_section)"
    return
  fi
  assert_absent needs_human_section closed-nh || ok=0

  run_section blocked_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac6 (blocked_section): $(not_implemented_reason blocked_section)"
    return
  fi
  assert_absent blocked_section closed-nh || ok=0

  [ "$ok" = 1 ] && pass "ac6: a closed needs-human issue never appears in ready_section, needs_human_section, or blocked_section"
}

test_ac6_dependency_on_closed_needs_human_not_a_block() {
  run_section blocked_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac6 (dep on closed blocker): $(not_implemented_reason blocked_section)"
    return
  fi
  assert_absent blocked_section dep-on-closed-nh && \
    pass "ac6: a dependency on a CLOSED needs-human issue is not treated as a needs-human block"

  run_section ready_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac6 (dep on closed blocker, ready): $(not_implemented_reason ready_section)"
    return
  fi
  assert_present ready_section dep-on-closed-nh && \
    pass "ac6: an issue whose only blocker is now closed is ready (matches bd ready's real behavior)"
}

# --- Out of scope guard: a "discovered-from" dependency on a needs-human issue is informational,
#     not a block - it must not put the issue in blocked_section, and the issue (having no own
#     needs-human label, and no open "blocks" dependency) belongs in ready ---
test_discovered_from_is_not_a_block() {
  run_section blocked_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "discovered-from: $(not_implemented_reason blocked_section)"
    return
  fi
  assert_absent blocked_section discovered-from-dep && \
    pass "discovered-from: a 'discovered-from' dependency on a needs-human issue does not appear in blocked_section"

  run_section ready_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "discovered-from (ready): $(not_implemented_reason ready_section)"
    return
  fi
  assert_present ready_section discovered-from-dep && \
    pass "discovered-from: the dependent issue (present in raw 'bd ready' output, no own needs-human label) stays in ready_section"
}

# --- Regression guard: an issue with neither a needs-human label nor any needs-human-blocked
#     dependency renders normally in ready_section (unaffected by the new filtering) ---
test_plain_ready_issue_unaffected() {
  run_section ready_section "$FIXTURE_DIR/list.json" "$FIXTURE_DIR/ready.json"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "plain ready issue: $(not_implemented_reason ready_section)"
    return
  fi
  assert_present ready_section plain-blocker && \
    pass "regression: a plain issue with no needs-human involvement still appears in ready_section"
}

test_ac1_needs_human_self_labelled_excluded_from_ready
test_ac1_needs_human_self_labelled_present_in_needs_human_section
test_ac2_dependent_on_needs_human_excluded_from_ready
test_ac3_dependent_on_needs_human_appears_in_blocked_with_blocker_named
test_ac3_needs_human_dependent_not_in_needs_human_section
test_ac4_label_removed_drops_out_of_blocked
test_ac4_blocker_closed_drops_out_of_blocked
test_ac4_blocker_closed_reappears_in_ready
test_ac5_plain_dependency_excluded_from_ready_and_blocked
test_ac6_closed_issue_absent_everywhere
test_ac6_dependency_on_closed_needs_human_not_a_block
test_discovered_from_is_not_a_block
test_plain_ready_issue_unaffected

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
