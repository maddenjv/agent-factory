#!/usr/bin/env bash
# Acceptance tests for agent-factory-hr7o: move issue throttling from team-lead to PO
# (MAX_READY_ENGINEER_ISSUES). One function per acceptance criterion in
# docs/stories/agent-factory-hr7o.md (test_acN_...).
#
# Behavioural ACs (3-8) run the real bin/agent-loop.sh against a stub `bd`, a stub `claude` and a
# scratch git origin (same harness style as tests/agent-factory-dx0_test.sh). The stub `bd`
# answers any `ready`/`list` call from a fixture, honouring --label, so the tests do not depend on
# exactly which bd subcommand the implementation uses to count ready role:engineer issues. Setting
# BD_FAIL_ENGINEER=1 makes any bd call mentioning role:engineer exit non-zero (AC7).
# Content ACs (1, 2) grep the repo for the removed machinery.
#
# Written BEFORE implementation: expect failures for missing behaviour (no gate exists yet; the
# throttle machinery is still present).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

cat > "$TMP/stubs/bd" <<'STUB'
#!/usr/bin/env bash
echo "bd $*" >> "$W/bdlog"
if [ "${BD_FAIL_ENGINEER:-0}" = 1 ]; then
  case "$*" in *role:engineer*) echo "bd: simulated failure" >&2; exit 1 ;; esac
fi
case "$1" in
  ready|list)
    label=""; args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      [ "${args[$i]}" = "--label" ] && label="${args[$((i + 1))]}"
    done
    if [ -n "$label" ]; then
      jq -c --arg l "$label" '[.[] | select((.labels // []) | index($l))]' "$W/issues.json"
    else
      cat "$W/issues.json"
    fi ;;
  count)
    jq -c '{count: ([.[] | select((.labels // []) | index("role:engineer"))] | length)}' "$W/issues.json" ;;
  show)
    jq -c --arg id "$2" '[.[] | select(.id == $id)]' "$W/issues.json" ;;
  *) ;;
esac
exit 0
STUB
chmod +x "$TMP/stubs/bd"

cat > "$TMP/stubs/claude" <<'STUB'
#!/usr/bin/env bash
echo x >> "$W/claude_runs"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0}'
touch "$W/data/control/STOP"
exit 0
STUB
chmod +x "$TMP/stubs/claude"

ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN" && git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# mk_issues N_ENGINEER [FILE]: a po request plus N ready role:engineer issues.
mk_issues() {
  local n=$1 out=${2:-$TMP/issues.json}
  jq -nc --argjson n "$n" '
    [{"id":"req-1","status":"open","assignee":"","labels":["role:po","stage:intake"]}]
    + [range(0;$n) | {"id":("eng-\(.)"),"status":"open","assignee":"","labels":["role:engineer","stage:implement"]}]' > "$out"
}

# start_loop ROLE FIXTURE [VAR=VAL...]: starts bin/agent-loop.sh in the background; sets W, PID.
start_loop() {
  local role=$1 fixture=$2; shift 2
  W="$(mktemp -d "$TMP/run.XXXXXX")"; mkdir -p "$W/data/control" "$W/home"; : > "$W/bdlog"; : > "$W/claude_runs"
  cp "$fixture" "$W/issues.json"
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home"
    unset MAX_READY_ENGINEER_ISSUES
    for kv in "$@"; do export "${kv?}"; done
    PATH="$TMP/stubs:$PATH" ROLE=$role KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 IDLE_SLEEP=1 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 \
      exec timeout 12 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) &
  PID=$!
}
stop_loop() { touch "$W/data/control/STOP"; wait "$PID" 2>/dev/null; }
# run_loop ROLE FIXTURE SECS [VAR=VAL...]: run for SECS seconds (or until the stub claude stops it).
run_loop() {
  local role=$1 fixture=$2 secs=$3; shift 3
  start_loop "$role" "$fixture" "$@"
  local i; for ((i = 0; i < secs * 2; i++)); do kill -0 "$PID" 2>/dev/null || break; sleep 0.5; done
  stop_loop
}
po_ran() { [ -s "$W/claude_runs" ]; }
po_claimed() { grep -qE 'bd update req-1 --claim' "$W/bdlog"; }

# ============================================================
# AC1 - team-lead never starts a throttle-assessment session; team-lead.md no longer describes one.
# ============================================================
test_ac1_team_lead_idle_queue_starts_no_throttle_session() {
  echo '[]' > "$TMP/empty.json"
  run_loop team-lead "$TMP/empty.json" 4
  if po_ran; then fail "ac1: team-lead ran a claude session with an empty queue (throttle assessment). out:$(tail -5 "$W/out")"; return; fi
  grep -qi 'throttle assessment' "$W/out" && { fail "ac1: loop still logs a throttle assessment: $(grep -i 'throttle assessment' "$W/out" | head -2)"; return; }
  pass "ac1: team-lead with an empty queue starts no session and logs no throttle assessment"
}
test_ac1_team_lead_md_has_no_throttle_assessment() {
  if grep -qiE 'throttle|set-throttle|THROTTLE_STALE' agents/team-lead.md; then
    fail "ac1: agents/team-lead.md still mentions throttling: $(grep -niE 'throttle' agents/team-lead.md | head -3)"
  else
    pass "ac1: agents/team-lead.md no longer describes or requests a throttle assessment"
  fi
}

# ============================================================
# AC2 - old throttle machinery removed; docs no longer describe team-lead throttling.
# ============================================================
test_ac2_old_machinery_gone() {
  local bad=""
  [ -e bin/set-throttle.sh ] && bad="$bad bin/set-throttle.sh-exists"
  grep -q 'THROTTLE_STALE_SECS\|THROTTLE_ALERT_STALE_SECS' bin/agent-loop.sh .env.example docker-compose.yml 2>/dev/null && bad="$bad THROTTLE_*_SECS-still-referenced"
  grep -qi 'throttle assessment stale\|throttle_stale_alert\|run_throttle_assessment\|throttle_ok' bin/agent-loop.sh && bad="$bad loop-throttle-functions/alert"
  grep -q -- '-- throttle' bin/board.sh && bad="$bad board-throttle-section"
  [ -z "$bad" ] && pass "ac2: set-throttle.sh, THROTTLE_* settings, stale alert and board section are gone" || fail "ac2: leftover:$bad"
}
test_ac2_docs_do_not_describe_team_lead_throttling() {
  local hits
  hits=$(grep -niE 'throttle' README.md docs/ARCHITECTURE.md .env.example | grep -viE 'MAX_READY_ENGINEER|\bpo\b.*(gate|throttl)|budget|quota|usage' | head -5)
  [ -z "$hits" ] && pass "ac2: README/ARCHITECTURE/.env.example no longer describe team-lead throttling" \
    || fail "ac2: docs still mention throttling: $hits"
}
test_ac2_env_example_documents_new_setting() {
  grep -q 'MAX_READY_ENGINEER_ISSUES' .env.example && pass "ac2/6: .env.example documents MAX_READY_ENGINEER_ISSUES" \
    || fail "ac2/6: .env.example does not mention MAX_READY_ENGINEER_ISSUES"
}

# ============================================================
# AC3 - ready role:engineer count >= N: PO does not claim, and logs once (count + limit).
# ============================================================
test_ac3_po_idles_when_queue_full_and_logs_once() {
  mk_issues 4
  run_loop po "$TMP/issues.json" 5 MAX_READY_ENGINEER_ISSUES=3
  if po_claimed || po_ran; then fail "ac3: PO claimed/ran work with 4 ready engineer issues and limit 3"; return; fi
  local n; n=$(grep -ciE 'queue.*full|full.*queue' "$W/out")
  [ "$n" = 1 ] || { fail "ac3: expected exactly one 'engineering queue is full' log line, got $n. out:$(tail -8 "$W/out")"; return; }
  grep -iE 'queue.*full|full.*queue' "$W/out" | grep -q '4' && grep -iE 'queue.*full|full.*queue' "$W/out" | grep -q '3' \
    && pass "ac3: PO idles at count>=limit and logs once with count (4) and limit (3)" \
    || fail "ac3: idle log line lacks count 4 / limit 3: $(grep -iE 'queue.*full' "$W/out")"
}
test_ac3_boundary_count_equals_limit_idles() {
  mk_issues 3
  run_loop po "$TMP/issues.json" 4 MAX_READY_ENGINEER_ISSUES=3
  po_claimed && fail "ac3: PO claimed with count == limit (3 >= 3 must idle)" || pass "ac3: count == limit holds PO back"
}

# ============================================================
# AC4 - below limit: PO works as normal.
# ============================================================
test_ac4_po_claims_when_below_limit() {
  mk_issues 2
  run_loop po "$TMP/issues.json" 8 MAX_READY_ENGINEER_ISSUES=3
  po_claimed && pass "ac4: PO claims the request with 2 ready engineer issues and limit 3" \
    || fail "ac4: PO did not claim. out:$(tail -8 "$W/out")"
}

# ============================================================
# AC5 - resumes without restart once the count drops.
# ============================================================
test_ac5_po_resumes_when_count_drops() {
  mk_issues 4
  start_loop po "$TMP/issues.json" MAX_READY_ENGINEER_ISSUES=3
  sleep 3
  if po_claimed; then stop_loop; fail "ac5: PO claimed while queue was full"; return; fi
  mk_issues 1 "$W/issues.json"
  local i; for ((i = 0; i < 16; i++)); do po_claimed && break; sleep 0.5; done
  local ok=0; po_claimed && ok=1
  stop_loop
  [ $ok = 1 ] && pass "ac5: PO resumed in the same process after the count dropped below the limit" \
    || fail "ac5: PO never resumed. out:$(tail -8 "$W/out")"
}

# ============================================================
# AC6 - default 5; 0 or empty = no limit.
# ============================================================
test_ac6_default_limit_is_5() {
  mk_issues 5
  run_loop po "$TMP/issues.json" 4
  po_claimed && { fail "ac6: unset setting did not default to 5 (PO claimed with 5 ready)"; return; }
  mk_issues 4
  run_loop po "$TMP/issues.json" 8
  po_claimed && pass "ac6: unset => limit 5 (5 ready idles, 4 ready proceeds)" || fail "ac6: PO idled with 4 ready under default limit. out:$(tail -5 "$W/out")"
}
test_ac6_zero_means_no_limit() {
  mk_issues 20
  run_loop po "$TMP/issues.json" 8 MAX_READY_ENGINEER_ISSUES=0
  po_claimed && pass "ac6: MAX_READY_ENGINEER_ISSUES=0 never holds PO back" || fail "ac6: PO held back with limit 0. out:$(tail -5 "$W/out")"
}
test_ac6_empty_means_no_limit() {
  mk_issues 20
  run_loop po "$TMP/issues.json" 8 MAX_READY_ENGINEER_ISSUES=
  po_claimed && pass "ac6: empty MAX_READY_ENGINEER_ISSUES never holds PO back" || fail "ac6: PO held back with empty limit. out:$(tail -5 "$W/out")"
}

# ============================================================
# AC7 - fails open when the count cannot be determined.
# ============================================================
test_ac7_po_proceeds_when_count_unavailable() {
  mk_issues 20
  run_loop po "$TMP/issues.json" 8 MAX_READY_ENGINEER_ISSUES=3 BD_FAIL_ENGINEER=1
  po_claimed && pass "ac7: PO proceeds when the engineer-count query fails" || fail "ac7: PO stalled when count unavailable. out:$(tail -5 "$W/out")"
}

# ============================================================
# AC8 - no other role is gated.
# ============================================================
test_ac8_other_roles_not_held_back() {
  local role fixture bad=""
  for role in architect engineer qa reviewer; do
    jq -nc --arg r "role:$role" '[{"id":"w-1","status":"open","assignee":"","labels":[$r]}]
      + [range(0;10) | {"id":("eng-\(.)"),"status":"open","assignee":"","labels":["role:engineer"]}]' > "$TMP/o_$role.json"
    run_loop "$role" "$TMP/o_$role.json" 8 MAX_READY_ENGINEER_ISSUES=1
    grep -qE 'bd update (w|eng)-[0-9]+ --claim' "$W/bdlog" || bad="$bad $role"
  done
  [ -z "$bad" ] && pass "ac8: architect/engineer/qa/reviewer claim work despite a full engineer queue" || fail "ac8: held back:$bad"
}
test_ac8_team_lead_not_held_back() {
  jq -nc '[{"id":"t-1","status":"open","assignee":"","labels":["needs-team-lead","role:qa"]}]
    + [range(0;10) | {"id":("eng-\(.)"),"status":"open","assignee":"","labels":["role:engineer"]}]' > "$TMP/tl.json"
  run_loop team-lead "$TMP/tl.json" 8 MAX_READY_ENGINEER_ISSUES=1
  grep -qE 'bd update t-1 --claim' "$W/bdlog" && pass "ac8: team-lead claims triage work despite a full engineer queue" || fail "ac8: team-lead held back"
}

# ============================================================
# AC9 - idle state with count/limit is visible (agent log, or board).
# ============================================================
test_ac9_idle_state_visible_in_log() {
  mk_issues 7
  run_loop po "$TMP/issues.json" 4 MAX_READY_ENGINEER_ISSUES=6
  local line; line=$(grep -iE 'idle|queue.*full' "$W/out" | grep -E '7' | grep -E '6' | head -1)
  [ -n "$line" ] && [ -s "$W/data/logs/po/loop.log" ] && grep -q "$(echo "$line" | cut -c30-60)" "$W/data/logs/po/loop.log" \
    && pass "ac9: idle state with count (7) and limit (6) is in the po loop log" \
    || fail "ac9: no idle line with count 7 / limit 6 in log. out:$(tail -5 "$W/out")"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo; echo "hr7o: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
