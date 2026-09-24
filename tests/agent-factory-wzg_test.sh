#!/usr/bin/env bash
# Acceptance tests for agent-factory-wzg: "Preflight recent alerts".
#
# One function per acceptance criterion in docs/stories/agent-factory-wzg.md (test_acN_...).
# Written from the story ONLY - docs/design/agent-factory-wzg.md may not exist yet or may still
# be changing in parallel, per the QA stage-tests instructions in CLAUDE.md.
#
# Test surface: bin/board.sh's recent_alerts(), the same single entry point agent-factory-2do and
# agent-factory-47q's tests already exercise (see tests/agent-factory-2do_test.sh /
# tests/agent-factory-47q_test.sh) - it is still the only reader of alerts.log's display, and
# board.sh already sources cleanly today (2do's loop-guard refactor is already merged), so no
# "not implemented yet" timeout dance is needed here: recent_alerts() runs today, it just doesn't
# yet apply this story's new resolution condition, so these tests fail on plain assertion
# mismatches until it does.
#
# The one new fixture this story's tests need beyond 2do/47q's is a way to say "this agent has
# started again since timestamp T". The story (Context) is explicit that a *successful* preflight
# logs nothing to alerts.log - so that signal cannot live in alerts.log itself. The only place in
# the codebase that already records, per agent, a timestamped "this agent has started" fact is
# agent-loop.sh's own `log "started: role=$ROLE ..."` line (agent-loop.sh, just after the
# preflight block), written via log() to "$DATA_DIR/logs/$ROLE/loop.log" - already relied on
# elsewhere as *the* liveness marker for an agent having started (docs/design/agent-factory-mi3.md,
# docs/design/agent-factory-9l0.md's smoke-test steps both check for it; tests/agent-factory-stg_test.sh
# already reads "$DATA_DIR/logs/<role>/loop.log" directly). These tests fabricate that same file
# under a scratch DATA_DIR to represent "the agent started again", without touching agent-loop.sh
# itself (out of scope per the story). If the design ends up sourcing this signal differently,
# these fixtures - not the assertions - are what needs updating.
#
# Per the story's Context, "usage limit hit" is its own alert family (already resolved by
# agent-factory-2do's wait-window logic) even when it occurs during preflight - AC5 lists
# "usage-limit" as one of the families this story's start-based expiry must NOT touch. Only the
# other two preflight alert messages ("preflight: bd cannot reach the Beads database" and
# "preflight: claude failed to run ...") are this story's concern.
#
# Run directly: bash tests/agent-factory-wzg_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

STUB_BD_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_BD_DIR"' EXIT

# Stub `bd`, needed only by the AC5 needs-human line (still_needs_human's `bd show <id> --json`).
# Anything else exits non-zero, same as a real bd with no reachable DB - recent_alerts must not
# depend on it for the preflight-restart logic under test here.
cat > "$STUB_BD_DIR/bd" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "show" ] && [ "$2" = "issue-still-flagged" ]; then
  echo '{"id":"issue-still-flagged","status":"open","labels":["needs-human"]}'
  exit 0
fi
exit 1
STUBEOF
chmod +x "$STUB_BD_DIR/bd"

now_ts() { date -u -d "$1" +%FT%TZ; }

# LOOP_LOGS["<agent-id>"]="<loop.log content>" - populated per test, consumed and reset by
# run_recent_alerts. See the file header for why loop.log is the fixture for "agent started again".
declare -A LOOP_LOGS

started_line() {
  # Mirrors agent-loop.sh's `log "started: role=$ROLE model=... max_turns=... timeout=..."` line
  # exactly (timestamp, [agent-id], message) - the marker these tests treat as "started again".
  local ts="$1" agent="$2"
  printf '%s [%s] started: role=%s model=default max_turns=60 timeout=45m\n' "$ts" "$agent" "$agent"
}

# Sources bin/board.sh in a throwaway DATA_DIR containing the given alerts.log content plus
# whatever's staged in LOOP_LOGS, then calls recent_alerts and captures its stdout.
# Sets RESULT_OUT / RESULT_RC. Resets LOOP_LOGS on return so tests don't leak fixtures into each
# other.
run_recent_alerts() {
  local content="$1"
  local tmp out rc agent
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/control"
  printf '%s' "$content" > "$tmp/control/alerts.log"
  for agent in "${!LOOP_LOGS[@]}"; do
    mkdir -p "$tmp/logs/$agent"
    printf '%s' "${LOOP_LOGS[$agent]}" > "$tmp/logs/$agent/loop.log"
  done
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
  LOOP_LOGS=()
  RESULT_OUT="$out"
  RESULT_RC=$rc
}

unexpected_rc_msg() {
  if [ "$RESULT_RC" -eq 124 ]; then
    echo "bin/board.sh hung (timeout) sourcing/calling recent_alerts - unexpected, it already sources cleanly today"
  elif [ "$RESULT_RC" -eq 97 ]; then
    echo "recent_alerts() is not defined by bin/board.sh"
  else
    echo "unexpected: rc=$RESULT_RC output=$RESULT_OUT"
  fi
}

# --- AC1: preflight alert from an earlier start disappears once that same agent has started
#     again, regardless of how recently the alert was logged. ---
test_ac1_bd_unreachable_dropped_after_restart() {
  local ts_alert ts_start line
  ts_alert="$(now_ts '30 seconds ago')"
  ts_start="$(now_ts '10 seconds ago')"
  line="$ts_alert [engineer] preflight: bd cannot reach the Beads database"
  LOOP_LOGS[engineer]="$(started_line "$ts_start" engineer)"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac1 (bd unreachable): $(unexpected_rc_msg)"; return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    fail "ac1: bd-unreachable preflight alert still shown after engineer started again:
$RESULT_OUT"
  else
    pass "ac1: bd-unreachable preflight alert is dropped once that agent has started again"
  fi
}

test_ac1_claude_failed_dropped_after_restart() {
  local ts_alert ts_start line
  ts_alert="$(now_ts '30 seconds ago')"
  ts_start="$(now_ts '10 seconds ago')"
  line="$ts_alert [engineer] preflight: claude failed to run (check API key/token): boom"
  LOOP_LOGS[engineer]="$(started_line "$ts_start" engineer)"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac1 (claude failed): $(unexpected_rc_msg)"; return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    fail "ac1: claude-failed preflight alert still shown after engineer started again:
$RESULT_OUT"
  else
    pass "ac1: claude-failed preflight alert is dropped once that agent has started again"
  fi
}

test_ac1_dropped_even_when_very_fresh() {
  # "regardless of how recently it was logged" - use a two-second-old alert, well inside every
  # tail-window/age-cutoff limit, so a pass here can only be explained by the new start-based
  # resolution, not by any age-based mechanism.
  local ts_alert ts_start line
  ts_alert="$(now_ts '2 seconds ago')"
  ts_start="$(now_ts '1 second ago')"
  line="$ts_alert [engineer] preflight: bd cannot reach the Beads database"
  LOOP_LOGS[engineer]="$(started_line "$ts_start" engineer)"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac1 (very fresh): $(unexpected_rc_msg)"; return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    fail "ac1: a 2-second-old preflight alert was still shown after a restart 1 second later - age is not what should drop it:
$RESULT_OUT"
  else
    pass "ac1: preflight alert is dropped on restart regardless of how recently it was logged"
  fi
}

# --- AC2: preflight alert from the agent's current (most recent) start, not yet restarted,
#     keeps appearing. ---
test_ac2_kept_when_agent_has_not_restarted_since() {
  local ts_alert line
  ts_alert="$(now_ts '30 seconds ago')"
  line="$ts_alert [engineer] preflight: claude failed to run (check API key/token): boom"
  # No LOOP_LOGS entry for engineer at all: no start recorded since this alert.
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac2: $(unexpected_rc_msg)"; return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    pass "ac2: preflight alert from the current start keeps appearing while the agent hasn't restarted"
  else
    fail "ac2: preflight alert was dropped even though the agent has not started again since:
$RESULT_OUT"
  fi
}

# --- AC3: two preflight alerts from the same agent's two successive starts - only the most
#     recent one appears, even though the older one is still within the age cutoff. ---
test_ac3_only_most_recent_of_two_preflight_alerts_shown() {
  local ts_old ts_new line_old line_new
  ts_old="$(now_ts '45 minutes ago')"   # within the default 60-minute cutoff
  ts_new="$(now_ts '5 minutes ago')"
  line_old="$ts_old [engineer] preflight: claude failed to run (check API key/token): first failure"
  line_new="$ts_new [engineer] preflight: claude failed to run (check API key/token): second failure"
  run_recent_alerts "$line_old
$line_new
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac3: $(unexpected_rc_msg)"; return
  fi
  local ok=1
  if echo "$RESULT_OUT" | grep -qF "$line_old"; then
    fail "ac3: the OLDER of two successive-start preflight alerts is still shown (should be dropped even though within the age cutoff):
$RESULT_OUT"
    ok=0
  fi
  if ! echo "$RESULT_OUT" | grep -qF "$line_new"; then
    fail "ac3: the NEWER of two successive-start preflight alerts is missing (should be shown):
$RESULT_OUT"
    ok=0
  fi
  [ "$ok" = 1 ] && pass "ac3: only the most recent of two successive-start preflight alerts for the same agent is shown"
}

# --- AC4: with alerts for two different agents, one agent restarting affects only that agent's
#     own preflight alert(s). ---
test_ac4_restart_affects_only_that_agents_own_alerts() {
  local ts_alert ts_start line_engineer line_qa
  ts_alert="$(now_ts '30 seconds ago')"
  ts_start="$(now_ts '10 seconds ago')"
  line_engineer="$ts_alert [engineer] preflight: bd cannot reach the Beads database"
  line_qa="$ts_alert [qa] preflight: claude failed to run (check API key/token): boom"
  LOOP_LOGS[engineer]="$(started_line "$ts_start" engineer)"
  # No LOOP_LOGS entry for qa: qa has not started again.
  run_recent_alerts "$line_engineer
$line_qa
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac4: $(unexpected_rc_msg)"; return
  fi
  local ok=1
  if echo "$RESULT_OUT" | grep -qF "$line_engineer"; then
    fail "ac4: engineer's preflight alert still shown after engineer restarted:
$RESULT_OUT"
    ok=0
  fi
  if ! echo "$RESULT_OUT" | grep -qF "$line_qa"; then
    fail "ac4: qa's preflight alert was dropped even though qa (a different agent) never restarted:
$RESULT_OUT"
    ok=0
  fi
  [ "$ok" = 1 ] && pass "ac4: one agent restarting only affects that agent's own preflight alerts"
}

# --- AC5: non-preflight alert families (needs-human, usage-limit, circuit breaker, daily budget,
#     git sync failure, clone failure) are unaffected by this story's start-based expiry, even
#     when that same agent has since started again. ---
test_ac5_non_preflight_families_unaffected_by_restart() {
  local ts ts_start
  ts="$(now_ts '30 seconds ago')"
  ts_start="$(now_ts '10 seconds ago')"
  local lines=(
    "$ts [engineer] issue-still-flagged flagged needs-human by the agent"
    "$ts [engineer] preflight: usage limit hit (5-hour limit reached); waiting 100000s before retrying startup"
    "$ts [engineer] circuit breaker: 5 consecutive failures; stopping engineer"
    "$ts [engineer] daily budget reached (42.00 USD); pausing 3600s"
    "$ts [engineer] git sync failed; releasing issue-x"
    "$ts [engineer] cannot clone git@example.com:org/repo.git"
  )
  LOOP_LOGS[engineer]="$(started_line "$ts_start" engineer)"
  local joined
  printf -v joined '%s\n' "${lines[@]}"
  run_recent_alerts "$joined"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac5: $(unexpected_rc_msg)"; return
  fi
  local ok=1 l
  for l in "${lines[@]}"; do
    echo "$RESULT_OUT" | grep -qF "$l" || { fail "ac5: alert line dropped/altered after engineer restarted, but this family should be unaffected by that: $l
Got:
$RESULT_OUT"; ok=0; }
  done
  [ "$ok" = 1 ] && pass "ac5: needs-human/usage-limit/circuit-breaker/daily-budget/git-sync/clone alerts are unaffected by a same-agent restart"
}

# --- AC6: a preflight alert for an agent that has NOT started again continues to be governed
#     exactly as before - existing tail-window and 47q age-cutoff behaviour, no regression. ---
test_ac6_no_restart_old_alert_still_dropped_by_age_cutoff() {
  local ts_alert line
  ts_alert="$(now_ts '90 minutes ago')"   # past the default 60-minute ALERT_MAX_AGE_MINUTES cutoff
  line="$ts_alert [engineer] preflight: bd cannot reach the Beads database"
  # No LOOP_LOGS entry: engineer never restarted - this must still be governed by the pre-existing
  # age-cutoff logic (agent-factory-47q), not kept alive by this story's change.
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac6 (age cutoff): $(unexpected_rc_msg)"; return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    fail "ac6: a 90-minute-old preflight alert with no restart is still shown - should be dropped by the existing age cutoff, unchanged by this story:
$RESULT_OUT"
  else
    pass "ac6: without a restart, a preflight alert past the age cutoff is still dropped exactly as before"
  fi
}

test_ac6_no_restart_recent_alert_still_shown() {
  local ts_alert line
  ts_alert="$(now_ts '10 minutes ago')"   # well within the default 60-minute cutoff
  line="$ts_alert [engineer] preflight: claude failed to run (check API key/token): boom"
  run_recent_alerts "$line
"
  if [ "$RESULT_RC" -ne 0 ]; then
    fail "ac6 (recent, no restart): $(unexpected_rc_msg)"; return
  fi
  if echo "$RESULT_OUT" | grep -qF "$line"; then
    pass "ac6: without a restart, a preflight alert within the age cutoff is still shown exactly as before"
  else
    fail "ac6: a recent preflight alert with no restart was dropped - should still be shown per the existing (unchanged) age-cutoff behaviour:
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

test_ac1_bd_unreachable_dropped_after_restart
test_ac1_claude_failed_dropped_after_restart
test_ac1_dropped_even_when_very_fresh
test_ac2_kept_when_agent_has_not_restarted_since
test_ac3_only_most_recent_of_two_preflight_alerts_shown
test_ac4_restart_affects_only_that_agents_own_alerts
test_ac5_non_preflight_families_unaffected_by_restart
test_ac6_no_restart_old_alert_still_dropped_by_age_cutoff
test_ac6_no_restart_recent_alert_still_shown
test_shellcheck_clean

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
