#!/usr/bin/env bash
# Acceptance tests for agent-factory-2do: "Expire recent alerts".
#
# No test framework is used elsewhere in this repo (see docs/ARCHITECTURE.md's "Test strategy")
# so these are plain shell assertions, one function per acceptance criterion in
# docs/stories/agent-factory-2do.md, following docs/design/agent-factory-2do.md's approach:
# bin/board.sh is restructured into a `recent_alerts` / `still_needs_human` pair of functions
# guarded behind `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` so it can be sourced without starting the
# infinite refresh loop.
#
# Written BEFORE that refactor exists: today bin/board.sh is still one flat `while :; do ... done`
# loop with no guard, so `source bin/board.sh` blocks forever. Every test here sources the script
# under `timeout`, in a subshell, with a stub `bd` on PATH so no live Beads state is touched. A
# `timeout`-triggered failure (exit 124) is expected and correct until the design's refactor
# lands - it is failing for the right reason (the guard/functions don't exist yet), not because of
# a typo in these tests.
#
# Run directly: bash tests/agent-factory-2do_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

STUB_BD_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_BD_DIR"' EXIT

# Stub `bd` covering only `bd show <id> --json`, the sole bd call still_needs_human should make
# per docs/design/agent-factory-2do.md. Anything else (bd list/ready, used by the rest of
# board.sh's render) exits non-zero, same as a real bd with no reachable DB - board.sh must not
# depend on those succeeding for recent_alerts() to work.
cat > "$STUB_BD_DIR/bd" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "show" ]; then
  case "$2" in
    issue-still-flagged) echo '{"id":"issue-still-flagged","status":"open","labels":["needs-human"]}' ;;
    issue-label-removed) echo '{"id":"issue-label-removed","status":"open","labels":["some-other-label"]}' ;;
    issue-closed)        echo '{"id":"issue-closed","status":"closed","labels":["needs-human"]}' ;;
    issue-as-array)      echo '[{"id":"issue-as-array","status":"open","labels":["needs-human"]}]' ;;
    issue-missing)       exit 1 ;;
    *)                   exit 1 ;;
  esac
  exit 0
fi
exit 1
STUBEOF
chmod +x "$STUB_BD_DIR/bd"

# Sources bin/board.sh (guarded per the design, so it must NOT start the refresh loop) in a
# throwaway DATA_DIR containing the given alerts.log content, then calls recent_alerts and
# captures its stdout. Sets RESULT_OUT / RESULT_RC. A 5s timeout stands in for "the loop guard
# doesn't exist yet" as well as any genuine hang in recent_alerts itself.
run_recent_alerts() {
  local content="$1" write_file="${2:-yes}"
  local tmp out rc
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/control"
  if [ "$write_file" = "yes" ]; then
    printf '%s' "$content" > "$tmp/control/alerts.log"
  fi
  out="$(DATA_DIR="$tmp" PATH="$STUB_BD_DIR:$PATH" timeout 5 bash -c '
    source bin/board.sh
    if ! declare -f recent_alerts >/dev/null; then
      echo "__RECENT_ALERTS_NOT_DEFINED__" >&2
      exit 97
    fi
    recent_alerts
  ' 2>&1)"
  rc=$?
  rm -rf "$tmp"
  RESULT_OUT="$out"
  RESULT_RC=$rc
}

# Fails with a message that makes clear this is "not implemented yet" (timeout / missing
# function), as opposed to a real assertion mismatch, whenever run_recent_alerts couldn't
# meaningfully exercise the behaviour.
not_implemented_reason() {
  if [ "$RESULT_RC" -eq 124 ]; then
    echo "bin/board.sh has no loop guard yet (source blocked until killed by timeout) - recent_alerts()/still_needs_human() from docs/design/agent-factory-2do.md are not implemented"
  elif [ "$RESULT_RC" -eq 97 ]; then
    echo "recent_alerts() is not defined by bin/board.sh yet"
  else
    echo "unexpected: rc=$RESULT_RC output=$RESULT_OUT"
  fi
}

now_ts() { date -u -d "$1" +%FT%TZ; }

# --- AC1: needs-human alert disappears once the label is removed (including by closing) ---
test_ac1_drops_when_label_removed() {
  local line="2026-09-23T09:00:00Z [engineer] issue-label-removed flagged needs-human by the agent"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac1 (label removed): $(not_implemented_reason)"
    return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    fail "ac1 (label removed): alert line still present after needs-human label was removed:
$RESULT_OUT"
  else
    pass "ac1: needs-human alert for a since-unlabelled issue is dropped"
  fi
}

test_ac1_drops_when_issue_closed() {
  local line="2026-09-23T09:00:02Z [engineer] issue-closed not completed after 3 attempts; labelled needs-human"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac1 (issue closed): $(not_implemented_reason)"
    return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    fail "ac1 (issue closed): alert line still present after the issue was closed:
$RESULT_OUT"
  else
    pass "ac1: needs-human alert for a since-closed issue is dropped"
  fi
}

# --- AC2: needs-human alert keeps appearing while the label is still present ---
test_ac2_kept_while_label_present() {
  local line="2026-09-23T09:00:00Z [engineer] issue-still-flagged flagged needs-human by the agent"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac2: $(not_implemented_reason)"
    return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    pass "ac2: needs-human alert for a still-labelled issue keeps appearing"
  else
    fail "ac2: alert line for a still-labelled needs-human issue was dropped (should be kept):
$RESULT_OUT"
  fi
}

# still_needs_human must handle both shapes `bd show --json` returns (bare object or a
# one-element array), same as agent-loop.sh's existing show_json/has_label idiom.
test_ac2_handles_array_shaped_bd_output() {
  local line="2026-09-23T09:00:00Z [engineer] issue-as-array flagged needs-human by the agent"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac2 (array-shaped bd output): $(not_implemented_reason)"
    return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    pass "ac2: still_needs_human handles an array-shaped 'bd show --json' response"
  else
    fail "ac2: alert line dropped when 'bd show --json' returned an array-wrapped object (should be kept):
$RESULT_OUT"
  fi
}

# --- AC3: usage-limit alert disappears once its wait window has elapsed ---
test_ac3_drops_after_wait_elapsed() {
  local ts line
  ts="$(now_ts '-100 seconds')"
  line="$ts [engineer] usage limit hit (5-hour limit reached); waiting 10s before retrying"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac3: $(not_implemented_reason)"
    return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    fail "ac3: usage-limit alert still present 90s past its 10s wait window (should be dropped):
$RESULT_OUT"
  else
    pass "ac3: usage-limit alert is dropped once now >= alert timestamp + wait duration"
  fi
}

# --- AC4: usage-limit alert keeps appearing while the wait window hasn't elapsed ---
test_ac4_kept_while_waiting() {
  local ts line
  ts="$(now_ts 'now')"
  line="$ts [engineer] issue-x: usage limit hit (5-hour limit reached); waiting 100000s to retry"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac4: $(not_implemented_reason)"
    return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    pass "ac4: usage-limit alert keeps appearing while now < alert timestamp + wait duration"
  else
    fail "ac4: usage-limit alert dropped even though its wait window (100000s) hasn't elapsed:
$RESULT_OUT"
  fi
}

# --- AC5: alerts other than needs-human/usage-limit are unaffected, byte-for-byte ---
test_ac5_other_alert_types_unaffected() {
  local lines=(
    "2026-09-23T08:00:00Z [engineer] circuit breaker: git sync failing; stopping"
    "2026-09-23T08:00:01Z [engineer] circuit breaker: 5 consecutive failures; stopping engineer"
    "2026-09-23T08:00:02Z [engineer] daily budget reached (42.00 USD); pausing 3600s"
    "2026-09-23T08:00:03Z [engineer] cannot clone git@example.com:org/repo.git"
    "2026-09-23T08:00:04Z [engineer] preflight: bd cannot reach the Beads database"
    "2026-09-23T08:00:05Z [engineer] preflight: claude failed to run (check API key/token): boom"
  )
  local joined
  # printf -v (not "$(...)") so the trailing newline after the last line survives - command
  # substitution would strip it, which would make the last line lack a trailing newline and get
  # silently skipped by recent_alerts' `while read` loop (a real risk if alerts.log's final write
  # were ever incomplete, so worth getting right here too).
  printf -v joined '%s\n' "${lines[@]}"
  run_recent_alerts "$joined"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac5: $(not_implemented_reason)"
    return
  fi
  local ok=1 l
  for l in "${lines[@]}"; do
    echo "$RESULT_OUT" | grep -qF "$l" || { fail "ac5: unaffected alert line missing/altered: $l
Got:
$RESULT_OUT"; ok=0; }
  done
  [ "$ok" = 1 ] && pass "ac5: circuit-breaker/daily-budget/clone/preflight alert lines are unaffected, byte-for-byte"
}

# --- Fail-open guarantees the design calls out explicitly: any lookup ambiguity must keep
#     showing the alert, never silently drop it. Not tied to a single AC number, but load-bearing
#     for AC1/AC2 not becoming "drop on any doubt". ---
test_failopen_bd_lookup_failure_keeps_alert() {
  local line="2026-09-23T09:00:00Z [engineer] issue-missing flagged needs-human by the agent"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "failopen (bd lookup failure): $(not_implemented_reason)"
    return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    pass "failopen: alert is kept when 'bd show' fails/issue can't be found (fail open, not silently dropped)"
  else
    fail "failopen: alert was dropped when the bd lookup failed - should fail open and keep showing it:
$RESULT_OUT"
  fi
}

test_failopen_malformed_line_kept() {
  local line="this line does not match the timestamp [agent] format at all"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "failopen (malformed line): $(not_implemented_reason)"
    return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    pass "failopen: a line that doesn't match alert()'s format is shown unchanged, not dropped"
  else
    fail "failopen: malformed/unparseable line was dropped instead of shown as-is:
$RESULT_OUT"
  fi
}

# --- Regression guard: matches today's `tail ... 2>/dev/null` behaviour of printing nothing and
#     not erroring when alerts.log is missing or empty. ---
test_missing_or_empty_alerts_log() {
  run_recent_alerts "" "no"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "missing alerts.log: $(not_implemented_reason)"
    return
  fi
  if [ -z "$RESULT_OUT" ]; then
    pass "recent_alerts prints nothing and doesn't error when alerts.log is missing"
  else
    fail "recent_alerts should print nothing for a missing alerts.log, got:
$RESULT_OUT"
  fi

  run_recent_alerts "" "yes"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "empty alerts.log: $(not_implemented_reason)"
    return
  fi
  if [ -z "$RESULT_OUT" ]; then
    pass "recent_alerts prints nothing and doesn't error when alerts.log is empty"
  else
    fail "recent_alerts should print nothing for an empty alerts.log, got:
$RESULT_OUT"
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

test_ac1_drops_when_label_removed
test_ac1_drops_when_issue_closed
test_ac2_kept_while_label_present
test_ac2_handles_array_shaped_bd_output
test_ac3_drops_after_wait_elapsed
test_ac4_kept_while_waiting
test_ac5_other_alert_types_unaffected
test_failopen_bd_lookup_failure_keeps_alert
test_failopen_malformed_line_kept
test_missing_or_empty_alerts_log
test_shellcheck_clean

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
