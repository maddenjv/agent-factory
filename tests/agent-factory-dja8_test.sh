#!/usr/bin/env bash
# Acceptance tests for agent-factory-dja8: with SYSTEM1_ENABLED the team lead's startup log line
# ("started: role=team-lead harness=... model=...") must not claim the capable-model tier ("opus"),
# because in System 1 mode no harness session is used. The story has one vague criterion; the testable
# readings (from Context) are named test_ac1_...
# Harness: the REAL bin/agent-loop.sh with stub bd/claude, STOP pre-set so it exits right after the log line.
set -uo pipefail
unset SYSTEM1_ENABLED SYSTEM1_LOCAL SYSTEM1_URL SYSTEM1_MODEL SYSTEM1_API_KEY SYSTEM1_TIMEOUT MODEL_TEAM_LEAD TIER_TEAM_LEAD
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"
printf '#!/usr/bin/env bash\necho "[]"\nexit 0\n' > "$TMP/stubs/bd"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/stubs/claude"
chmod +x "$TMP/stubs/"*
ORIGIN="$TMP/origin"; git init -q -b main "$ORIGIN"
git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# started_line [env assignments...] -> prints the "started:" log line of a team-lead loop start
started_line() {
  local W; W="$(mktemp -d "$TMP/run.XXXXXX")"; mkdir -p "$W/data/control" "$W/home"
  touch "$W/data/control/STOP"
  ( export HOME="$W/home" CONTAINER_HOME="$W/home" "$@"
    PATH="$TMP/stubs:$PATH" ROLE=team-lead KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 IDLE_SLEEP=1 timeout 40 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 )
  grep -h 'started: role=' "$W/out" "$W/data/logs/team-lead/loop.log" 2>/dev/null | head -n 1
}

test_ac1_system1_start_line_does_not_claim_opus() {
  local l; l=$(started_line SYSTEM1_ENABLED=1 SYSTEM1_URL=http://127.0.0.1:1 SYSTEM1_MODEL=fake/s1-model-dja8)
  [ -n "$l" ] || { fail "ac1: no 'started:' line logged"; return; }
  case "$l" in *model=opus*) fail "ac1: System 1 start line still says model=opus: $l";; *) pass "ac1: System 1 start line does not claim opus";; esac
}
test_ac1_system1_start_line_names_system1_model() {
  local l; l=$(started_line SYSTEM1_ENABLED=1 SYSTEM1_URL=http://127.0.0.1:1 SYSTEM1_MODEL=fake/s1-model-dja8)
  case "$l" in *fake/s1-model-dja8*) pass "ac1: start line reports the configured System 1 model";; *) fail "ac1: start line lacks the System 1 model: $l";; esac
}
test_ac1_system1_default_model_not_opus() {
  local l; l=$(started_line SYSTEM1_ENABLED=1 SYSTEM1_URL=http://127.0.0.1:1)
  [ -n "$l" ] || { fail "ac1: no 'started:' line logged"; return; }
  case "$l" in *model=opus*) fail "ac1: default System 1 start line says model=opus: $l";; *) pass "ac1: default System 1 start line does not claim opus";; esac
}
test_ac1_system1_ignores_tier_override() {
  local l; l=$(started_line SYSTEM1_ENABLED=1 SYSTEM1_URL=http://127.0.0.1:1 SYSTEM1_MODEL=fake/s1-model-dja8 TIER_TEAM_LEAD=tier-marker-dja8)
  case "$l" in *tier-marker-dja8*) fail "ac1: System 1 start line shows the harness tier model: $l";; *) pass "ac1: System 1 start line independent of harness tier";; esac
}
# Regression guards: the non-System-1 behaviour must be unchanged.
test_ac1_flag_off_still_reports_tier_model() {
  local l; l=$(started_line)
  case "$l" in *model=opus*) pass "ac1: flag off -> team-lead start line still model=opus";; *) fail "ac1: flag off start line lost model=opus: $l";; esac
}
test_ac1_flag_off_pinned_model_reported() {
  local l; l=$(started_line MODEL_TEAM_LEAD=pin-marker-dja8)
  case "$l" in *model=pin-marker-dja8*) pass "ac1: flag off, MODEL_TEAM_LEAD pin still reported";; *) fail "ac1: pinned model missing: $l";; esac
}
test_ac1_other_roles_unaffected_by_flag() {
  local W l; W="$(mktemp -d "$TMP/run.XXXXXX")"; mkdir -p "$W/data/control" "$W/home"; touch "$W/data/control/STOP"
  ( export HOME="$W/home" CONTAINER_HOME="$W/home" SYSTEM1_ENABLED=1 SYSTEM1_URL=http://127.0.0.1:1
    PATH="$TMP/stubs:$PATH" ROLE=qa KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 IDLE_SLEEP=1 timeout 40 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 )
  l=$(grep -h 'started: role=' "$W/out" | head -n 1)
  case "$l" in *"role=qa"*model=sonnet*) pass "ac1: qa role start line unaffected (model=sonnet)";; *) fail "ac1: qa start line changed: $l";; esac
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
