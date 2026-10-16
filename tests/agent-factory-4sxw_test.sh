#!/usr/bin/env bash
# Acceptance tests for agent-factory-4sxw: wait until the quota reset time when the message is an
# hour-only clock time ("resets 7pm (UTC)"). One or more tests per criterion in
# docs/stories/agent-factory-4sxw.md (test_acN_...).
# AC1-AC5 call the real usage_limit_wait_seconds (extracted from bin/agent-loop.sh) with a stub
# `date` that pins "now" to 15:00 today (UTC) +/- an offset. AC6 runs the real loop against stub
# `claude`, `bd`, `sleep` and checks the logged alert.
# Run directly: bash tests/agent-factory-4sxw_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs" "$TMP/datestub"
export TZ=UTC
REAL_DATE="$(command -v date)"

# Stub date: with no -d, behaves as the real date at the pinned instant FAKE_NOW; with -d, real date.
cat > "$TMP/datestub/date" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-d" ] && exec $REAL_DATE "\$@"; done
exec $REAL_DATE -d "@\$FAKE_NOW" "\$@"
STUB
chmod +x "$TMP/datestub/date"

# Extract the function under test.
sed -n '/^usage_limit_wait_seconds() {/,/^}/p' "$KIT_DIR/bin/agent-loop.sh" > "$TMP/fn.sh"

# wait_at HH:MM MESSAGE -> seconds computed when "now" is today at HH:MM:00
wait_at() {
  local now; now=$($REAL_DATE -d "today $1:00" +%s)
  ( export FAKE_NOW="$now" QUOTA_RETRY_INTERVAL=777; PATH="$TMP/datestub:$PATH"
    # shellcheck disable=SC1091
    source "$TMP/fn.sh"; usage_limit_wait_seconds "$2" )
}
check() {  # check TAG NOW MSG EXPECTED
  local got; got=$(wait_at "$2" "$3")
  [ "$got" = "$4" ] && pass "$1" || fail "$1: now=$2 msg='$3' -> '$got', expected $4"
}

test_ac1_hour_only_pm_waits_until_reset() {
  check "ac1: 7pm at 15:00 -> 14460" 15:00 "You've hit your session limit · resets 7pm (UTC)" 14460
}
test_ac1_hour_only_variants() {
  check "ac1: '7 PM' with space/case" 15:00 "limit reached, resets 7 PM" 14460
  check "ac1: 9am at 07:30 -> 5400+60" 07:30 "hit your limit · resets 9am (UTC)" 5460
}
test_ac2_twelve_am_is_midnight() {
  check "ac2: 12am at 23:00 -> 1h+60 (00:00 tomorrow)" 23:00 "resets 12am (UTC)" 3660
}
test_ac2_twelve_pm_is_noon() {
  check "ac2: 12pm at 10:00 -> 2h+60 (12:00)" 10:00 "resets 12pm (UTC)" 7260
}
test_ac3_just_passed_hour_retries_in_60s() {
  check "ac3: 7pm passed 5 min ago -> 60" 19:05 "resets 7pm (UTC)" 60
}
test_ac3_passed_earlier_rolls_to_tomorrow() {
  check "ac3: 7pm passed 1h ago -> tomorrow 19:00+60" 20:00 "resets 7pm (UTC)" 82860
  check "ac3: 7pm passed 11 min ago -> tomorrow" 19:11 "resets 7pm (UTC)" 85800
}
test_ac4_minutes_form_unchanged() {
  check "ac4: 5:50pm at 15:00 -> 10200+60" 15:00 "You've hit your session limit · resets 5:50pm (UTC)" 10260
  check "ac4: 5:50pm just passed -> 60" 17:55 "resets 5:50pm (UTC)" 60
  check "ac4: 5:50pm passed earlier -> tomorrow" 18:50 "resets 5:50pm (UTC)" 82860
  check "ac4: 12:30am handled" 23:00 "resets 12:30am" 5460
}
test_ac4_minutes_not_misread_as_hour() {
  # the minutes form must not be parsed as the bare hour "50pm"/"5pm"
  check "ac4: '6:50pm' is not read as 6pm or 50pm" 15:00 "continuing automatically at 6:50pm" 13860
}
test_ac5_no_clock_time_falls_back() {
  check "ac5: no time -> QUOTA_RETRY_INTERVAL" 15:00 "You've hit your session limit" 777
  check "ac5: digits but no am/pm -> fallback" 15:00 "limit hit after 7 requests, try later" 777
  check "ac5: empty message -> fallback" 15:00 "" 777
}

# ---- AC6: real loop, alert shows the computed wait ----
cat > "$TMP/stubs/claude" <<'STUB'
#!/usr/bin/env bash
echo x >> "$W/claude_runs"
printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"model\":\"<synthetic>\",\"content\":[{\"type\":\"text\",\"text\":\"$LIMIT_MSG\"}]}}"
printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","num_turns":1,"total_cost_usd":0}'
exit 0
STUB
cat > "$TMP/stubs/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$1" >> "$W/sleeps"
touch "$W/data/control/STOP"
exit 0
STUB
cat > "$TMP/stubs/bd" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  ready) if [[ "$*" == *--label* ]]; then echo '[{"id":"t-1","labels":["role:qa"],"assignee":""}]'; else echo '[{"id":"t-1"}]'; fi;;
  show) echo '[{"id":"t-1","title":"t","status":"in_progress","assignee":"qa","labels":["role:qa"]}]';;
  list) echo '[]';;
esac
exit 0
STUB
chmod +x "$TMP/stubs/claude" "$TMP/stubs/sleep" "$TMP/stubs/bd"
ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN" && git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

test_ac6_alert_shows_computed_wait_not_fallback() {
  local W; W="$(mktemp -d "$TMP/run.XXXXXX")"; mkdir -p "$W/data/control" "$W/home"
  # hour-only reset 2 hours from now: true wait is between 1h and 2h (+60s buffer)
  local msg="You've hit your session limit · resets $($REAL_DATE -u -d '+2 hours' +%-I%P) (UTC)"
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home" LIMIT_MSG="$msg"
    PATH="$TMP/stubs:$PATH" ROLE=qa KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 QUOTA_RETRY_INTERVAL=777 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 \
      timeout 60 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || true
  local alert n; alert=$(cat "$W/data/control/alerts.log" 2>/dev/null)
  n=$(echo "$alert" | grep -i 'limit' | grep -oE 'waiting [0-9]+s' | head -1 | grep -oE '[0-9]+')
  [ -n "$n" ] || { fail "ac6: no 'waiting Ns' in quota alert (alerts: '$alert'; msg: '$msg')"; return; }
  [ "$n" != 777 ] || { fail "ac6: alert shows fallback 777s for hour-only message '$msg'"; return; }
  [ "$n" -gt 3600 ] && [ "$n" -le 7260 ] || { fail "ac6: alert wait ${n}s outside 3600-7260s for '$msg'"; return; }
  [ "$(head -1 "$W/sleeps" 2>/dev/null)" = "$n" ] || { fail "ac6: slept '$(head -1 "$W/sleeps" 2>/dev/null)' but alert said ${n}s"; return; }
  pass "ac6: alert and sleep use computed wait (${n}s) for hour-only message"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
