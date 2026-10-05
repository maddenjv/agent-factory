#!/usr/bin/env bash
# Acceptance tests for agent-factory-8j3y: "Copilot agents can run kit scripts outside their workspace".
# One or more tests per acceptance criterion in docs/stories/agent-factory-8j3y.md (test_acN_...).
# Written from the story ONLY (not docs/design/agent-factory-8j3y.md).
#
# Method: run the real bin/agent-loop.sh against stub `bd`, `copilot` and `claude` binaries that
# record how they were invoked (argv, cwd). The real Copilot sandbox can't be exercised offline, so
# "kit paths accessible" is judged from the invocation: Copilot CLI grants path access via
# --add-dir <dir> (must name $KIT_DIR, or a parent of it) or --allow-all-paths / --allow-all / --yolo.
#
# Run directly: bash tests/agent-factory-8j3y_test.sh
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
case "$1" in
  ready|list) cat "$W/issues.json" ;;
  show) jq -c --arg id "$2" '[.[] | select(.id == $id)]' "$W/issues.json" ;;
esac
exit 0
STUB

# Stub harness CLI: logs argv (one per line, blank-line separated per call) and cwd.
# Preflight calls (prompt "Reply with the single word OK.") are logged separately.
# Optional $W/preflight_fail_once: first preflight prints a quota message and exits 1.
for h in copilot claude; do
cat > "$TMP/stubs/$h" <<STUB
#!/usr/bin/env bash
name=$h
if [ "\$2" = "Reply with the single word OK." ]; then log="\$W/preflight_calls"; else log="\$W/session_calls"; fi
{ echo "== \$name cwd=\$(pwd -P)"; printf 'ARG:%s\n' "\$@"; } >> "\$log"
if [ "\$log" = "\$W/preflight_calls" ] && [ -f "\$W/preflight_fail_once" ]; then
  rm -f "\$W/preflight_fail_once"; echo "quota_exceeded" >&2; exit 1
fi
if [ "\$log" = "\$W/session_calls" ]; then touch "\$W/data/control/STOP"; fi
[ "\$name" = claude ] && echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0}'
echo OK
exit 0
STUB
chmod +x "$TMP/stubs/$h"
done
chmod +x "$TMP/stubs/bd"

ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN" && git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# run_loop ROLE HARNESS [VAR=VAL...]  -> sets W, RC. One ready issue for qa; none for team-lead
# (so team-lead goes straight to its throttle-assessment session).
run_loop() {
  local role=$1 harness=$2; shift 2
  W="$TMP/run.$RANDOM"; mkdir -p "$W/data/control" "$W/home"
  : > "$W/bdlog"; : > "$W/session_calls"; : > "$W/preflight_calls"
  echo '[{"id":"issue-1","status":"open","assignee":"","type":"task","labels":["role:'"$role"'","stage:verify","story:s"]}]' > "$W/issues.json"
  [ "$role" = team-lead ] && echo '[]' > "$W/issues.json"
  RC=0
  ( unset MODEL TIER_TEAM_LEAD TIER_STANDARD MODEL_PO MODEL_ARCHITECT MODEL_ENGINEER MODEL_QA MODEL_REVIEWER MODEL_TEAM_LEAD
    export W HOME="$W/home" CONTAINER_HOME="$W/home"
    export PATH="$TMP/stubs:$PATH" ROLE="$role" HARNESS="$harness" KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" \
      DATA_DIR="$W/data" ORIGIN="$ORIGIN" PREFLIGHT=0 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 \
      IDLE_SLEEP=1 THROTTLE_STALE_SECS=0 QUOTA_RETRY_INTERVAL=1 "$@"
    timeout 60 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
}

# Does the recorded call (file $1) grant access to $KIT_DIR?
grants_kit_access() {
  local f=$1 prev="" a
  grep -qxE 'ARG:(--allow-all-paths|--allow-all|--yolo)' "$f" && return 0
  while IFS= read -r a; do
    a=${a#ARG:}
    if [ "$prev" = "--add-dir" ]; then
      case "$KIT_DIR/" in "${a%/}/"*) return 0 ;; esac
    fi
    case "$a" in --add-dir=*) v=${a#--add-dir=}; case "$KIT_DIR/" in "${v%/}/"*) return 0 ;; esac ;; esac
    prev=$a
  done < "$f"
  return 1
}
has_arg() { grep -qxF -- "ARG:$2" "$1"; }

# ---------------- AC1: team-lead session can run $KIT_DIR/bin scripts ----------------
test_ac1_team_lead_session_granted_kit_dir_access() {
  run_loop team-lead copilot
  if ! grep -q '^== copilot' "$W/session_calls"; then
    fail "ac1: team-lead never started a copilot session. out: $(head -c 600 "$W/out")"; return
  fi
  grants_kit_access "$W/session_calls" \
    && pass "ac1: team-lead copilot session is granted access to \$KIT_DIR (path allow-list or allow-all-paths)" \
    || fail "ac1: team-lead copilot session has no path grant covering \$KIT_DIR=$KIT_DIR; argv: $(grep ARG: "$W/session_calls" | cut -c1-80 | tr '\n' ' ')"
}

# ---------------- AC2: any role can read $KIT_DIR files ----------------
test_ac2_every_role_granted_kit_dir_access() {
  local r bad=""
  for r in po architect engineer qa reviewer team-lead; do
    run_loop "$r" copilot
    grep -q '^== copilot' "$W/session_calls" || { bad="$bad $r(no-session)"; continue; }
    grants_kit_access "$W/session_calls" || bad="$bad $r"
  done
  [ -z "$bad" ] && pass "ac2: all six roles' copilot sessions are granted access to \$KIT_DIR" \
    || fail "ac2: roles without \$KIT_DIR access under copilot:$bad"
}

# ---------------- AC3: still non-interactive, in own clone, model/timeout unchanged ----------------
test_ac3_copilot_session_stays_noninteractive_in_clone() {
  run_loop qa copilot
  local f="$W/session_calls"
  grep -q '^== copilot' "$f" || { fail "ac3: no copilot session ran. out: $(head -c 600 "$W/out")"; return; }
  local miss=""
  has_arg "$f" -p || miss="$miss -p"
  has_arg "$f" --no-ask-user || miss="$miss --no-ask-user"
  has_arg "$f" -s || miss="$miss -s"
  { has_arg "$f" --allow-all-tools || has_arg "$f" --allow-all || has_arg "$f" --yolo; } || miss="$miss tool-approval"
  [ -z "$miss" ] || { fail "ac3: copilot argv lost non-interactive flags:$miss"; return; }
  local cwd; cwd=$(sed -n 's/^== copilot cwd=//p' "$f" | head -1)
  case "$cwd" in
    */repo|*/clone|"$W"/*) pass "ac3: copilot runs in its own clone ($cwd), non-interactive flags kept" ;;
    *) fail "ac3: unexpected cwd '$cwd' (expected the agent's clone under \$PROJECT_DIR=$W)" ;;
  esac
  [ "$cwd" != "$KIT_DIR" ] || fail "ac3: copilot cwd is KIT_DIR, not the agent's clone"
}

test_ac3_copilot_model_and_prompt_still_passed() {
  run_loop qa copilot MODEL_QA=gpt-test-model
  local f="$W/session_calls"
  grep -qxF -- 'ARG:--model' "$f" && grep -qxF -- 'ARG:gpt-test-model' "$f" \
    && pass "ac3: --model <MODEL_QA> still passed to copilot" \
    || fail "ac3: --model gpt-test-model missing from copilot argv"
  grep -q 'Your assigned issue: issue-1' "$f" \
    && pass "ac3: prompt (with assigned issue) still passed to copilot" \
    || fail "ac3: prompt with assigned issue not found in copilot argv"
  run_loop qa copilot
  grep -qxF -- 'ARG:--model' "$W/session_calls" \
    && fail "ac3: --model passed although no model configured (copilot default expected)" \
    || pass "ac3: no --model when none configured (copilot's own default)"
}

test_ac3_copilot_timeout_still_enforced() {
  # A hung copilot (stub sleeps 30s) must be killed by ITERATION_TIMEOUT=2.
  local start end
  mv "$TMP/stubs/copilot" "$TMP/stubs/copilot.orig"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$TMP/stubs/copilot"; chmod +x "$TMP/stubs/copilot"
  start=$(date +%s)
  run_loop qa copilot ITERATION_TIMEOUT=2 MAX_ATTEMPTS_PER_ISSUE=1
  end=$(date +%s)
  mv "$TMP/stubs/copilot.orig" "$TMP/stubs/copilot"
  if [ $((end - start)) -lt 25 ]; then
    pass "ac3: hung copilot session is cut off by ITERATION_TIMEOUT"
  else
    fail "ac3: hung copilot session not terminated by ITERATION_TIMEOUT=2 (took $((end - start))s)"
  fi
}

# ---------------- AC4: claude-code invocation unchanged ----------------
test_ac4_claude_code_invocation_unchanged() {
  run_loop qa claude-code MODEL_QA=sonnet MAX_TURNS=7
  local f="$W/session_calls"
  grep -q '^== claude' "$f" || { fail "ac4: no claude session ran. out: $(head -c 600 "$W/out")"; return; }
  local args; args=$(grep '^ARG:' "$f" | sed 's/^ARG://' | awk 'NR==1{print "<prompt>"; next} {print}' | tr '\n' ' ')
  local expect="<prompt> --dangerously-skip-permissions --max-turns 7 --output-format stream-json --verbose --model sonnet "
  # prompt may be multi-line, so compare from the first flag onward
  local tail_args; tail_args=$(printf '%s' "$args" | sed 's/^.*--dangerously-skip-permissions/--dangerously-skip-permissions/')
  [ "$tail_args" = "${expect#<prompt> }" ] \
    && pass "ac4: claude argv unchanged: $tail_args" \
    || fail "ac4: claude argv changed. got: '$tail_args' want: '${expect#<prompt> }'"
  grep -qE 'ARG:--(add-dir|allow-all|yolo|allow-all-paths|no-ask-user)' "$f" \
    && fail "ac4: copilot-only flags leaked into the claude invocation" \
    || pass "ac4: no copilot-only flags in the claude invocation"
  local cwd; cwd=$(sed -n 's/^== claude cwd=//p' "$f" | head -1)
  [ "$cwd" != "$KIT_DIR" ] && pass "ac4: claude still runs in the agent's clone" || fail "ac4: claude cwd changed to KIT_DIR"
}

test_ac4_claude_code_preflight_unchanged() {
  run_loop qa claude-code PREFLIGHT=1
  local f="$W/preflight_calls"
  grep -q '^== claude' "$f" || { fail "ac4: claude preflight did not run. out: $(head -c 600 "$W/out")"; return; }
  grep -qxF -- 'ARG:--dangerously-skip-permissions' "$f" && grep -qxF -- 'ARG:--max-turns' "$f" \
    && ! grep -qE 'ARG:--(add-dir|allow-all|yolo|allow-all-paths)' "$f" \
    && pass "ac4: claude preflight invocation unchanged" || fail "ac4: claude preflight invocation changed"
}

# ---------------- AC5: copilot preflight still works, quota handling unchanged ----------------
test_ac5_copilot_preflight_succeeds() {
  run_loop qa copilot PREFLIGHT=1
  local f="$W/preflight_calls"
  grep -q '^== copilot' "$f" || { fail "ac5: copilot preflight never ran. out: $(head -c 600 "$W/out")"; return; }
  grep -q 'preflight:' "$W/data/control/alerts.log" 2>/dev/null \
    && fail "ac5: preflight raised an alert: $(cat "$W/data/control/alerts.log")" \
    || pass "ac5: copilot preflight ran with no alert"
  grep -q '^== copilot' "$W/session_calls" \
    && pass "ac5: loop proceeds to its session after preflight" \
    || fail "ac5: loop did not reach a session after a successful preflight. out: $(head -c 600 "$W/out")"
  has_arg "$f" --no-ask-user && has_arg "$f" -s \
    && { has_arg "$f" --allow-all-tools || has_arg "$f" --allow-all || has_arg "$f" --yolo; } \
    && pass "ac5: preflight stays non-interactive" || fail "ac5: preflight lost non-interactive flags"
}

test_ac5_copilot_preflight_quota_hit_waits_and_retries() {
  # run_loop recreates W; seed failure flag by pre-creating it via a wrapper run
  W="$TMP/run.quota"; rm -rf "$W"; mkdir -p "$W/data/control" "$W/home"
  : > "$W/bdlog"; : > "$W/session_calls"; : > "$W/preflight_calls"; touch "$W/preflight_fail_once"
  echo '[{"id":"issue-1","status":"open","assignee":"","type":"task","labels":["role:qa","stage:verify","story:s"]}]' > "$W/issues.json"
  RC=0
  ( unset MODEL TIER_TEAM_LEAD TIER_STANDARD MODEL_PO MODEL_ARCHITECT MODEL_ENGINEER MODEL_QA MODEL_REVIEWER MODEL_TEAM_LEAD
    export W HOME="$W/home" CONTAINER_HOME="$W/home"
    export PATH="$TMP/stubs:$PATH" ROLE=qa HARNESS=copilot KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" \
      ORIGIN="$ORIGIN" PREFLIGHT=1 IDLE_SLEEP=1 QUOTA_RETRY_INTERVAL=1
    timeout 60 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
  local n; n=$(grep -c '^== copilot' "$W/preflight_calls")
  if [ "$n" -ge 2 ] && grep -q 'usage limit hit' "$W/data/control/alerts.log" \
     && ! grep -q 'harness failed to run' "$W/data/control/alerts.log"; then
    pass "ac5: preflight quota hit (quota_exceeded) is waited out and retried ($n preflight calls)"
  else
    fail "ac5: quota hit in copilot preflight not handled as before (calls=$n) alerts: $(cat "$W/data/control/alerts.log" 2>/dev/null) out: $(head -c 500 "$W/out")"
  fi
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
