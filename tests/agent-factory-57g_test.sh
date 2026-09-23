#!/usr/bin/env bash
# Acceptance tests for agent-factory-57g: "Remove spend today from the board".
#
# No test framework is used elsewhere in this repo (see docs/ARCHITECTURE.md's "Test strategy")
# so these are plain shell assertions, one function per acceptance criterion in
# docs/stories/agent-factory-57g.md, following docs/design/agent-factory-57g.md's approach:
# the "-- spend today (USD) --" header and its `cat control/cost/* | awk ...` total line are
# deleted from render() in bin/board.sh, with no other section's header/order/spacing changed.
#
# Written BEFORE that change lands: today bin/board.sh's render() still prints the "spend today"
# section (bin/board.sh:57-58), so AC1 is expected to fail until it's removed. board.sh is already
# guarded behind `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`, so sourcing it here does not start the
# infinite refresh loop.
#
# Run directly: bash tests/agent-factory-57g_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

STUB_BD_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_BD_DIR"' EXIT

# Stub `bd` covering the calls render() makes: `bd list --json` (used twice: "in progress" and
# "needs-human") and `bd ready --limit 50 --json` (used for "ready"). Returns a fixed, small,
# non-empty JSON array from each so every section other than "spend today" has real content to
# assert on.
cat > "$STUB_BD_DIR/bd" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
  echo '[{"id":"issue-1","status":"in_progress","assignee":"engineer","title":"Do the thing","labels":[]},
         {"id":"issue-2","status":"open","assignee":"-","title":"Needs a human","labels":["needs-human"]}]'
  exit 0
fi
if [ "$1" = "ready" ]; then
  echo '[{"id":"issue-3","title":"Ready to go","labels":["role:qa"]}]'
  exit 0
fi
exit 1
STUBEOF
chmod +x "$STUB_BD_DIR/bd"

# Sources bin/board.sh in a throwaway DATA_DIR, calls render(), and captures its stdout.
# Sets RESULT_OUT / RESULT_RC.
run_render() {
  local tmp out rc
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/control/cost"
  # A dated, nonzero cost file - if the "spend today" line were still present it would have
  # something real to sum, making its absence from the output a meaningful assertion rather than
  # a vacuous one (an empty control/cost/ would pass even with the old code, awk on no input).
  echo "12.50" > "$tmp/control/cost/engineer.$(date +%F)"
  out="$(DATA_DIR="$tmp" PATH="$STUB_BD_DIR:$PATH" TERM="${TERM:-xterm}" timeout 5 bash -c '
    source bin/board.sh
    render
  ' 2>&1)"
  rc=$?
  rm -rf "$tmp"
  RESULT_OUT="$out"
  RESULT_RC=$rc
}

# --- AC1: no "spend today" header and no dollar-total line derived from control/cost/ ---
test_ac1_no_spend_today_header() {
  run_render
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac1: render() did not run cleanly (rc=$RESULT_RC):
$RESULT_OUT"
    return
  fi
  if echo "$RESULT_OUT" | grep -qi "spend today"; then
    fail "ac1: output still contains a 'spend today' section header:
$RESULT_OUT"
  else
    pass "ac1: output contains no 'spend today' section header"
  fi
}

test_ac1_no_dollar_total_line() {
  run_render
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac1 (dollar total): render() did not run cleanly (rc=$RESULT_RC):
$RESULT_OUT"
    return
  fi
  # The old code's awk total for a single 12.50 entry is exactly "12.50" printed alone on its own
  # line - that's the dollar-total line this AC says must be gone.
  if echo "$RESULT_OUT" | grep -qxF "12.50"; then
    fail "ac1: output still contains a dollar-total line derived from control/cost/:
$RESULT_OUT"
  else
    pass "ac1: output contains no dollar-total line derived from control/cost/"
  fi
}

# --- AC2: the other sections still appear, same order/format, with the gap closed ---
test_ac2_remaining_sections_present_in_order() {
  run_render
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac2: render() did not run cleanly (rc=$RESULT_RC):
$RESULT_OUT"
    return
  fi
  local idx_progress idx_ready idx_human idx_alerts
  idx_progress=$(echo "$RESULT_OUT" | grep -n -- "-- in progress --" | head -1 | cut -d: -f1)
  idx_ready=$(echo "$RESULT_OUT" | grep -n -- "-- ready --" | head -1 | cut -d: -f1)
  idx_human=$(echo "$RESULT_OUT" | grep -n -- "-- needs-human" | head -1 | cut -d: -f1)
  idx_alerts=$(echo "$RESULT_OUT" | grep -n -- "-- recent alerts --" | head -1 | cut -d: -f1)

  if [ -z "$idx_progress" ] || [ -z "$idx_ready" ] || [ -z "$idx_human" ] || [ -z "$idx_alerts" ]; then
    fail "ac2: one or more of the expected section headers is missing:
$RESULT_OUT"
    return
  fi
  if [ "$idx_progress" -lt "$idx_ready" ] && [ "$idx_ready" -lt "$idx_human" ] && [ "$idx_human" -lt "$idx_alerts" ]; then
    pass "ac2: 'in progress', 'ready', 'needs-human', 'recent alerts' headers all present, in order"
  else
    fail "ac2: section headers are present but out of order (progress=$idx_progress ready=$idx_ready human=$idx_human alerts=$idx_alerts):
$RESULT_OUT"
  fi
}

test_ac2_no_leftover_blank_section_between_human_and_alerts() {
  run_render
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac2 (gap closed): render() did not run cleanly (rc=$RESULT_RC):
$RESULT_OUT"
    return
  fi
  local idx_human idx_alerts between
  idx_human=$(echo "$RESULT_OUT" | grep -n -- "-- needs-human" | head -1 | cut -d: -f1)
  idx_alerts=$(echo "$RESULT_OUT" | grep -n -- "-- recent alerts --" | head -1 | cut -d: -f1)
  if [ -z "$idx_human" ] || [ -z "$idx_alerts" ]; then
    fail "ac2 (gap closed): 'needs-human' or 'recent alerts' header missing:
$RESULT_OUT"
    return
  fi
  # Everything strictly between the needs-human header line and the recent-alerts header line:
  # this stub's needs-human list has one matching issue (issue-2), so the line right after the
  # header is that issue's row, then the blank `echo` immediately preceding the "recent alerts"
  # header - i.e. exactly one blank line, no leftover "spend today" header or total in between.
  between=$(echo "$RESULT_OUT" | sed -n "$((idx_human + 1)),$((idx_alerts - 1))p")
  local blank_lines non_blank_non_data
  blank_lines=$(echo "$between" | grep -c '^$')
  if echo "$between" | grep -qi "spend today"; then
    fail "ac2: leftover 'spend today' content still sits between 'needs-human' and 'recent alerts':
$between"
  elif [ "$blank_lines" -gt 1 ]; then
    fail "ac2: more than one blank line between 'needs-human' and 'recent alerts' (leftover gap):
[$between]"
  else
    pass "ac2: 'recent alerts' immediately follows 'needs-human' output with no leftover blank section"
  fi
}

test_ac2_ready_and_in_progress_content_unaffected() {
  run_render
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac2 (content unaffected): render() did not run cleanly (rc=$RESULT_RC):
$RESULT_OUT"
    return
  fi
  local ok=1
  echo "$RESULT_OUT" | grep -qF "issue-1" || { fail "ac2: 'in progress' row (issue-1) missing from output:
$RESULT_OUT"; ok=0; }
  echo "$RESULT_OUT" | grep -qF "issue-3" || { fail "ac2: 'ready' row (issue-3) missing from output:
$RESULT_OUT"; ok=0; }
  echo "$RESULT_OUT" | grep -qF "issue-2" || { fail "ac2: 'needs-human' row (issue-2) missing from output:
$RESULT_OUT"; ok=0; }
  [ "$ok" = 1 ] && pass "ac2: 'in progress'/'ready'/'needs-human' still show their rows, unaffected"
}

test_shellcheck_clean() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    fail "shellcheck: not available in this environment - could not verify bin/board.sh is clean"
    return
  fi
  local out
  if out="$(shellcheck bin/board.sh 2>&1)"; then
    pass "shellcheck bin/board.sh is clean"
  else
    fail "shellcheck bin/board.sh reported issues:
$out"
  fi
}

test_ac1_no_spend_today_header
test_ac1_no_dollar_total_line
test_ac2_remaining_sections_present_in_order
test_ac2_no_leftover_blank_section_between_human_and_alerts
test_ac2_ready_and_in_progress_content_unaffected
test_shellcheck_clean

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
