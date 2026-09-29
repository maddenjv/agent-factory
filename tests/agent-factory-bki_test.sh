#!/usr/bin/env bash
# Acceptance tests for agent-factory-bki: select the harness (Claude Code vs GitHub Copilot CLI)
# every role runs via a command-line flag on bin/init.sh, persisted into .env.
#
# Written BEFORE implementation (write-tests stage) and BEFORE docs/design/agent-factory-bki.md
# exists, per docs/stories/agent-factory-bki.md's Context: the architect owns the exact flag
# name/spelling, the .env variable name, and the GitHub Copilot CLI invocation details - this story
# only specifies observable behaviour. So these tests anchor only on the tokens the story itself
# guarantees regardless of that naming - the literal word "copilot" wherever the new harness is
# selected/persisted/read/invoked, "harness" as the general concept, and "claude" as the pre-
# existing default/comparison point - using flexible regex rather than exact flag syntax, so a
# reasonable design choice doesn't spuriously fail these.
#
# Confirmed to fail right now for the correct reason: grepping bin/, Dockerfile,
# docker-compose.yml, .env.example and docs/ARCHITECTURE.md for "harness|copilot"
# (case-insensitive) turns up nothing - none of AC1-AC7's behaviour exists yet.
#
# Mechanism tests exercising the real flag/invocation end-to-end (once the design fixes their
# exact spelling) belong to the stage:verify issue for this story, the same split
# tests/agent-factory-q4tj_test.sh used between its write-tests-stage content checks and its
# verify-stage mechanism tests.
#
# Run directly: bash tests/agent-factory-bki_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"

pass=0; fail=0; skip=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
skp() { echo "SKIP: $1"; skip=$((skip+1)); }

have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
dc() { docker compose -f "$KIT_DIR/docker-compose.yml" "$@"; }

INIT="bin/init.sh"; LOOP="bin/agent-loop.sh"; LIB="bin/lib.sh"; ENVEX=".env.example"

# ============================================================
# AC1 - no flag -> Claude Code (today's default), no flag required to keep working as before.
# ============================================================
test_ac1_default_is_claude_code_no_flag_required() {
  if ! grep -qiE 'harness' "$INIT" "$LIB" 2>/dev/null; then
    bad "ac1: neither bin/init.sh nor bin/lib.sh mentions a harness concept at all - no default-harness selection exists yet"
    return
  fi
  # The default must be Claude Code and must not require the flag to be passed - look for a
  # fallback-style assignment (VAR="${VAR:-...claude...}") or equivalent "default...claude" wording
  # near the harness logic, not just the word "claude" occurring incidentally elsewhere (e.g. the
  # pre-existing CLAUDE_CODE_OAUTH_TOKEN block).
  local near
  near=$(grep -iB2 -A2 -E 'harness' "$INIT" "$LIB" 2>/dev/null)
  echo "$near" | grep -qiE '\$\{[A-Z_]*HARNESS[A-Z_]*:-[^}]*claude|default[^.]{0,40}claude|claude[^.]{0,40}default' \
    || { bad "ac1: harness logic in bin/init.sh/bin/lib.sh doesn't default to Claude Code when no flag is given"; return; }
  ok "ac1: bin/init.sh/bin/lib.sh default the harness to Claude Code when no flag is passed"
}

# ============================================================
# AC2 - flag selecting GitHub Copilot CLI -> persisted into .env, used by later start.sh/
# agent-loop.sh runs without repeating the flag.
# ============================================================
test_ac2_copilot_choice_persisted_to_env_and_reused() {
  if ! grep -qi 'copilot' "$INIT"; then
    bad "ac2: bin/init.sh has no GitHub Copilot CLI flag/handling at all"
    return
  fi
  if ! grep -qiE '>>\s*"?\$AGENT_ENV_FILE"?' "$INIT" || \
     ! grep -iB5 -A5 -E '>>\s*"?\$AGENT_ENV_FILE"?' "$INIT" | grep -qiE 'harness'; then
    bad "ac2: bin/init.sh doesn't persist the harness choice into \$AGENT_ENV_FILE (no append near a harness-named variable, unlike the existing HOST_UID/HOST_GID/HOST_USER/CONTAINER_HOME pattern)"
    return
  fi
  grep -qiE 'harness' "$ENVEX" 2>/dev/null \
    || { bad "ac2: .env.example doesn't document a harness-selection variable"; return; }
  grep -qiE 'harness' "$LOOP" \
    || { bad "ac2: bin/agent-loop.sh never reads a harness variable back out - later start.sh/agent-loop.sh runs couldn't pick up the persisted choice"; return; }
  ok "ac2: bin/init.sh persists a harness choice into \$AGENT_ENV_FILE, .env.example documents it, and bin/agent-loop.sh reads it back"
}

# ============================================================
# AC3 - configured for Copilot -> agent-loop.sh invokes the Copilot CLI (not claude), feeding it
# the same agents/<role>.md prompt content Claude Code sessions get today.
# ============================================================
test_ac3_agent_loop_invokes_copilot_with_same_role_prompt() {
  if ! grep -qi 'copilot' "$LOOP"; then
    bad "ac3: bin/agent-loop.sh never invokes a Copilot CLI - only claude is ever run"
    return
  fi
  local near
  near=$(grep -iB15 -A15 -E 'copilot' "$LOOP")
  echo "$near" | grep -qE 'build_prompt|\$prompt\b' \
    || { bad "ac3: bin/agent-loop.sh's Copilot invocation isn't wired to build_prompt()/\$prompt - it wouldn't receive the same agents/<role>.md content Claude Code sessions get"; return; }
  ok "ac3: bin/agent-loop.sh invokes a Copilot CLI, fed from the same build_prompt()/\$prompt (agents/<role>.md) Claude Code sessions use"
}

# ============================================================
# AC4 - Copilot configured -> agent image build installs the GitHub Copilot CLI, usable inside
# the image (docker compose build agent succeeds; the CLI runs inside a container).
# ============================================================
test_ac4_dockerfile_installs_copilot_cli() {
  if ! grep -qi 'copilot' Dockerfile; then
    bad "ac4: Dockerfile does not install a GitHub Copilot CLI"
    return
  fi
  if ! have_docker; then
    skp "ac4: docker unavailable in this environment - Dockerfile mentions copilot, build/run unverified"
    return
  fi
  if ! dc build agent; then
    bad "ac4: docker compose build agent failed"
    return
  fi
  local out
  out=$(dc run --rm --entrypoint bash agent -lc 'command -v copilot || command -v gh' 2>&1)
  if [ -z "$out" ]; then
    bad "ac4: no copilot-ish binary found on PATH inside the built image: $out"
  else
    ok "ac4: docker compose build agent succeeded and a Copilot-CLI-ish binary is on PATH inside the image ($out)"
  fi
}

# ============================================================
# AC5 - either harness: tmux pane still shows readable progress, a cost/usage figure is still
# recorded under $CONTROL/cost/<role>.<date> (or documented equivalent), and a usage-limit/quota
# condition is still detected and handled the same way run_claude_session() handles one today.
# ============================================================
test_ac5_cost_and_quota_handling_preserved_for_copilot() {
  if ! grep -qi 'copilot' "$LOOP"; then
    bad "ac5: bin/agent-loop.sh has no Copilot branch to check cost/quota handling for"
    return
  fi
  local near
  near=$(grep -iB25 -A25 -E 'copilot' "$LOOP")
  echo "$near" | grep -qE 'CONTROL/cost|cost/\$ROLE|cost[^.]{0,20}\$\(date' \
    || { bad "ac5: bin/agent-loop.sh's Copilot path doesn't appear to record a cost/usage figure under \$CONTROL/cost/<role>.<date> (or a documented equivalent)"; return; }
  echo "$near" | grep -qiE 'quota|usage.limit|LAST_RUN_QUOTA_MSG' \
    || { bad "ac5: bin/agent-loop.sh's Copilot path doesn't detect/handle a usage-limit/quota condition the way run_claude_session() does for Claude Code today"; return; }
  ok "ac5: bin/agent-loop.sh's Copilot path still records cost under \$CONTROL/cost/<role>.<date> and detects/handles usage-limit/quota conditions"
}

# ============================================================
# AC6 - unrecognized harness flag value -> bin/init.sh fails with an error naming the accepted
# values, and does not silently fall back to a default or half-configure the project.
# ============================================================
test_ac6_unrecognized_harness_value_rejected() {
  if ! grep -qiE 'harness' "$INIT"; then
    bad "ac6: bin/init.sh has no harness flag to validate at all"
    return
  fi
  local near
  near=$(grep -iB5 -A10 -E 'harness' "$INIT")
  echo "$near" | grep -qiE 'unrecognized|invalid|unknown[^.]{0,20}(harness|value)|error' \
    || { bad "ac6: bin/init.sh's harness handling has no visible validation/error path for an unrecognized value"; return; }
  if ! (echo "$near" | grep -qi 'claude' && echo "$near" | grep -qi 'copilot'); then
    bad "ac6: bin/init.sh's harness error path doesn't appear to name both accepted values (claude, copilot)"
    return
  fi
  echo "$near" | grep -qE 'exit [1-9]' \
    || { bad "ac6: bin/init.sh's harness validation doesn't appear to exit non-zero on an unrecognized value"; return; }
  ok "ac6: bin/init.sh rejects an unrecognized harness value with an error naming the accepted values and a non-zero exit"
}

# ============================================================
# AC7 - Copilot configured -> agent-loop.sh's preflight check uses Copilot's equivalent
# invocation, and still alerts the operator the same way on failure.
# ============================================================
test_ac7_preflight_uses_copilot_equivalent_and_still_alerts() {
  local preflight_block
  preflight_block=$(sed -n '/if \[ "\$PREFLIGHT" = 1 \]; then/,/^fi$/p' "$LOOP")
  if [ -z "$preflight_block" ]; then
    bad "ac7: could not locate the 'if [ \"\$PREFLIGHT\" = 1 ]; then ... fi' preflight block in bin/agent-loop.sh"
    return
  fi
  if ! echo "$preflight_block" | grep -qi 'copilot'; then
    bad "ac7: bin/agent-loop.sh's preflight block has no Copilot-specific invocation - it would still only run 'claude -p ...' even when Copilot is configured"
    return
  fi
  echo "$preflight_block" | grep -q 'alert "preflight' \
    || { bad "ac7: bin/agent-loop.sh's preflight block no longer calls alert \"preflight: ...\" on failure once Copilot handling was added"; return; }
  ok "ac7: bin/agent-loop.sh's preflight check has a Copilot-specific invocation and still alerts the operator on failure"
}

test_ac1_default_is_claude_code_no_flag_required
test_ac2_copilot_choice_persisted_to_env_and_reused
test_ac3_agent_loop_invokes_copilot_with_same_role_prompt
test_ac4_dockerfile_installs_copilot_cli
test_ac5_cost_and_quota_handling_preserved_for_copilot
test_ac6_unrecognized_harness_value_rejected
test_ac7_preflight_uses_copilot_equivalent_and_still_alerts

echo "---"
echo "pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
