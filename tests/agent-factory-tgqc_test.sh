#!/usr/bin/env bash
# Acceptance tests for agent-factory-tgqc: one-line alerts, and a cause on "not completed" alerts.
# One function per acceptance criterion in docs/stories/agent-factory-tgqc.md (test_acN_...).
# Each test runs the real bin/agent-loop.sh against stub `claude`, `bd`, `sleep` and `curl` on PATH
# (same harness style as tests/agent-factory-stg_test.sh).
#
# AC1-AC4 (alert() itself) are driven through the startup preflight alert
#   "preflight: harness failed to run (check auth): <harness output>"
# which embeds arbitrary multi-line harness output: the stub `claude` fails the preflight call with
# PREFLIGHT_OUT (printf %b-expanded, so \n, \r are real line breaks) and the loop exits.
# AC5-AC8 (record_failure) run a full session with MAX_ATTEMPTS_PER_ISSUE=1 (cap reached on the
# first failure) or 3 (cap not reached), the stub claude ending with a chosen exit status / stderr /
# stream-json result and never closing the issue (stub `bd show` keeps it in_progress).
# Run directly: bash tests/agent-factory-tgqc_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

cat > "$TMP/stubs/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"Reply with the single word OK"* ]]; then
  printf '%b' "${PREFLIGHT_OUT:-OK}"; exit "${PREFLIGHT_EXIT:-1}"
fi
echo x >> "$W/claude_runs"
[ -n "${STDERR_TEXT:-}" ] && printf '%b\n' "$STDERR_TEXT" >&2
[ -n "${STDOUT_TEXT:-}" ] && printf '%b\n' "$STDOUT_TEXT"
exit "${CLAUDE_EXIT:-0}"
STUB

cat > "$TMP/stubs/sleep" <<'STUB'
#!/usr/bin/env bash
touch "$W/data/control/STOP"
exit 0
STUB

cat > "$TMP/stubs/curl" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  [ "$prev" = "-d" ] && printf '%s' "$a" > "$W/notify"
  prev="$a"
done
exit 0
STUB

cat > "$TMP/stubs/bd" <<'STUB'
#!/usr/bin/env bash
echo "bd $*" >> "$W/bdlog"
case "$1" in
  ready) if [[ "$*" == *--label* ]]; then echo '[{"id":"t-1","labels":["role:qa"],"assignee":""}]'; else echo '[{"id":"t-1"}]'; fi;;
  show) echo '[{"id":"t-1","title":"t","status":"in_progress","assignee":"qa","labels":["role:qa"]}]';;
  list) echo '[]';;
esac
exit 0
STUB
chmod +x "$TMP/stubs/"*

ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN" && git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# run_loop: env for the stub claude is taken from the caller's exported vars. Sets W and RC.
run_loop() {  # run_loop PREFLIGHT MAX_ATTEMPTS
  W="$TMP/run.$RANDOM"; mkdir -p "$W/data/control" "$W/home"; : > "$W/bdlog"
  RC=0
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home" TZ=UTC
    PATH="$TMP/stubs:$PATH" ROLE=qa KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT="$1" MAX_ATTEMPTS_PER_ISSUE="${2:-1}" MAX_CONSECUTIVE_FAILURES=5 \
      timeout 60 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
}
ALERTS() { echo "$W/data/control/alerts.log"; }
LOOPLOG() { echo "$W/data/logs/qa/loop.log"; }
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z \[[^]]+\] '
PRE="preflight: harness failed to run (check auth): "

# ---------------- AC1-AC4: alert() ----------------

test_ac1_lf_crlf_cr_become_single_spaces_one_line() {
  PREFLIGHT_OUT='line1\nline2\r\nline3\rline4' NOTIFY_URL= run_loop 1
  local n; n=$(wc -l < "$(ALERTS)" 2>/dev/null || echo 0)
  [ "$n" = 1 ] || { fail "ac1: alerts.log has $n lines, expected exactly 1"; return; }
  local line; line=$(cat "$(ALERTS)")
  [[ "$line" =~ $TS_RE ]] || { fail "ac1: line not '<timestamp> [<agent>] <text>': $line"; return; }
  [ "${line#*] }" = "${PRE}line1 line2 line3 line4" ] \
    || { fail "ac1: text is '${line#*] }', expected '${PRE}line1 line2 line3 line4'"; return; }
  pass "ac1: LF/CRLF/CR collapsed to single spaces; exactly one line logged"
}

test_ac2_blank_lines_add_no_blank_line_or_extra_spaces() {
  PREFLIGHT_OUT='\n\nA\n\n\nB\n\n' NOTIFY_URL= run_loop 1
  local n; n=$(wc -l < "$(ALERTS)" 2>/dev/null || echo 0)
  [ "$n" = 1 ] || { fail "ac2: alerts.log has $n lines, expected exactly 1"; return; }
  grep -qE '^\s*$' "$(ALERTS)" && { fail "ac2: blank line in alerts.log"; return; }
  local line; line=$(cat "$(ALERTS)")
  [ "${line#*] }" = "${PRE}A B" ] || { fail "ac2: text is '${line#*] }', expected '${PRE}A B'"; return; }
  [[ "$line" == *"  "* ]] && { fail "ac2: repeated spaces in '$line'"; return; }
  [[ "$line" =~ [[:space:]]$ ]] && { fail "ac2: trailing whitespace in '$line'"; return; }
  pass "ac2: leading/consecutive blank lines collapse cleanly; no blank line, no repeated/trailing spaces"
}

test_ac3_single_line_alert_unchanged() {
  PREFLIGHT_OUT='plain message' NOTIFY_URL= run_loop 1
  local line; line=$(cat "$(ALERTS)" 2>/dev/null)
  [ "$(wc -l < "$(ALERTS)")" = 1 ] && [[ "$line" =~ $TS_RE ]] && [ "${line#*] }" = "${PRE}plain message" ] \
    && pass "ac3: newline-free alert written as before" \
    || fail "ac3: line is '$line'"
}

test_ac4_loop_log_and_notify_are_single_line_same_text() {
  PREFLIGHT_OUT='\nline1\r\nline2\n\nline3' NOTIFY_URL=http://notify.invalid/x run_loop 1
  local want="${PRE}line1 line2 line3"
  local text; text=$(sed 's/^[^]]*\] //' "$(ALERTS)")
  [ "$text" = "$want" ] || { fail "ac4: alerts.log text '$text' != '$want'"; return; }
  grep -qE -v "$TS_RE" "$(LOOPLOG)" && { fail "ac4: loop.log has orphan/blank continuation line: $(grep -E -v "$TS_RE" "$(LOOPLOG)" | head -2)"; return; }
  grep -qF "ALERT: $want" "$(LOOPLOG)" || { fail "ac4: loop.log lacks single-line 'ALERT: $want'"; return; }
  [ -f "$W/notify" ] || { fail "ac4: NOTIFY_URL never called"; return; }
  [ "$(cat "$W/notify")" = "[qa] $want" ] || { fail "ac4: notify text '$(cat "$W/notify")' != '[qa] $want'"; return; }
  pass "ac4: loop.log and NOTIFY_URL text are single-line and equal to the alerts.log text"
}

# ---------------- AC5-AC8: not-completed alert ----------------

nc_alerts() { grep 'not completed' "$(ALERTS)" 2>/dev/null; }

test_ac5_nonzero_exit_status_in_alert() {
  CLAUDE_EXIT=42 NOTIFY_URL= run_loop 0 1
  local a; a=$(nc_alerts)
  [ -n "$a" ] || { fail "ac5: no 'not completed' alert raised"; return; }
  [ "$(echo "$a" | wc -l)" = 1 ] || { fail "ac5: alert spans several lines"; return; }
  [[ "$a" =~ (^|[^0-9])42([^0-9]|$) ]] \
    || { fail "ac5: alert does not state harness exit status 42: $a"; return; }
  pass "ac5: non-zero harness exit status appears in the single alert line"
}

test_ac5_clean_exit_states_ended_without_closing() {
  CLAUDE_EXIT=0 NOTIFY_URL= run_loop 0 1
  local a; a=$(nc_alerts)
  [ -n "$a" ] || { fail "ac5b: no 'not completed' alert raised"; return; }
  echo "$a" | grep -qi 'without closing or explaining' \
    && pass "ac5: clean exit -> 'session ended without closing or explaining' stated" \
    || fail "ac5b: alert lacks the without-closing-or-explaining cause: $a"
}

test_ac6_stderr_excerpt_single_line_and_bounded() {
  local long; long=$(printf 'Y%.0s' $(seq 1 600))
  CLAUDE_EXIT=1 STDERR_TEXT="Error: ERRMARKER boom\nsecond line of error\n$long" NOTIFY_URL= run_loop 0 1
  local a; a=$(nc_alerts)
  [ -n "$a" ] || { fail "ac6: no 'not completed' alert raised"; return; }
  [ "$(echo "$a" | wc -l)" = 1 ] || { fail "ac6: alert spans several lines"; return; }
  [[ "$a" == *ERRMARKER* ]] || { fail "ac6: stderr error excerpt missing: $a"; return; }
  [ "${#a}" -le 600 ] || { fail "ac6: alert is ${#a} chars; excerpt not bounded (<=200 + prefix expected)"; return; }
  [[ "$a" == *"$(printf 'Y%.0s' $(seq 1 300))"* ]] && { fail "ac6: excerpt not truncated to ~200 chars"; return; }
  pass "ac6: stderr error excerpt included, single-line, bounded (alert ${#a} chars)"
}

test_ac6_stream_result_error_excerpt() {
  CLAUDE_EXIT=1 STDOUT_TEXT='{"type":"result","subtype":"error_during_execution","is_error":true,"result":"STREAMERR something broke\\nsecond","num_turns":1,"total_cost_usd":0}' NOTIFY_URL= run_loop 0 1
  local a; a=$(nc_alerts)
  [ -n "$a" ] || { fail "ac6b: no 'not completed' alert raised"; return; }
  [[ "$a" == *STREAMERR* ]] && [ "$(echo "$a" | wc -l)" = 1 ] \
    && pass "ac6: error from the stream-json result included on one line" \
    || fail "ac6b: stream error text missing or multi-line: $a"
}

test_ac7_alert_still_begins_with_legacy_prefix() {
  CLAUDE_EXIT=3 STDERR_TEXT="oops" NOTIFY_URL= run_loop 0 1
  local a text; a=$(nc_alerts)
  [ -n "$a" ] || { fail "ac7: no 'not completed' alert raised"; return; }
  text="${a#*] }"
  [[ "$text" == "t-1 not completed after 1 attempts; labelled needs-team-lead"* ]] \
    && pass "ac7: alert starts with '<id> not completed after <N> attempts; labelled <label>'" \
    || fail "ac7: alert text is '$text'"
}

test_ac8_no_alert_below_attempt_cap() {
  CLAUDE_EXIT=1 STDERR_TEXT="boom" NOTIFY_URL= run_loop 0 3
  [ "$(cat "$W/data/control/state/qa/attempts.t-1" 2>/dev/null)" = 1 ] \
    || { fail "ac8: setup problem, attempts='$(cat "$W/data/control/state/qa/attempts.t-1" 2>/dev/null)' (expected 1 failure recorded)"; return; }
  [ -z "$(nc_alerts)" ] && ! grep -q 'label add t-1 needs-' "$W/bdlog" \
    && pass "ac8: failure below the cap writes no alert and does not escalate" \
    || fail "ac8: alert/escalation raised below cap: $(nc_alerts)"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
