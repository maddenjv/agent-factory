#!/usr/bin/env bash
# Acceptance tests for agent-factory-eqy2 (passwordless sudo for the agent user).
# One or more tests per acceptance criterion in docs/stories/agent-factory-eqy2.md:
#   bash tests/agent-factory-eqy2_test.sh
# Written before implementation, from the story only.
# Runtime tests (AC1-6) need docker + `docker compose` (+ network for AC3); they build from a scratch
# copy of the repo under throwaway tags (both HARNESS values), so factory-agent:latest is never
# touched, and start containers with the security flags rendered from docker-compose.yml's `agent`
# service. Without docker those tests are SKIPped (reported, not failed). AC7-9 and the static
# compose checks need only the repo files.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"

pass=0; fail=0; skip=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
skp()  { echo "SKIP: $1"; skip=$((skip+1)); }

cleanup_dirs=(); cleanup_imgs=()
cleanup() {
  for i in "${cleanup_imgs[@]}"; do docker rmi -f "$i" >/dev/null 2>&1; done
  for d in "${cleanup_dirs[@]}"; do rm -rf "$d"; done
}
trap cleanup EXIT

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
   && docker compose version >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then HAVE_DOCKER=1; fi
RUN_ID="t$$"
W=$(mktemp -d); cleanup_dirs+=("$W")
HARNESSES="claude-code copilot"
declare -A RC
FLAGS=()   # docker run flags rendered from the compose `agent` service

if [ "$HAVE_DOCKER" = 1 ]; then
  CTX=$(mktemp -d); cleanup_dirs+=("$CTX")
  git -C "$KIT_DIR" archive HEAD | tar -x -C "$CTX"
  : >"$W/agent.env"
  cfg=$(AGENT_ENV_FILE="$W/agent.env" KIT_DIR="$CTX" PROJECT_DIR="$W" HOME="$W" \
        docker compose -f "$CTX/docker-compose.yml" --profile agents config --format json 2>"$W/cfg.err")
  if [ -n "$cfg" ]; then
    a='.services.agent'
    while IFS= read -r c; do [ -n "$c" ] && FLAGS+=(--cap-drop "$c"); done < <(jq -r "$a.cap_drop[]?" <<<"$cfg")
    while IFS= read -r c; do [ -n "$c" ] && FLAGS+=(--cap-add "$c"); done < <(jq -r "$a.cap_add[]?" <<<"$cfg")
    while IFS= read -r c; do [ -n "$c" ] && FLAGS+=(--security-opt "$c"); done < <(jq -r "$a.security_opt[]?" <<<"$cfg")
    p=$(jq -r "$a.pids_limit // empty" <<<"$cfg"); [ -n "$p" ] && FLAGS+=(--pids-limit "$p")
    m=$(jq -r "$a.mem_limit // empty" <<<"$cfg"); [ -n "$m" ] && FLAGS+=(--memory "$m")
    [ "$(jq -r "$a.privileged // false" <<<"$cfg")" = true ] && FLAGS+=(--privileged)
    CFG_OK=1
  else
    CFG_OK=0
  fi
  for h in $HARNESSES; do
    cleanup_imgs+=("af-eqy2-$h-$RUN_ID")
    docker build --build-arg HARNESS="$h" -t "af-eqy2-$h-$RUN_ID" "$CTX" >"$W/build-$h.log" 2>&1
    RC[$h]=$?
  done
fi

# check <name> <harness> <shell-snippet>: run the snippet in the image, as its default user, with the
# compose service's security options.
check() {
  local n=$1 h=$2; shift 2
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker)"; return; }
  [ "$CFG_OK" = 1 ] || { bad "$n - docker compose config failed: $(tail -3 "$W/cfg.err")"; return; }
  [ "${RC[$h]}" = 0 ] || { bad "$n - build failed: $(tail -5 "$W/build-$h.log")"; return; }
  local out
  out=$(docker run --rm "${FLAGS[@]}" --entrypoint bash "af-eqy2-$h-$RUN_ID" -c \
    '[ "$(id -u)" != 0 ] || { echo "ran as root"; exit 1; }; set -e; '"$*" 2>&1) \
    && ok "$n" || bad "$n - $out"
}

ac1() { check "AC1 [$1] sudo -n true exits 0 without a password" "$1" 'sudo -n true'; }
ac2() { check "AC2 [$1] sudo -n id -u prints 0 under compose security options" "$1" \
  '[ "$(sudo -n id -u)" = 0 ]'; }
ac3() { check "AC3 [$1] sudo apt-get update + install tree makes tree runnable" "$1" \
  '! command -v tree >/dev/null; sudo -n apt-get update >/dev/null; sudo -n apt-get install -y tree >/dev/null; tree --version'; }
ac4() { check "AC4 [$1] harness CLI, bd, git, jq, curl, shellcheck still work" "$1" \
  'h='"$([ "$1" = claude-code ] && echo claude || echo copilot)"'
   command -v "$h"; "$h" --version; bd --version; git --version; jq --version; curl --version; shellcheck --version'; }
ac5() { check "AC5 [$1] default user is non-root; files written (no sudo) are owned by it" "$1" \
  'u=$(id -u); [ "$u" != 0 ]; d=$(mktemp -d); touch "$d/f"; [ "$(stat -c %u "$d/f")" = "$u" ]
   [ "$(stat -c %u "$HOME")" = "$u" ]; sudo -n true; touch "$d/g"; [ "$(stat -c %u "$d/g")" = "$u" ]'; }
ac6_rt() { check "AC6 [$1] no docker socket, no ~/.ssh in container; no host mounts for them" "$1" \
  '[ ! -e /var/run/docker.sock ] && [ ! -e /run/docker.sock ]; [ ! -e "$HOME/.ssh" ]'; }
ac6_lim() { check "AC6 [$1] pids and memory limits still applied" "$1" \
  'pl=$(cat /sys/fs/cgroup/pids.max 2>/dev/null || cat /sys/fs/cgroup/pids/pids.max)
   ml=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
   [ "$pl" = 512 ]; [ "$ml" = 6442450944 ]'; }

for h in $HARNESSES; do
  ac1 "$h"; ac2 "$h"; ac3 "$h"; ac4 "$h"; ac5 "$h"; ac6_rt "$h"; ac6_lim "$h"
done

# ---- static checks (no docker needed) ----
C=docker-compose.yml
# agent service block: from "  agent:" to the next top-level key.
agent_block() { awk '/^  agent:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^  [a-z]/{f=0} f' "$C"; }
blk=$(agent_block)

if grep -Eq 'no-new-privileges:[[:space:]]*true' <<<"$(grep -v '^[[:space:]]*#' <<<"$blk")"; then
  bad "AC2 compose agent service still sets no-new-privileges:true (setuid sudo cannot work)"
else ok "AC2 compose agent service no longer sets no-new-privileges:true"; fi

if grep -Eq '^[[:space:]]*(privileged:[[:space:]]*true|user:[[:space:]]*"?(root|0))' <<<"$blk"; then
  bad "AC5/6 compose agent service is privileged or runs as root by default"
else ok "AC5/6 compose agent service is neither privileged nor default-root"; fi

nc=$(grep -v '^[[:space:]]*#' <<<"$blk")
if grep -Eq 'docker\.sock|\.ssh' <<<"$nc"; then bad "AC6 compose agent service mounts docker socket or ~/.ssh"
else ok "AC6 compose agent service does not mount docker socket or ~/.ssh"; fi
if grep -Eq 'pids_limit:' <<<"$nc" && grep -Eq 'mem_limit:' <<<"$nc"; then ok "AC6 pids_limit and mem_limit still set in compose"
else bad "AC6 pids_limit/mem_limit missing from compose agent service"; fi
if grep -Eq 'cap_drop:[[:space:]]*\[?[[:space:]]*-?[[:space:]]*ALL' <<<"$nc" || grep -Eq '^[[:space:]]*-[[:space:]]*ALL' <<<"$nc"; then
  ok "AC6 compose agent still drops ALL capabilities (any relaxation is a narrow cap_add)"
else bad "AC6 compose agent no longer has cap_drop ALL (relaxation should be a narrow cap_add)"; fi
ro_bad=$(grep -E -- '-host:' <<<"$nc" | grep -v ':ro' || true)
if [ -z "$ro_bad" ] && grep -q -- '-host:ro' <<<"$nc"; then ok "AC6 host-config mounts (*-host) are still read-only"
else bad "AC6 a host-config mount is missing or not read-only: $ro_bad"; fi

# Dockerfile: sudo installed, passwordless for the agent user, default user still non-root.
if grep -Eq 'sudo' Dockerfile && grep -Eq 'NOPASSWD' Dockerfile; then ok "AC1 Dockerfile installs sudo and configures NOPASSWD"
else bad "AC1 Dockerfile does not install sudo / configure NOPASSWD"; fi
last_user=$(grep -E '^USER[[:space:]]' Dockerfile | tail -1 | awk '{print $2}')
if [ -n "$last_user" ] && [ "$last_user" != root ] && [ "$last_user" != 0 ]; then ok "AC5 Dockerfile's final USER is non-root ($last_user)"
else bad "AC5 Dockerfile's final USER is not a non-root user (got '${last_user:-none}')"; fi

# AC7/8: instructions every role loads.
for f in agents/CLAUDE.project.md CLAUDE.md; do
  if grep -qi 'sudo' "$f" && grep -Eqi 'passwordless|without a password|no password' "$f" \
     && grep -Eqi 'install' "$f"; then ok "AC7 $f says passwordless sudo is available and installs are allowed"
  else bad "AC7 $f does not say passwordless sudo is available / package installs allowed"; fi
  sec=$(grep -i -B6 -A16 'sudo' "$f" 2>/dev/null || true)
  if grep -Eqi 'security' <<<"$sec" && grep -Eqi 'clone|outside' <<<"$sec" \
     && grep -Eqi 'issue' <<<"$sec" && grep -Eqi 'persist|rebuild' <<<"$sec"; then
    ok "AC8 $f scopes sudo use (no security-settings/outside-clone changes; file an issue; not persistent)"
  else bad "AC8 $f lacks sudo scope limits (security settings, outside clone, file issue for image, no persistence across rebuilds)"; fi
done

# AC9: docs.
for f in docs/ARCHITECTURE.md README.md; do
  if grep -qi 'sudo' "$f" && grep -Eqi 'passwordless|NOPASSWD' "$f" \
     && grep -Eqi 'no-new-privileges|cap_add|cap_drop|capabilit' "$f"; then
    ok "AC9 $f describes passwordless sudo and the hardening adjusted for it"
  else bad "AC9 $f does not describe passwordless sudo and the adjusted hardening"; fi
done

echo "passed=$pass failed=$fail skipped=$skip"
[ "$fail" -eq 0 ]
