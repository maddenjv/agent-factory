#!/usr/bin/env bash
# Acceptance tests for agent-factory-whtf: "Throttle verbosity on board".
#
# One function per acceptance criterion in docs/stories/agent-factory-whtf.md (test_acN_...).
# Written BEFORE implementation, from the story's acceptance criteria only - NOT from
# docs/design/agent-factory-whtf.md, which may not exist yet or may still be changing in
# parallel (see CLAUDE.md's qa stage:tests instructions).
#
# Today, bin/board.sh's render() unconditionally prints the "-- throttle (po/architect) --"
# header followed by throttle_section()'s one line, in every case (no throttle.json, idle:false,
# idle:true, and the malformed-file fallback) - see bin/board.sh:139-150. So AC1 and AC2 below are
# expected to fail right now: the header and body both appear even when there is nothing to
# report. AC3 (idle:true keeps showing the reason) and AC4 (a malformed file is still surfaced,
# not swallowed) are expected to already pass against today's code, since render() never suppresses
# anything yet - they're included so a future change can't silently break them while fixing AC1/AC2.
#
# Run directly: bash tests/agent-factory-whtf_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

STUB_BD_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_BD_DIR"' EXIT

# Stub `bd` covering the calls render() makes for the other sections (list/ready), so those
# sections have real, unrelated content - keeps the throttle-section assertions from being
# vacuously true against an otherwise-empty board.
cat > "$STUB_BD_DIR/bd" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then
  echo '[{"id":"issue-1","status":"in_progress","assignee":"engineer","title":"Do the thing","labels":[]}]'
  exit 0
fi
if [ "$1" = "ready" ]; then
  echo '[{"id":"issue-3","title":"Ready to go","labels":["role:qa"]}]'
  exit 0
fi
exit 1
STUBEOF
chmod +x "$STUB_BD_DIR/bd"

# Sources bin/board.sh in a throwaway DATA_DIR with the given throttle.json fixture ("MISSING"
# means no file at all), calls render(), and captures its stdout. Sets RESULT_OUT / RESULT_RC.
# board.sh is already guarded behind `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`, so sourcing it here
# does not start the infinite refresh loop.
run_render() {
  local fixture="$1" tmp out rc
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/control"
  if [ "$fixture" != "MISSING" ]; then
    printf '%s' "$fixture" > "$tmp/control/throttle.json"
  fi
  out="$(DATA_DIR="$tmp" PATH="$STUB_BD_DIR:$PATH" TERM="${TERM:-xterm}" timeout 5 bash -c '
    source bin/board.sh
    render
  ' 2>&1)"
  rc=$?
  rm -rf "$tmp"
  RESULT_OUT="$out"
  RESULT_RC=$rc
}

# --- AC1: no throttle.json at all -> no header, no body ---
test_ac1_no_throttle_file_hides_section_entirely() {
  run_render MISSING
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac1: render() did not run cleanly (rc=$RESULT_RC):
$RESULT_OUT"
    return
  fi
  local bad=0
  if echo "$RESULT_OUT" | grep -qF -- "-- throttle"; then
    fail "ac1: output still contains the '-- throttle (po/architect) --' header when throttle.json doesn't exist:
$RESULT_OUT"
    bad=1
  fi
  if echo "$RESULT_OUT" | grep -qi "no assessment yet"; then
    fail "ac1: output still contains the 'no assessment yet' body line when throttle.json doesn't exist:
$RESULT_OUT"
    bad=1
  fi
  [ "$bad" -eq 0 ] && pass "ac1: throttle section (header and body) is entirely absent when throttle.json doesn't exist"
}

# --- AC2: idle:false -> no header, no body ---
test_ac2_idle_false_hides_section_entirely() {
  run_render '{"idle":false,"reason":"plenty of room","assessed_at":"2026-09-28T00:05:00Z"}'
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac2: render() did not run cleanly (rc=$RESULT_RC):
$RESULT_OUT"
    return
  fi
  local bad=0
  if echo "$RESULT_OUT" | grep -qF -- "-- throttle"; then
    fail "ac2: output still contains the '-- throttle (po/architect) --' header for idle:false:
$RESULT_OUT"
    bad=1
  fi
  if echo "$RESULT_OUT" | grep -qF "plenty of room"; then
    fail "ac2: output still contains the recorded reason for idle:false (should be fully suppressed, not just re-worded):
$RESULT_OUT"
    bad=1
  fi
  [ "$bad" -eq 0 ] && pass "ac2: throttle section (header and body) is entirely absent when throttle.json records idle:false"
}

# --- AC3: idle:true -> header, reason, and assessed-at time all still shown ---
test_ac3_idle_true_still_shows_header_reason_and_time() {
  run_render '{"idle":true,"reason":"backlog too deep at stage:implement","assessed_at":"2026-09-28T00:00:00Z"}'
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac3: render() did not run cleanly (rc=$RESULT_RC):
$RESULT_OUT"
    return
  fi
  local ok=1
  echo "$RESULT_OUT" | grep -qF -- "-- throttle (po/architect) --" \
    || { fail "ac3: output is missing the '-- throttle (po/architect) --' header for idle:true:
$RESULT_OUT"; ok=0; }
  echo "$RESULT_OUT" | grep -qF "backlog too deep at stage:implement" \
    || { fail "ac3: output is missing the recorded reason for idle:true:
$RESULT_OUT"; ok=0; }
  echo "$RESULT_OUT" | grep -qF "2026-09-28T00:00:00Z" \
    || { fail "ac3: output is missing the recorded assessed_at time for idle:true:
$RESULT_OUT"; ok=0; }
  [ "$ok" -eq 1 ] && pass "ac3: header, reason, and assessed-at time all still appear when throttle.json records idle:true"
}

test_ac3_idle_true_header_precedes_reason() {
  run_render '{"idle":true,"reason":"quota low","assessed_at":"2026-09-28T00:00:00Z"}'
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac3 (order): render() did not run cleanly (rc=$RESULT_RC):
$RESULT_OUT"
    return
  fi
  local idx_header idx_reason
  idx_header=$(echo "$RESULT_OUT" | grep -n -- "-- throttle (po/architect) --" | head -1 | cut -d: -f1)
  idx_reason=$(echo "$RESULT_OUT" | grep -n -F "quota low" | head -1 | cut -d: -f1)
  if [ -z "$idx_header" ] || [ -z "$idx_reason" ]; then
    fail "ac3 (order): header or reason line missing entirely:
$RESULT_OUT"
    return
  fi
  if [ "$idx_header" -lt "$idx_reason" ]; then
    pass "ac3: '-- throttle (po/architect) --' header appears before the reason it introduces"
  else
    fail "ac3 (order): header does not precede the reason line (header=$idx_header reason=$idx_reason):
$RESULT_OUT"
  fi
}

# --- AC4: malformed/unreadable throttle.json -> failure still surfaced, not swallowed silently ---
test_ac4_malformed_file_is_still_surfaced() {
  run_render '{this is not valid json'
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac4: render() did not run cleanly (rc=$RESULT_RC):
$RESULT_OUT"
    return
  fi
  if echo "$RESULT_OUT" | grep -qiE 'unreadable|malformed|invalid|parse error|could not (read|parse)'; then
    pass "ac4: a malformed throttle.json still produces a visible failure indication in the output"
  else
    fail "ac4: a malformed throttle.json produced no visible failure indication at all - looks silently swallowed:
$RESULT_OUT"
  fi
}

test_ac4_malformed_file_differs_from_silent_nothing_to_report_case() {
  run_render '{this is not valid json'
  local malformed_out="$RESULT_OUT"
  run_render MISSING
  local missing_out="$RESULT_OUT"
  if [ "$malformed_out" = "$missing_out" ]; then
    fail "ac4: rendered output for a malformed throttle.json is identical to the no-file case - the
malformed-file error is being silently folded into the 'nothing to report' case instead of being
surfaced:
$malformed_out"
  else
    pass "ac4: rendered output for a malformed throttle.json differs from the silent no-file case"
  fi
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

test_ac1_no_throttle_file_hides_section_entirely
test_ac2_idle_false_hides_section_entirely
test_ac3_idle_true_still_shows_header_reason_and_time
test_ac3_idle_true_header_precedes_reason
test_ac4_malformed_file_is_still_surfaced
test_ac4_malformed_file_differs_from_silent_nothing_to_report_case
test_shellcheck_clean

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
