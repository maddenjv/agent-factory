#!/usr/bin/env bash
# Acceptance tests for agent-factory-1aq (Install shellcheck in the agent image).
# One test function per acceptance criterion in docs/stories/agent-factory-1aq.md. Plain shell
# acceptance script (docs/ARCHITECTURE.md "Test strategy"); run directly:
#   bash tests/acceptance/agent-factory-1aq.sh
# PASS/FAIL/SKIP per criterion; exit is non-zero if any FAILs. SKIP = docker unavailable here
# (not a pass, not an implementation failure). Static Dockerfile checks still run without docker.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$KIT_DIR"

HOST_UID_EXPECT="${HOST_UID:-1000}"
HOST_GID_EXPECT="${HOST_GID:-1000}"

pass=0
fail=0
skip=0

ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
skp()  { echo "SKIP: $1"; skip=$((skip+1)); }

have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
dc() { docker compose -f "$KIT_DIR/docker-compose.yml" "$@"; }
in_agent() { dc run --rm --entrypoint bash agent -lc "$1"; }

# AC1: `docker compose build agent` succeeds.
test_ac1_build_succeeds() {
  if ! grep -qi 'shellcheck' Dockerfile; then
    bad "ac1: Dockerfile does not mention shellcheck (nothing installs it)"
    return
  fi
  if ! have_docker; then
    skp "ac1: docker unavailable - Dockerfile mentions shellcheck, build unverified"
    return
  fi
  if dc build agent; then ok "ac1: docker compose build agent succeeded"
  else bad "ac1: docker compose build agent failed"; fi
}

# AC2: shellcheck --version exits 0 and prints a version banner.
test_ac2_shellcheck_version() {
  if ! have_docker; then
    skp "ac2: docker unavailable - cannot run shellcheck --version in the image"
    return
  fi
  local out
  if ! out=$(in_agent 'shellcheck --version'); then
    bad "ac2: shellcheck --version failed in the image"
  elif grep -Eq '^version: [0-9]+\.[0-9]+' <<<"$out"; then
    ok "ac2: shellcheck --version exits 0 with banner ($(grep -E '^version:' <<<"$out"))"
  else
    bad "ac2: no 'version: X.Y' banner in output: $out"
  fi
}

# AC3: shellcheck runs against bin/lib.sh inside the container; rc reflects lint result,
# not 127 / "command not found". (Repo mounted via a bind mount so bin/lib.sh is visible.)
test_ac3_shellcheck_runs_on_lib() {
  if ! have_docker; then
    skp "ac3: docker unavailable - cannot run shellcheck on bin/lib.sh in the image"
    return
  fi
  local out rc
  out=$(dc run --rm -v "$KIT_DIR/bin/lib.sh:/tmp/lib.sh:ro" --entrypoint bash agent -lc \
        'shellcheck /tmp/lib.sh 2>&1; echo "rc=$?"')
  rc=$(sed -n 's/^rc=//p' <<<"$out" | tail -n1)
  if [ -z "$rc" ] || [ "$rc" = "127" ] || grep -qi 'command not found' <<<"$out"; then
    bad "ac3: shellcheck not runnable in container: $out"
  elif [ "$rc" -gt 1 ]; then
    bad "ac3: shellcheck exited $rc (usage/runtime error, not a lint result): $out"
  else
    ok "ac3: shellcheck executed on bin/lib.sh (rc=$rc, 0=clean 1=findings)"
  fi
}

# AC4: existing tools and user/UID/GID unchanged.
test_ac4_existing_tools_and_user_unchanged() {
  if ! have_docker; then
    skp "ac4: docker unavailable - cannot verify tools/user in the image"
    return
  fi
  if ! in_agent 'claude --version && bd --version && git --version && jq --version && curl --version >/dev/null'; then
    bad "ac4: one of claude/bd/git/jq/curl failed in the image"
    return
  fi
  local out
  out=$(in_agent 'id -u; id -g; id -un; echo "$HOME"') || { bad "ac4: could not read user identity"; return; }
  if [ "$(sed -n 1p <<<"$out")" = "$HOST_UID_EXPECT" ] && [ "$(sed -n 2p <<<"$out")" = "$HOST_GID_EXPECT" ] \
     && [ "$(sed -n 3p <<<"$out")" = "john" ] && [ "$(sed -n 4p <<<"$out")" = "/home/john" ]; then
    ok "ac4: tools present; user john uid/gid $HOST_UID_EXPECT/$HOST_GID_EXPECT home /home/john"
  else
    bad "ac4: user identity changed: $(tr '\n' ' ' <<<"$out")"
  fi
}

test_ac1_build_succeeds
test_ac2_shellcheck_version
test_ac3_shellcheck_runs_on_lib
test_ac4_existing_tools_and_user_unchanged

echo "---"
echo "pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
