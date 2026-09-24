#!/usr/bin/env bash
# Acceptance tests for agent-factory-76g: account name/UID/GID/home taken from the host user.
# One function per acceptance criterion in docs/stories/agent-factory-76g.md (test_acN_...).
# bin/init.sh tests run with stub `id` and `docker` on PATH (no real docker needed).
# Docker-backed tests (ac2, ac3, ac5 runtime) are SKIPped when no docker daemon is reachable.
# Run directly: bash tests/agent-factory-76g_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"
cat > "$TMP/stubs/id" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -un) echo "$FAKE_USER";; -u) echo "$FAKE_UID";; -g) echo "$FAKE_GID";; *) echo "uid=$FAKE_UID($FAKE_USER)";; esac
STUB
cat > "$TMP/stubs/docker" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP/stubs/"*

# new_project NAME [ENV_CONTENT] -> creates a clean git repo at $TMP/NAME; prints path.
# With ENV_CONTENT, pre-seeds .agent-factory/.env.
new_project() {
  local p="$TMP/$1"; mkdir -p "$p"
  git -C "$p" init -q; git -C "$p" config user.email t@t; git -C "$p" config user.name t
  echo x > "$p/f"; git -C "$p" add f; git -C "$p" commit -qm init
  echo '.agent-factory/' > "$p/.git/info/exclude"
  if [ $# -ge 2 ]; then mkdir -p "$p/.agent-factory"; printf '%s' "$2" > "$p/.agent-factory/.env"; fi
  echo "$p"
}
# run_init PROJECT USER UID GID [HOME_OVERRIDE] - runs bin/init.sh (twice if the first run only
# created the starter .env and exited), leaving results in PROJECT/.agent-factory/.env
run_init() {
  local p="$1"; case "$p" in "$TMP"/*) ;; *) echo "refusing to run init outside TMP" >&2; return 1;; esac
  (cd "$p" && env -u CONTAINER_HOME -u PROJECT_DIR -u AGENT_ENV_FILE -u KIT_DIR -u DATA_DIR PATH="$TMP/stubs:$PATH" FAKE_USER="$2" FAKE_UID="$3" FAKE_GID="$4" \
     bash "$REPO_ROOT/bin/init.sh" >"$TMP/init.out" 2>&1) && return 0
  (cd "$p" && env -u CONTAINER_HOME -u PROJECT_DIR -u AGENT_ENV_FILE -u KIT_DIR -u DATA_DIR PATH="$TMP/stubs:$PATH" FAKE_USER="$2" FAKE_UID="$3" FAKE_GID="$4" \
     bash "$REPO_ROOT/bin/init.sh" >"$TMP/init.out" 2>&1)
}
envval() { grep -E "^$2=" "$1" | tail -1 | cut -d= -f2-; }
# username variable: any KEY containing USER whose value is the name
user_lines() { grep -E '^[A-Z_]*USER[A-Z_]*=' "$1" | grep -v '^DOLT' ; }

test_ac1_init_records_username_uid_gid_home() {
  local p; p=$(new_project ac1)
  run_init "$p" alice 1234 1234
  local f="$p/.agent-factory/.env"
  [ -f "$f" ] || { fail "ac1: no .env produced"; return; }
  user_lines "$f" | grep -qx '[A-Z_]*=alice' || { fail "ac1: no username=alice in .env: $(cat "$f" | grep -E 'HOST|HOME|USER')"; return; }
  [ "$(envval "$f" HOST_UID)" = 1234 ] || { fail "ac1: HOST_UID != 1234"; return; }
  [ "$(envval "$f" HOST_GID)" = 1234 ] || { fail "ac1: HOST_GID != 1234"; return; }
  [ "$(envval "$f" CONTAINER_HOME)" = /home/alice ] || { fail "ac1: CONTAINER_HOME=$(envval "$f" CONTAINER_HOME), want /home/alice"; return; }
  pass "ac1: init.sh records alice/1234/1234 and /home/alice"
}

test_ac1_container_home_not_inherited_from_john() {
  local p; p=$(new_project ac1b)
  run_init "$p" bob 2001 2002
  grep -q 'john' "$p/.agent-factory/.env" && { fail "ac1b: .env mentions john for user bob"; return; }
  [ "$(envval "$p/.agent-factory/.env" CONTAINER_HOME)" = /home/bob ] || { fail "ac1b: CONTAINER_HOME not /home/bob"; return; }
  pass "ac1b: different user (bob) gets /home/bob, no john"
}

test_ac4_no_hardcoded_home_in_agent_loop_and_compose() {
  local out; out=$(grep -n '/home/john' bin/agent-loop.sh docker-compose.yml Dockerfile)
  [ -z "$out" ] && pass "ac4: no /home/john in agent-loop.sh, docker-compose.yml, Dockerfile" || fail "ac4: $out"
}

test_ac4_compose_mounts_use_derived_home() {
  local n; n=$(grep -cE 'CONTAINER_HOME[^ ]*/\.(claude|ai-dev-kit|agents)' docker-compose.yml)
  [ "$n" -ge 6 ] && pass "ac4: compose mounts .claude/.ai-dev-kit/.agents under CONTAINER_HOME" || fail "ac4: only $n CONTAINER_HOME mounts"
  grep -q 'CONTAINER_HOME' bin/agent-loop.sh && grep -q 'sync_dir "\$CONTAINER_HOME' bin/agent-loop.sh \
    && pass "ac4: agent-loop.sh syncs into \$CONTAINER_HOME" || fail "ac4: agent-loop.sh sync not based on CONTAINER_HOME"
}

test_ac6_existing_env_gets_username_without_overwrite() {
  local seed=$'HOST_UID=4321\nHOST_GID=4322\nCONTAINER_HOME=/home/custom\nMAX_TURNS=7\n'
  local p; p=$(new_project ac6 "$seed")
  local before; before=$(cat "$p/.agent-factory/.env")
  run_init "$p" alice 1234 1234
  local f="$p/.agent-factory/.env"
  user_lines "$f" | grep -qx '[A-Z_]*=alice' || { fail "ac6: username not added"; return; }
  [ "$(envval "$f" HOST_UID)" = 4321 ] && [ "$(envval "$f" HOST_GID)" = 4322 ] \
    && [ "$(envval "$f" CONTAINER_HOME)" = /home/custom ] && [ "$(envval "$f" MAX_TURNS)" = 7 ] \
    || { fail "ac6: existing values overwritten"; return; }
  # every original line still present, exactly once
  while IFS= read -r l; do [ "$(grep -cxF "$l" "$f")" = 1 ] || { fail "ac6: line changed/duplicated: $l"; return; }; done <<<"$before"
  pass "ac6: username added, existing values untouched"
}

test_ac6_rerun_is_idempotent() {
  local p; p=$(new_project ac6b $'HOST_UID=1\nHOST_GID=1\nCONTAINER_HOME=/home/x\n')
  run_init "$p" alice 1234 1234; local a; a=$(cat "$p/.agent-factory/.env")
  run_init "$p" alice 1234 1234; local b; b=$(cat "$p/.agent-factory/.env")
  [ "$a" = "$b" ] && pass "ac6: re-running init.sh does not change .env again" || fail "ac6: second run changed .env"
}

test_ac6_existing_username_not_overwritten() {
  local p; p=$(new_project ac6c $'HOST_UID=1\nHOST_GID=1\nCONTAINER_HOME=/home/x\n')
  run_init "$p" alice 1234 1234
  local before; before=$(user_lines "$p/.agent-factory/.env")
  run_init "$p" carol 1234 1234
  [ "$(user_lines "$p/.agent-factory/.env")" = "$before" ] && pass "ac6: recorded username kept when host user differs" || fail "ac6: username overwritten"
}

test_ac5_john_1000_init_matches_previous_behaviour() {
  local p; p=$(new_project ac5)
  run_init "$p" john 1000 1000
  local f="$p/.agent-factory/.env"
  [ "$(envval "$f" HOST_UID)" = 1000 ] && [ "$(envval "$f" HOST_GID)" = 1000 ] \
    && [ "$(envval "$f" CONTAINER_HOME)" = /home/john ] && user_lines "$f" | grep -qx '[A-Z_]*=john' \
    && pass "ac5: john/1000/1000 -> /home/john in .env" || fail "ac5: john .env wrong"
}

test_ac7_no_john_literal_in_tracked_files() {
  local out; out=$(grep -nw 'john' Dockerfile docker-compose.yml bin/* README.md docs/ARCHITECTURE.md 2>/dev/null)
  [ -z "$out" ] && pass "ac7: no 'john' in Dockerfile, compose, bin/, README, ARCHITECTURE" || fail "ac7: $(echo "$out" | head -5)"
  out=$(grep -n '/home/john' Dockerfile docker-compose.yml bin/* README.md docs/ARCHITECTURE.md 2>/dev/null)
  [ -z "$out" ] && pass "ac7: no /home/john" || fail "ac7: $out"
}

test_ac7_docs_describe_account_as_host_derived() {
  grep -qiE 'username|HOST_USER' docs/ARCHITECTURE.md \
    && grep -qiE 'derived|host user|host username|from the host' docs/ARCHITECTURE.md \
    && pass "ac7: ARCHITECTURE.md describes account as host-derived" || fail "ac7: ARCHITECTURE.md lacks host-derived account description"
}

# ---- Docker-backed (ac2, ac3, ac5 runtime) ----
docker_ready() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# build_and_run USER UID GID -> sets OUT to `id -un; id -u; id -g; echo $HOME` output
build_and_run() {
  local p; p=$(new_project "dk_$1")
  run_init "$p" "$1" "$2" "$3"
  local envf="$p/.agent-factory/.env"
  local dcmd=(docker compose -f "$REPO_ROOT/docker-compose.yml" --env-file "$envf")
  export KIT_DIR="$REPO_ROOT" PROJECT_DIR="$p" AGENT_ENV_FILE="$envf"
  "${dcmd[@]}" build agent >"$TMP/build.out" 2>&1 || return 1
  OUT=$("${dcmd[@]}" run --rm --entrypoint bash agent -lc 'id -un; id -u; id -g; echo $HOME' 2>&1)
  DCMD=("${dcmd[@]}")
}

test_ac2_image_account_matches_host_user() {
  docker_ready || { skip "ac2: no docker daemon"; return; }
  build_and_run alice 1234 1234 || { fail "ac2: build failed: $(tail -3 "$TMP/build.out")"; return; }
  [ "$(echo "$OUT" | tail -4)" = $'alice\n1234\n1234\n/home/alice' ] && pass "ac2: container is alice/1234/1234 /home/alice" || fail "ac2: got: $OUT"
}

test_ac3_bind_mount_files_owned_by_host_user() {
  docker_ready || { skip "ac3: no docker daemon"; return; }
  local uid; uid=$(id -u)
  build_and_run "$(id -un)" "$uid" "$(id -g)" || { fail "ac3: build failed"; return; }
  local d="$TMP/mnt"; mkdir -p "$d"
  "${DCMD[@]}" run --rm -v "$d:/mnt/t" --entrypoint bash agent -lc 'touch /mnt/t/f' >/dev/null 2>&1
  [ "$(stat -c %u "$d/f" 2>/dev/null)" = "$uid" ] && pass "ac3: file owned by invoking host user" || fail "ac3: bad ownership"
}

test_ac5_john_1000_container_identical() {
  docker_ready || { skip "ac5: no docker daemon"; return; }
  build_and_run john 1000 1000 || { fail "ac5: build failed"; return; }
  [ "$(echo "$OUT" | tail -4)" = $'john\n1000\n1000\n/home/john' ] && pass "ac5: container john/1000/1000 /home/john" || fail "ac5: got: $OUT"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "passed=$PASS failed=$FAIL skipped=$SKIP"
[ "$FAIL" -eq 0 ]
