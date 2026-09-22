#!/usr/bin/env bash
# Acceptance tests for agent-factory-9l0: "Use the invoking user's identity in agent containers".
# No test framework is used elsewhere in this repo (infra/orchestration kit, see
# docs/design/agent-factory-9l0.md's "Test strategy" section) so these are plain shell
# assertions, one function per acceptance criterion in docs/stories/agent-factory-9l0.md.
#
# Run directly: bash tests/agent-factory-9l0_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# Lines matching /home/john or a bare `john` outside of a `${CONTAINER_HOME:-...}` (or
# `"${CONTAINER_HOME:-...}"`) fallback expression are exactly the "hardcoded" occurrences AC2/
# AC3/AC5 are about; see docs/design/agent-factory-9l0.md's QA note under criterion 5.
non_fallback_john_hits() {
  grep -n 'john' "$@" 2>/dev/null | grep -v 'CONTAINER_HOME' || true
}

# --- AC2: docker-compose.yml's agent service volumes don't hardcode /home/john/... targets ---
test_ac2_compose_volumes_use_container_home() {
  if [ ! -f docker-compose.yml ]; then
    fail "ac2: docker-compose.yml not found"
    return
  fi
  local hits
  hits="$(non_fallback_john_hits docker-compose.yml)"
  if [ -z "$hits" ]; then
    pass "ac2: docker-compose.yml has no hardcoded /home/john mount targets"
  else
    fail "ac2: docker-compose.yml still hardcodes john/home-john outside a \${CONTAINER_HOME:-...} fallback:
$hits"
  fi
}

# --- AC3: bin/agent-loop.sh's sync_dir calls derive the home path from CONTAINER_HOME ---
test_ac3_agent_loop_sync_uses_container_home() {
  if [ ! -f bin/agent-loop.sh ]; then
    fail "ac3: bin/agent-loop.sh not found"
    return
  fi
  local hits
  hits="$(non_fallback_john_hits bin/agent-loop.sh)"
  if [ -n "$hits" ]; then
    fail "ac3: bin/agent-loop.sh still hardcodes john/home-john outside a \${CONTAINER_HOME:-...} fallback:
$hits"
    return
  fi
  if ! grep -Eq 'CONTAINER_HOME="\$\{CONTAINER_HOME:-.*\}"' bin/agent-loop.sh; then
    fail "ac3: bin/agent-loop.sh does not derive CONTAINER_HOME (expected a \${CONTAINER_HOME:-...} default assignment near the other env-derived vars)"
    return
  fi
  local sync_block
  sync_block="$(sed -n '/^sync_configs()/,/^}/p' bin/agent-loop.sh)"
  if [ -z "$sync_block" ]; then
    fail "ac3: could not find sync_configs() in bin/agent-loop.sh"
    return
  fi
  local claude_ok=1 kit_ok=1 agents_ok=1
  echo "$sync_block" | grep -q '\.claude-host'   && echo "$sync_block" | grep -q '\$CONTAINER_HOME' || claude_ok=0
  echo "$sync_block" | grep -q '\.ai-dev-kit-host' || kit_ok=0
  echo "$sync_block" | grep -q '\.agents-host'      || agents_ok=0
  if echo "$sync_block" | grep -qE '/home/john' ; then
    fail "ac3: sync_configs() in bin/agent-loop.sh still references a literal /home/john path:
$sync_block"
    return
  fi
  if [ "$claude_ok" = 1 ] && [ "$kit_ok" = 1 ] && [ "$agents_ok" = 1 ]; then
    pass "ac3: sync_configs()'s three sync_dir calls (.claude, .ai-dev-kit, .agents) derive their path from \$CONTAINER_HOME"
  else
    fail "ac3: sync_configs() is missing one of the expected .claude/.ai-dev-kit/.agents sync_dir calls:
$sync_block"
  fi
}

# --- AC4: bin/init.sh fills in CONTAINER_HOME into a pre-existing .env, idempotently ---
test_ac4_init_appends_container_home_idempotently() {
  if [ ! -f bin/init.sh ]; then
    fail "ac4: bin/init.sh not found"
    return
  fi
  # Extract the single statement that appends CONTAINER_HOME (mirrors the existing
  # HOST_UID/HOST_GID append at bin/init.sh:13 - see docs/design/agent-factory-9l0.md).
  local append_line
  append_line="$(grep -E "grep -q '\^CONTAINER_HOME=' .*>>.*\.env" bin/init.sh || true)"
  if [ -z "$append_line" ]; then
    fail "ac4: bin/init.sh has no idempotent 'grep -q ... CONTAINER_HOME ... >> .env' append statement (see bin/init.sh:13's HOST_UID/HOST_GID pattern for the expected shape)"
    return
  fi

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  printf 'HOST_UID=1000\nHOST_GID=1000\n' > "$tmp/.env"

  ( KIT_DIR="$tmp"; eval "$append_line" )
  ( KIT_DIR="$tmp"; eval "$append_line" )  # run twice: must not duplicate the line

  local count value
  count="$(grep -c '^CONTAINER_HOME=' "$tmp/.env" || true)"
  value="$(grep '^CONTAINER_HOME=' "$tmp/.env" | head -1 | cut -d= -f2-)"

  if [ "$count" != "1" ]; then
    fail "ac4: expected exactly one CONTAINER_HOME= line in .env after running the append statement twice, got $count"
  elif [ -z "$value" ]; then
    fail "ac4: CONTAINER_HOME was appended with an empty value"
  elif ! grep -q '^HOST_UID=1000$' "$tmp/.env" || ! grep -q '^HOST_GID=1000$' "$tmp/.env"; then
    fail "ac4: pre-existing HOST_UID/HOST_GID lines were disturbed by the CONTAINER_HOME append"
  else
    pass "ac4: bin/init.sh's CONTAINER_HOME append is idempotent and preserves the rest of an existing .env (value=$value)"
  fi
}

# --- AC5: repo-wide grep for john/home-john in docker-compose.yml and bin/*.sh shows only
#          the ${CONTAINER_HOME:-/home/john} fallback default, never a bare hardcoded path ---
test_ac5_no_hardcoded_john_left() {
  # shellcheck disable=SC2206
  local files=(docker-compose.yml bin/*.sh)
  local hits
  hits="$(non_fallback_john_hits "${files[@]}")"
  if [ -z "$hits" ]; then
    pass "ac5: no hardcoded john/home-john references remain in docker-compose.yml or bin/*.sh"
  else
    fail "ac5: hardcoded john/home-john references remain outside a \${CONTAINER_HOME:-...} fallback:
$hits"
  fi
}

# --- AC1: no step fails or silently mis-owns files for a non-john host user. Not independently
#          runnable without a matching container image/docker (see design's Test strategy #6,
#          a manual full-loop smoke test); here we assert the two static preconditions that make
#          that true: the pre-existing HOST_UID/HOST_GID derivation (bin/init.sh:13) is intact,
#          and AC2/AC3/AC5's CONTAINER_HOME wiring (this story's actual change) holds together. ---
test_ac1_identity_derivation_present() {
  if ! grep -Eq "HOST_UID=\\\$\(id -u\)" bin/init.sh; then
    fail "ac1: bin/init.sh no longer derives HOST_UID from 'id -u' (regression against pre-existing behavior)"
    return
  fi
  if ! grep -Eq '\$\{HOST_UID:-1000\}' docker-compose.yml; then
    fail "ac1: docker-compose.yml no longer uses the \${HOST_UID:-1000} fallback (regression)"
    return
  fi
  pass "ac1: pre-existing HOST_UID/HOST_GID identity derivation is intact (full end-to-end coverage needs a manual smoke test per docs/design/agent-factory-9l0.md - no docker available in this environment)"
}

test_ac1_identity_derivation_present
test_ac2_compose_volumes_use_container_home
test_ac3_agent_loop_sync_uses_container_home
test_ac4_init_appends_container_home_idempotently
test_ac5_no_hardcoded_john_left

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
