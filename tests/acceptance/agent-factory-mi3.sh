#!/usr/bin/env bash
# Acceptance tests for agent-factory-mi3 (Remove claude-code-sandbox dependency).
# One test function per acceptance criterion in docs/stories/agent-factory-mi3.md - see that
# file and docs/design/agent-factory-mi3.md ("Test strategy (for QA)") for the criteria/commands
# these are derived from. No unit-test framework applies here (docs/ARCHITECTURE.md "Test
# strategy"); this is a plain shell acceptance script, run directly:
#   bash tests/acceptance/agent-factory-mi3.sh
# PASS/FAIL/SKIP is printed per criterion; overall exit is non-zero if any criterion FAILs.
# SKIP means "docker isn't available in this environment" - not a pass, and not counted as a
# failure of the implementation under test.
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

# AC1: clean checkout, no sibling claude-code-sandbox present, `docker compose build agent`
# succeeds without referencing any path outside this repo.
test_ac1_self_contained_build() {
  if [ ! -f "$KIT_DIR/Dockerfile" ]; then
    bad "ac1: Dockerfile missing at repo root ($KIT_DIR/Dockerfile)"
    return
  fi
  if ! grep -Eq '^\s*context:\s*\.\s*$' docker-compose.yml; then
    bad "ac1: docker-compose.yml agent.build.context is not '.' (still points outside this repo?)"
    return
  fi
  if grep -q 'claude-code-sandbox' docker-compose.yml; then
    bad "ac1: docker-compose.yml still references claude-code-sandbox"
    return
  fi
  if ! have_docker; then
    skp "ac1: docker not available in this environment - static checks passed, build unverified"
    return
  fi
  if [ -d "$KIT_DIR/../claude-code-sandbox" ]; then
    bad "ac1: sibling ../claude-code-sandbox exists locally - not a clean-checkout test of AC1"
    return
  fi
  if dc build agent; then
    ok "ac1: docker compose build agent succeeded from a self-contained context"
  else
    bad "ac1: docker compose build agent failed"
  fi
}

# AC2: claude --version, bd --version, git --version, jq --version all succeed in the built image.
test_ac2_toolchain_present() {
  if ! have_docker; then
    skp "ac2: docker not available in this environment - cannot verify toolchain versions"
    return
  fi
  if dc run --rm --entrypoint bash agent -lc \
      'claude --version && bd --version && git --version && jq --version'; then
    ok "ac2: claude/bd/git/jq --version all succeeded in the built image"
  else
    bad "ac2: one or more of claude/bd/git/jq --version failed in the built image"
  fi
}

# AC3: container's default user is non-root, home /home/john, uid/gid match HOST_UID/HOST_GID
# build args (default 1000/1000).
test_ac3_nonroot_user_identity() {
  if ! have_docker; then
    skp "ac3: docker not available in this environment - cannot verify container user identity"
    return
  fi
  local out uid gid uname home
  out=$(dc run --rm --entrypoint bash agent -lc 'id -u; id -g; id -un; echo "$HOME"') || {
    bad "ac3: could not exec id/\$HOME in container"
    return
  }
  uid=$(sed -n '1p' <<<"$out")
  gid=$(sed -n '2p' <<<"$out")
  uname=$(sed -n '3p' <<<"$out")
  home=$(sed -n '4p' <<<"$out")
  if [ "$uid" = "0" ]; then
    bad "ac3: container default user is root (uid 0)"
  elif [ "$uid" != "$HOST_UID_EXPECT" ] || [ "$gid" != "$HOST_GID_EXPECT" ]; then
    bad "ac3: uid/gid ($uid/$gid) don't match HOST_UID/HOST_GID ($HOST_UID_EXPECT/$HOST_GID_EXPECT)"
  elif [ "$uname" != "john" ] || [ "$home" != "/home/john" ]; then
    bad "ac3: username/home ($uname/$home) is not john/home/john"
  else
    ok "ac3: non-root user john, uid/gid $uid/$gid, home /home/john"
  fi
}

# AC4: agent-loop.sh entrypoint override + ~/.claude, ~/.ai-dev-kit, ~/.agents host-sync mounts
# keep working unchanged - this story only touches agent.build, not agent.entrypoint/volumes.
test_ac4_entrypoint_and_sync_unchanged() {
  if ! grep -Fq 'entrypoint: ["bash", "${KIT_DIR}/bin/agent-loop.sh"]' docker-compose.yml; then
    bad "ac4: agent.entrypoint no longer overrides agent-loop.sh in docker-compose.yml"
    return
  fi
  local missing=0
  for mount in '.claude-host:ro' '.ai-dev-kit-host:ro' '.agents-host:ro'; do
    grep -q "$mount" docker-compose.yml || { bad "ac4: missing host-sync mount for $mount"; missing=1; }
  done
  [ "$missing" -eq 1 ] && return
  if ! have_docker; then
    skp "ac4: static entrypoint/mount checks passed; docker unavailable to confirm the running sync-and-run flow"
    return
  fi
  ok "ac4: agent-loop.sh entrypoint override and host-config mounts are unchanged"
}

# AC5: README.md's Setup section no longer states ../claude-code-sandbox as a required sibling
# checkout, and instead describes the self-contained build.
test_ac5_readme_updated() {
  if grep -q 'claude-code-sandbox' README.md; then
    bad "ac5: README.md still references claude-code-sandbox"
    return
  fi
  ok "ac5: README.md no longer references claude-code-sandbox"
}

test_ac1_self_contained_build
test_ac2_toolchain_present
test_ac3_nonroot_user_identity
test_ac4_entrypoint_and_sync_unchanged
test_ac5_readme_updated

echo "---"
echo "pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
