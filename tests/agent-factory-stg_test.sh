#!/usr/bin/env bash
# Acceptance tests for agent-factory-stg: wait out a usage-limit hit instead of failing the issue.
# One function per acceptance criterion in docs/stories/agent-factory-stg.md (test_acN_...).
# Each test runs the real bin/agent-loop.sh against stub `claude`, `bd` and `sleep` on PATH and a
# scratch git origin. The stub `claude` reproduces the observed CLI behaviour: the limit message
# appears ONLY in stream-json stdout (synthetic assistant message + is_error result), stderr empty.
# The stub `sleep` records its argument (plus how many claude runs had happened) and touches the
# STOP file after SLEEP_STOP_AFTER calls, so the otherwise endless loop exits.
# Run directly: bash tests/agent-factory-stg_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

cat > "$TMP/stubs/claude" <<'STUB'
#!/usr/bin/env bash
# CLAUDE_MODE: limit (real limit hit, stdout only) | mention (text mentions limits, ends normally)
#              mention_fail (mentions limits, ordinary is_error failure) | quoted (tool_result quotes full message)
echo x >> "$W/claude_runs"
emit() { printf '%s\n' "$1"; }
case "$CLAUDE_MODE" in
  limit)
    emit "{\"type\":\"assistant\",\"message\":{\"model\":\"<synthetic>\",\"content\":[{\"type\":\"text\",\"text\":\"$LIMIT_MSG\"}]}}"
    emit '{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","num_turns":1,"total_cost_usd":0}';;
  mention)
    emit '{"type":"assistant","message":{"content":[{"type":"text","text":"I read a doc about the usage limit and the session limit; unrelated."}]}}'
    emit '{"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":0}';;
  mention_fail)
    emit '{"type":"assistant","message":{"content":[{"type":"text","text":"The issue talks about a usage limit and a session limit."}]}}'
    emit '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":60,"total_cost_usd":0}';;
  quoted)
    emit '{"type":"user","message":{"content":[{"type":"tool_result","content":"log line: You have hit your session limit · resets 1:50pm (UTC) (from an old transcript)"}]}}'
    emit '{"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":0}';;
esac
exit 0
STUB

cat > "$TMP/stubs/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$1 $(wc -l < "$W/claude_runs" 2>/dev/null || echo 0)" >> "$W/sleeps"
n=$(wc -l < "$W/sleeps")
[ "$n" -ge "${SLEEP_STOP_AFTER:-1}" ] && touch "$W/data/control/STOP"
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

# Scratch origin with a main branch.
ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN" && git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# run_loop MODE LIMIT_MSG [SLEEP_STOP_AFTER] [MAX_ATTEMPTS]; sets W (workdir) and exit code RC
run_loop() {
  W="$TMP/run.$RANDOM"; mkdir -p "$W/data/control" "$W/home"; : > "$W/bdlog"
  RC=0
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home" TZ=UTC
    export CLAUDE_MODE="$1" LIMIT_MSG="$2" SLEEP_STOP_AFTER="${3:-1}"
    PATH="$TMP/stubs:$PATH" ROLE=qa KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 QUOTA_RETRY_INTERVAL=777 MAX_ATTEMPTS_PER_ISSUE="${4:-1}" MAX_CONSECUTIVE_FAILURES="${5:-1}" \
      timeout 60 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
}
reset_msg() { echo "You've hit your session limit · resets $(date -u -d "+${1:-2} hours" +%-I:%M%P) (UTC)"; }
attempts_file() { echo "$W/data/control/state/qa/attempts.t-1"; }
runs() { wc -l < "$W/claude_runs" 2>/dev/null || echo 0; }
alerts() { cat "$W/data/control/alerts.log" 2>/dev/null; }
# assert_not_counted TAG: AC2 invariants on the current run
assert_not_counted() {
  [ ! -s "$(attempts_file)" ] || { fail "$1: attempt count incremented ($(cat "$(attempts_file)"))"; return 1; }
  grep -q 'consecutive failures' "$W/data/logs/qa/loop.log" && { fail "$1: consecutive-failure counter incremented"; return 1; }
  grep -q 'label add t-1 needs-human' "$W/bdlog" && { fail "$1: labelled needs-human"; return 1; }
  grep -q -- '--append-notes' "$W/bdlog" && { fail "$1: escalation note appended"; return 1; }
  alerts | grep -qE 'circuit breaker|not completed' && { fail "$1: failure alert raised"; return 1; }
  return 0
}
last_open_after_run() { grep -q 'update t-1 --status open' "$W/bdlog"; }

test_ac1_limit_in_stdout_only_waits_until_reset() {
  run_loop limit "$(reset_msg 2)"
  local s; s=$(head -1 "$W/sleeps" 2>/dev/null)
  [ -n "$s" ] || { fail "ac1: loop never slept after a stdout-only limit hit"; return; }
  local secs=${s% *} at=${s#* }
  [ "$secs" -ge 7100 ] && [ "$secs" -le 7900 ] \
    || { fail "ac1: first sleep was ${secs}s, expected ~7200-7800s (until shortly after reset)"; return; }
  [ "$at" = 1 ] || { fail "ac1: $at claude runs before waiting; expected exactly 1"; return; }
  pass "ac1: stdout-only limit hit recognised; waited ${secs}s until just after reset"
}

test_ac1_wait_precedes_anything_else() {
  run_loop limit "$(reset_msg 2)" 2
  # With the limit persisting, no claude run may happen between the hit and the long sleep.
  local first; first=$(head -1 "$W/sleeps" 2>/dev/null)
  [ -n "$first" ] && [ "${first% *}" -ge 7100 ] && [ "${first#* }" = 1 ] \
    && pass "ac1: long wait is the first thing after the hit (no retry before it)" \
    || fail "ac1: first sleep was '${first:-none}' (want >=7100s after exactly 1 run)"
}

test_ac2_usage_limit_not_a_failure_and_issue_released() {
  run_loop limit "$(reset_msg 2)"
  assert_not_counted "ac2" || return
  last_open_after_run || { fail "ac2: issue not released (no 'update t-1 --status open')"; return; }
  [ "$RC" -eq 0 ] || { fail "ac2: loop exited $RC (circuit breaker?) instead of waiting"; return; }
  pass "ac2: no attempt/failure counted, no needs-human, issue released"
}

test_ac3_no_parseable_reset_time_uses_fallback_interval() {
  run_loop limit "You've hit your session limit"
  local s; s=$(head -1 "$W/sleeps" 2>/dev/null)
  [ -n "$s" ] || { fail "ac3: no sleep at all - retried immediately"; return; }
  [ "${s% *}" = 777 ] || { fail "ac3: slept ${s% *}s, expected QUOTA_RETRY_INTERVAL=777"; return; }
  [ "${s#* }" = 1 ] || { fail "ac3: retried before waiting"; return; }
  assert_not_counted "ac3" || return
  pass "ac3: unparseable reset time -> waited fallback interval, no failure counted"
}

test_ac4_words_in_conversation_is_not_a_limit_hit() {
  local mode
  for mode in mention mention_fail quoted; do
    run_loop "$mode" "" 1 2 5
    if alerts | grep -qi 'usage limit'; then fail "ac4($mode): treated as usage-limit hit"; return; fi
    if [ "$(head -1 "$W/sleeps" 2>/dev/null | cut -d' ' -f1)" != 5 ]; then
      fail "ac4($mode): first sleep was '$(head -1 "$W/sleeps" 2>/dev/null)', expected ordinary 5s pause"; return; fi
    [ "$(cat "$(attempts_file)" 2>/dev/null)" = 1 ] \
      || { fail "ac4($mode): ordinary failure accounting not applied (attempts='$(cat "$(attempts_file)" 2>/dev/null)')"; return; }
  done
  pass "ac4: mentions of usage/session limit (incl. quoted message in a tool_result) get ordinary failure accounting"
}

test_ac5_repeated_hit_waits_again_without_counting() {
  run_loop limit "$(reset_msg 1)" 2
  [ "$(runs)" = 2 ] || { fail "ac5: expected 2 claude runs, got $(runs)"; return; }
  local a b; a=$(sed -n 1p "$W/sleeps"); b=$(sed -n 2p "$W/sleeps")
  [ "${a% *}" -ge 3500 ] && [ "${b% *}" -ge 3500 ] && [ "${b#* }" = 2 ] \
    || { fail "ac5: sleeps '$a' / '$b'; want two long waits, second after 2nd run"; return; }
  assert_not_counted "ac5" || return
  pass "ac5: retry hitting the limit again waits again, still no failure counted"
}

test_ac6_alert_states_limit_and_wait_length() {
  run_loop limit "$(reset_msg 2)"
  local a; a=$(alerts)
  echo "$a" | grep -qi 'limit' || { fail "ac6: no alert mentioning the limit (alerts: '$a')"; return; }
  echo "$a" | grep -qiE '(7[0-9]{3}|[0-9]{2,3} ?min|[12] ?h(ou)?r?|wait)' \
    && echo "$a" | grep -qE '[0-9]+ ?(s|sec|seconds|m|min|minutes|h|hr|hours)\b' \
    || { fail "ac6: alert lacks a wait duration: '$a'"; return; }
  pass "ac6: alert states limit hit and wait length"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
