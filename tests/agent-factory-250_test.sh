#!/usr/bin/env bash
# Acceptance tests for agent-factory-250: per-role model tiers, team-lead on the most capable model.
# One function per acceptance criterion in docs/stories/agent-factory-250.md (test_acN_...).
# Each test runs the real bin/agent-loop.sh far enough to hit the "started:" log line and no
# further: a pre-planted control/STOP file makes the loop exit on its very first iteration, right
# after that line is written and before any claude/bd interaction beyond `bd list` in
# release_stale (stubbed). This exercises the real model-resolution code path (bin/agent-loop.sh
# reads MODEL_<ROLE> and falls back to a default) without needing to stub `claude` at all.
# Run directly: bash tests/agent-factory-250_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

cat > "$TMP/stubs/bd" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list) echo '[]' ;;
  ready) echo '[]' ;;
esac
exit 0
STUB
chmod +x "$TMP/stubs/bd"

# Scratch origin with a main branch.
ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN" && git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# run_loop ROLE [MODEL_VAR=VALUE ...]; sets W (workdir) and RC (exit code); log at $W/data/logs/$ROLE/loop.log
run_loop() {
  local role=$1; shift
  W="$TMP/run.$RANDOM"; mkdir -p "$W/data/control" "$W/home"
  touch "$W/data/control/STOP"   # exit on the loop's first iteration, right after the startup log line
  RC=0
  ( export HOME="$W/home" CONTAINER_HOME="$W/home" TZ=UTC
    for kv in "$@"; do export "${kv?}"; done
    PATH="$TMP/stubs:$PATH" ROLE="$role" KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 \
      timeout 30 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
  LOG="$W/data/logs/$role/loop.log"
}
# started_model: the value after "model=" on the startup log line, up to the next space
started_model() { grep -o 'started:.*model=[^ ]*' "$LOG" 2>/dev/null | sed 's/.*model=//'; }

test_ac1_team_lead_defaults_to_most_capable_model() {
  run_loop team-lead
  [ "$RC" -eq 0 ] || { fail "ac1: loop exited $RC, expected clean STOP exit (out: $(cat "$W/out" 2>/dev/null))"; return; }
  local m; m=$(started_model)
  [ -n "$m" ] || { fail "ac1: no model recorded in startup log line"; return; }
  case "$m" in
    *[Oo]pus*) pass "ac1: team-lead with MODEL_TEAM_LEAD unset resolves to the most-capable tier (opus): $m" ;;
    *) fail "ac1: team-lead defaulted to '$m', expected the most-capable (opus) tier" ;;
  esac
}

test_ac2_other_roles_default_to_lower_tier() {
  local role m bad=""
  for role in po architect engineer qa reviewer; do
    run_loop "$role"
    [ "$RC" -eq 0 ] || { fail "ac2($role): loop exited $RC, expected clean STOP exit"; return; }
    m=$(started_model)
    case "$m" in
      *[Ss]onnet*) : ;;
      *) bad="$bad $role=$m" ;;
    esac
  done
  [ -z "$bad" ] || { fail "ac2: role(s) did not default to sonnet tier:$bad"; return; }
  pass "ac2: po/architect/engineer/qa/reviewer with MODEL_<ROLE> unset all resolve to the lower-capability tier (sonnet)"
}

test_ac3_explicit_override_wins_over_tier_default() {
  run_loop qa MODEL_QA=my-explicit-model-x
  local m; m=$(started_model)
  [ "$m" = "my-explicit-model-x" ] \
    && pass "ac3(qa): explicit MODEL_QA overrides the tier default" \
    || fail "ac3(qa): expected model 'my-explicit-model-x', got '$m'"

  run_loop team-lead MODEL_TEAM_LEAD=my-explicit-model-y
  m=$(started_model)
  [ "$m" = "my-explicit-model-y" ] \
    && pass "ac3(team-lead): explicit MODEL_TEAM_LEAD overrides the team-lead tier default" \
    || fail "ac3(team-lead): expected model 'my-explicit-model-y', got '$m'"
}

test_ac4_startup_log_records_actual_model_not_literal_default() {
  local role m bad=""
  for role in team-lead po architect engineer qa reviewer; do
    run_loop "$role"
    m=$(started_model)
    if [ -z "$m" ] || [ "$m" = "default" ]; then bad="$bad $role='$m'"; fi
  done
  run_loop qa MODEL_QA=another-explicit-model
  m=$(started_model)
  [ "$m" = "another-explicit-model" ] || bad="$bad qa-override='$m'"

  [ -z "$bad" ] \
    && pass "ac4: startup log always records a concrete resolved model, never the literal string 'default'" \
    || fail "ac4: startup log did not record a concrete model for:$bad"
}

test_ac5_docs_state_tier_defaults_and_override() {
  local docs="$KIT_DIR/README.md $KIT_DIR/docs/ARCHITECTURE.md"
  local blob; blob=$(cat $docs 2>/dev/null)
  local ok=1 why=""
  echo "$blob" | grep -qi 'team-lead' || { ok=0; why="$why no mention of team-lead;"; }
  echo "$blob" | grep -qi 'opus' || { ok=0; why="$why no mention of opus;"; }
  echo "$blob" | grep -qi 'sonnet' || { ok=0; why="$why no mention of sonnet;"; }
  echo "$blob" | grep -qi 'MODEL_<ROLE>\|MODEL_ROLE\|MODEL_[A-Z_]*' || { ok=0; why="$why no mention of the MODEL_<ROLE> override;"; }
  [ "$ok" = 1 ] \
    && pass "ac5: README/ARCHITECTURE docs state the team-lead vs. other-roles tier defaults and the MODEL_<ROLE> override" \
    || fail "ac5: docs incomplete:$why"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
