#!/usr/bin/env bash
# Acceptance tests for agent-factory-47q: "Time-based expiry for recent alerts".
# One test per acceptance criterion in docs/stories/agent-factory-47q.md (test_acN_...).
# Sources bin/board.sh (guarded, no refresh loop) with a stub `bd` on PATH and a throwaway DATA_DIR,
# then calls recent_alerts.
# Run directly: bash tests/agent-factory-47q_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

STUB_BD_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_BD_DIR"' EXIT
cat > "$STUB_BD_DIR/bd" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "show" ]; then
  case "$2" in
    issue-still-flagged) echo '{"id":"issue-still-flagged","status":"open","labels":["needs-human"]}'; exit 0 ;;
  esac
fi
exit 1
STUBEOF
chmod +x "$STUB_BD_DIR/bd"

ts_ago() { date -u -d "$1 minutes ago" +%FT%TZ; }

# run_recent_alerts <content> [ALERT_MAX_AGE_MINUTES value or "unset"]
# Sets RESULT_OUT, RESULT_RC, LOG_BEFORE_SUM, LOG_AFTER_SUM.
run_recent_alerts() {
  local content="$1" age="${2:-unset}" tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/control"
  printf '%s' "$content" > "$tmp/control/alerts.log"
  LOG_BEFORE_SUM="$(sha256sum < "$tmp/control/alerts.log")"
  local envcmd=(env -u ALERT_MAX_AGE_MINUTES)
  [ "$age" != "unset" ] && envcmd=(env "ALERT_MAX_AGE_MINUTES=$age")
  RESULT_OUT="$(DATA_DIR="$tmp" PATH="$STUB_BD_DIR:$PATH" "${envcmd[@]}" timeout 10 bash -c '
    source bin/board.sh
    recent_alerts' 2>&1)"
  RESULT_RC=$?
  LOG_AFTER_SUM="$(sha256sum < "$tmp/control/alerts.log")"
  rm -rf "$tmp"
}

has() { grep -qF -- "$1" <<<"$RESULT_OUT"; }

# expect_shown/expect_hidden <test label> <line>  (uses last run_recent_alerts result)
expect_shown() {
  if [ "$RESULT_RC" -eq 0 ] && has "$2"; then pass "$1"; else fail "$1: expected line shown (rc=$RESULT_RC): $2
Got: $RESULT_OUT"; fi
}
expect_hidden() {
  if [ "$RESULT_RC" -eq 0 ] && ! has "$2"; then pass "$1"; else fail "$1: expected line hidden (rc=$RESULT_RC): $2
Got: $RESULT_OUT"; fi
}

test_ac1_old_alert_hidden() {
  local l1 l2 l3
  l1="$(ts_ago 120) [engineer] circuit breaker: 5 consecutive failures; stopping engineer"
  l2="$(ts_ago 180) [qa] preflight: claude failed to run (check API key/token): boom"
  l3="$(ts_ago 1500) [po] daily budget reached (42.00 USD); pausing 3600s"
  run_recent_alerts "$l1
$l2
$l3
"
  expect_hidden "ac1: 2h-old circuit-breaker alert hidden" "$l1"
  has "$l2" && fail "ac1: old preflight alert still shown" || pass "ac1: old preflight alert hidden"
  has "$l3" && fail "ac1: day-old budget alert still shown" || pass "ac1: day-old budget alert hidden"
}

test_ac2_recent_alert_shown_unchanged() {
  local l="$(ts_ago 10) [engineer] circuit breaker: git sync failing; stopping"
  run_recent_alerts "$l
"
  expect_shown "ac2: 10-min-old alert still shown" "$l"
  if [ "$RESULT_OUT" = "$l" ]; then pass "ac2: shown byte-for-byte unchanged"; else fail "ac2: output altered: $RESULT_OUT"; fi
}

test_ac3_default_is_one_hour() {
  local young="$(ts_ago 50) [engineer] cannot clone git@example.com:org/repo.git"
  local old="$(ts_ago 70) [engineer] circuit breaker: git sync failing; stopping"
  run_recent_alerts "$old
$young
"
  expect_shown "ac3: 50-min-old alert kept under default" "$young"
  expect_hidden "ac3: 70-min-old alert dropped under default (1h)" "$old"
}

test_ac4_env_var_shorter() {
  local a="$(ts_ago 10) [engineer] circuit breaker: git sync failing; stopping"
  local b="$(ts_ago 2) [engineer] cannot clone git@example.com:org/repo.git"
  run_recent_alerts "$a
$b
" 5
  expect_hidden "ac4: ALERT_MAX_AGE_MINUTES=5 drops 10-min-old alert" "$a"
  expect_shown "ac4: ALERT_MAX_AGE_MINUTES=5 keeps 2-min-old alert" "$b"
}

test_ac4_env_var_longer() {
  local a="$(ts_ago 90) [engineer] circuit breaker: git sync failing; stopping"
  local b="$(ts_ago 300) [engineer] cannot clone git@example.com:org/repo.git"
  run_recent_alerts "$a
$b
" 180
  expect_shown "ac4: ALERT_MAX_AGE_MINUTES=180 keeps 90-min-old alert" "$a"
  expect_hidden "ac4: ALERT_MAX_AGE_MINUTES=180 drops 300-min-old alert" "$b"
}

test_ac5_needs_human_not_hidden_by_age() {
  local flagged="$(ts_ago 3000) [engineer] issue-still-flagged flagged needs-human by the agent"
  local gone="$(ts_ago 3000) [engineer] issue-unknown-label-removed flagged needs-human by the agent"
  run_recent_alerts "$flagged
"
  expect_shown "ac5: still-flagged needs-human alert 2 days old is NOT hidden by age" "$flagged"
  run_recent_alerts "$flagged
" 5
  expect_shown "ac5: still-flagged needs-human alert not hidden even with ALERT_MAX_AGE_MINUTES=5" "$flagged"
}

test_ac5_usage_limit_follows_wait_not_age() {
  local waiting="$(ts_ago 120) [engineer] issue-x: usage limit hit (5-hour limit reached); waiting 100000s to retry"
  local elapsed="$(ts_ago 2) [engineer] usage limit hit (5-hour limit reached); waiting 10s before retrying"
  run_recent_alerts "$waiting
"
  expect_shown "ac5: usage-limit alert within its wait window kept though older than max age" "$waiting"
  run_recent_alerts "$elapsed
"
  expect_hidden "ac5: usage-limit alert past its wait window still dropped (2do)" "$elapsed"
}

test_ac6_unparseable_timestamp_shown() {
  local a="not-a-timestamp [engineer] circuit breaker: git sync failing; stopping"
  local b="9999-99-99T99:99:99Z [engineer] circuit breaker: 5 consecutive failures; stopping engineer"
  local c="garbage line with no format at all"
  run_recent_alerts "$a
$b
$c
"
  expect_shown "ac6: non-timestamp alert shown" "$a"
  expect_shown "ac6: invalid-date timestamp alert shown (fail visible)" "$b"
  expect_shown "ac6: unformatted line shown" "$c"
}

test_ac7_log_unmodified_and_tail_window() {
  local content="" i
  for i in 1 2 3 4 5 6 7 8; do
    content+="$(ts_ago "$i") [engineer] cannot clone repo-$i
"
  done
  run_recent_alerts "$content"
  # newest-last order in file: lines 1..8 written; last 6 are repo-3..repo-8
  if [ "$LOG_BEFORE_SUM" = "$LOG_AFTER_SUM" ]; then pass "ac7: alerts.log unmodified"; else fail "ac7: alerts.log was modified"; fi
  local n
  n="$(grep -c . <<<"$RESULT_OUT")"
  if [ "$n" -eq 6 ] && has "repo-3" && ! has "repo-2" && ! has "repo-1"; then
    pass "ac7: 6-line tail window still applies"
  else
    fail "ac7: expected only last 6 lines (repo-3..8), got $n lines:
$RESULT_OUT"
  fi

  # window applies before age filtering: old lines in the tail are dropped, not back-filled from earlier lines
  local fresh="$(ts_ago 1) [engineer] cannot clone fresh"
  content="$(ts_ago 5) [engineer] cannot clone early-fresh
"
  for i in 1 2 3 4 5; do content+="$(ts_ago 500) [engineer] cannot clone stale-$i
"; done
  content+="$fresh
"
  run_recent_alerts "$content"
  if has "fresh" && ! has "stale-" && ! has "early-fresh"; then
    pass "ac7: tail window applied first, then age filter (no back-fill)"
  else
    fail "ac7: unexpected output for tail+age combination:
$RESULT_OUT"
  fi
  [ "$LOG_BEFORE_SUM" = "$LOG_AFTER_SUM" ] && pass "ac7: alerts.log unmodified after filtering" || fail "ac7: alerts.log modified after filtering"
}

test_ac1_old_alert_hidden
test_ac2_recent_alert_shown_unchanged
test_ac3_default_is_one_hour
test_ac4_env_var_shorter
test_ac4_env_var_longer
test_ac5_needs_human_not_hidden_by_age
test_ac5_usage_limit_follows_wait_not_age
test_ac6_unparseable_timestamp_shown
test_ac7_log_unmodified_and_tail_window

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
