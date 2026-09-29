#!/usr/bin/env bash
# Acceptance tests for agent-factory-wpq4: .env's HOST_USER/HOST_UID/HOST_GID/CONTAINER_HOME must
# actually reach Compose's own build-arg/volume-mount interpolation (bin/init.sh's `dc build
# agent` and bin/start.sh's pane()/ops_cmd/board_cmd `docker compose run` strings), not just get
# written into .env and silently ignored.
# One function per acceptance criterion in docs/stories/agent-factory-wpq4.md (test_acN_...).
# Docker-backed tests are SKIPped when no docker daemon is reachable. Deliberately does NOT use
# an explicit `docker compose --env-file` workaround anywhere - that would paper over exactly the
# gap this story exists to close; tests source the real bin/lib.sh (dc()) and, for AC2, run the
# real bin/start.sh (with tmux/docker stubbed only to CAPTURE its command strings, never to fake
# their result) so whatever mechanism the fix actually uses gets exercised for real.
# Run directly: bash tests/agent-factory-wpq4_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# new_project NAME ENV_CONTENT -> creates a clean git repo at $TMP/NAME with .agent-factory/.env
# pre-seeded with ENV_CONTENT (bypassing bin/init.sh's own id-detection - this story only cares
# about what happens to values already sitting in .env). Prints the project path.
new_project() {
  local p="$TMP/$1"; mkdir -p "$p/.agent-factory"
  git -C "$p" init -q; git -C "$p" config user.email t@t; git -C "$p" config user.name t
  echo x > "$p/f"; git -C "$p" add f; git -C "$p" commit -qm init
  echo '.agent-factory/' > "$p/.git/info/exclude"
  printf '%s' "$2" > "$p/.agent-factory/.env"
  echo "$p"
}

docker_ready() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# build_real PROJECT_DIR PNAME -> builds the `agent` image using the REAL bin/lib.sh (PROJECT_DIR
# exported, dc() sourced unmodified) exactly the way bin/init.sh's `dc build agent` does - no
# --env-file workaround. PNAME sets COMPOSE_PROJECT_NAME (only affects container/network naming,
# not the bug under test) so each test forces a fresh evaluation instead of reusing another test's
# compose state. Build log in $TMP/build.out. Returns 1 on build failure.
build_real() {
  local p="$1" pname="$2"
  ( export PROJECT_DIR="$p" COMPOSE_PROJECT_NAME="$pname"
    source "$REPO_ROOT/bin/lib.sh"
    dc build agent
  ) >"$TMP/build.out" 2>&1
}

# run_real PROJECT_DIR PNAME -- <dc run args...> -> like build_real, then `dc run --rm "$@"`,
# printing its stdout+stderr. Assumes the image was already built (matches bin/start.sh, which
# never rebuilds itself).
run_real() {
  local p="$1" pname="$2"; shift 2
  ( export PROJECT_DIR="$p" COMPOSE_PROJECT_NAME="$pname"
    source "$REPO_ROOT/bin/lib.sh"
    dc run --rm "$@"
  )
}

ENV_ALICE=$'HOST_USER=alice\nHOST_UID=1234\nHOST_GID=1234\n'

test_ac1_dc_build_agent_uses_env_file_identity() {
  docker_ready || { skip "ac1: no docker daemon"; return; }
  local p; p=$(new_project ac1 "$ENV_ALICE")
  build_real "$p" wpq4_ac1 || { fail "ac1: dc build agent failed: $(tail -5 "$TMP/build.out")"; return; }
  local out; out=$(run_real "$p" wpq4_ac1 --entrypoint bash agent -lc 'id -un; id -u; id -g; echo $HOME' 2>&1)
  [ "$(echo "$out" | tail -4)" = $'alice\n1234\n1234\n/home/alice' ] \
    && pass "ac1: bin/init.sh's plain 'dc build agent' produces account alice/1234/1234 /home/alice from .env" \
    || fail "ac1: got: $out"
}

# capture_start_cmds PROJECT_DIR -> runs the REAL bin/start.sh against PROJECT_DIR with tmux and
# docker stubbed (stubs only ever return success and log their argv - they never fabricate a
# result for anything this test later asserts on), capturing the literal command strings pane(),
# ops_cmd and board_cmd construct into $TMP/pane_cmd, $TMP/ops_cmd, $TMP/board_cmd. This exercises
# start.sh's actual command-construction code, so whatever mechanism the eventual fix uses to get
# HOST_* into these strings is captured automatically - nothing here assumes a particular fix.
capture_start_cmds() {
  local p="$1" stubs="$TMP/tmux_stubs" log="$TMP/tmux.log"
  mkdir -p "$stubs"; : > "$log"
  cat > "$stubs/tmux" <<STUB
#!/usr/bin/env bash
{ for a in "\$@"; do printf '%s\x1e' "\$a"; done; printf '\n'; } >> "$log"
[ "\${1:-}" = has-session ] && exit 1
exit 0
STUB
  cat > "$stubs/docker" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$stubs/tmux" "$stubs/docker"
  ( export PROJECT_DIR="$p" SESSION="wpq4cap$$" PATH="$stubs:$PATH"
    bash "$REPO_ROOT/bin/start.sh"
  ) >"$TMP/start.out" 2>&1
  awk -F'\x1e' '$1=="new-session"{print $(NF-1); exit}' "$log" > "$TMP/pane_cmd"
  awk -F'\x1e' '$1=="new-window"{print $(NF-1); exit}' "$log" > "$TMP/ops_cmd"
  awk -F'\x1e' '$1=="split-window"{print $(NF-1); exit}' "$log" > "$TMP/board_cmd"
}

# marker_check CMD_FILE FACTORY_NAME MARKER_DIR -> takes the literal captured command (its
# env-assignment + `docker compose ... run --rm --name factory-<FACTORY_NAME>` prefix is kept
# completely intact - nothing about the mechanism under test is touched), replaces only what
# start.sh puts after `--name factory-<FACTORY_NAME>` with a plain identity/mount check, and runs
# it for real. Prints the container's view of $MARKER_DIR/marker.txt (or an error) so the caller
# can tell whether the real $HOME (baked into the already-built image) matches where Compose's own
# ${CONTAINER_HOME:-/home/${HOST_USER:-agent}} volume interpolation actually mounted the file.
marker_check() {
  local cmd; cmd=$(cat "$1")
  local marker="--name factory-$2"
  [ "$cmd" = "${cmd/$marker/}" ] && { echo "MARKER_NOT_FOUND: $marker not in captured cmd: $cmd"; return 1; }
  local prefix="${cmd%%"$marker"*}$marker"
  bash -c "$prefix --entrypoint bash agent -lc 'cat \"\$HOME/$3/marker.txt\" 2>&1'"
}

test_ac2_pane_delivers_mount_matching_real_home() {
  docker_ready || { skip "ac2: no docker daemon"; return; }
  local p; p=$(new_project ac2pane "$ENV_ALICE")
  build_real "$p" wpq4_ac2pane || { fail "ac2 pane: build failed: $(tail -5 "$TMP/build.out")"; return; }
  capture_start_cmds "$p"
  [ -s "$TMP/pane_cmd" ] || { fail "ac2 pane: start.sh produced no pane() command (see $TMP/start.out)"; return; }
  mkdir -p "$p/.agent-factory/claude/team-lead"; echo MARK > "$p/.agent-factory/claude/team-lead/marker.txt"
  local out; out=$(marker_check "$TMP/pane_cmd" team-lead .claude)
  [ "$out" = MARK ] && pass "ac2: pane() run command mounts .claude at the built image's real \$HOME (alice)" \
    || fail "ac2: pane() command's .claude mount doesn't land at real \$HOME: $out"
}

test_ac2_ops_cmd_delivers_mount_matching_real_home() {
  docker_ready || { skip "ac2: no docker daemon"; return; }
  local p; p=$(new_project ac2ops "$ENV_ALICE")
  build_real "$p" wpq4_ac2ops || { fail "ac2 ops: build failed: $(tail -5 "$TMP/build.out")"; return; }
  capture_start_cmds "$p"
  [ -s "$TMP/ops_cmd" ] || { fail "ac2 ops: start.sh produced no ops_cmd (see $TMP/start.out)"; return; }
  mkdir -p "$p/.agent-factory/claude/shell"; echo MARK > "$p/.agent-factory/claude/shell/marker.txt"
  local out; out=$(marker_check "$TMP/ops_cmd" ops .claude)
  [ "$out" = MARK ] && pass "ac2: ops_cmd mounts .claude at the built image's real \$HOME (alice)" \
    || fail "ac2: ops_cmd's .claude mount doesn't land at real \$HOME: $out"
}

test_ac2_board_cmd_delivers_mount_matching_real_home() {
  docker_ready || { skip "ac2: no docker daemon"; return; }
  local p; p=$(new_project ac2board "$ENV_ALICE")
  build_real "$p" wpq4_ac2board || { fail "ac2 board: build failed: $(tail -5 "$TMP/build.out")"; return; }
  capture_start_cmds "$p"
  [ -s "$TMP/board_cmd" ] || { fail "ac2 board: start.sh produced no board_cmd (see $TMP/start.out)"; return; }
  mkdir -p "$p/.agent-factory/claude/shell"; echo MARK > "$p/.agent-factory/claude/shell/marker.txt"
  local out; out=$(marker_check "$TMP/board_cmd" board .claude)
  [ "$out" = MARK ] && pass "ac2: board_cmd mounts .claude at the built image's real \$HOME (alice)" \
    || fail "ac2: board_cmd's .claude mount doesn't land at real \$HOME: $out"
}

test_ac3_bind_mount_files_owned_by_env_uid_gid() {
  docker_ready || { skip "ac3: no docker daemon"; return; }
  local uid gid; uid=$(id -u); gid=$(id -g)
  local envc; envc=$(printf 'HOST_USER=%s\nHOST_UID=%s\nHOST_GID=%s\n' "$(id -un)" "$uid" "$gid")
  local p; p=$(new_project ac3 "$envc")
  build_real "$p" wpq4_ac3 || { fail "ac3: build failed: $(tail -5 "$TMP/build.out")"; return; }
  local d="$TMP/mnt"; mkdir -p "$d"
  run_real "$p" wpq4_ac3 -v "$d:/mnt/t" --entrypoint bash agent -lc 'touch /mnt/t/f' >/dev/null 2>&1
  [ "$(stat -c %u "$d/f" 2>/dev/null)" = "$uid" ] && [ "$(stat -c %g "$d/f" 2>/dev/null)" = "$gid" ] \
    && pass "ac3: file written through a bind mount is owned by the .env-sourced uid:gid" \
    || fail "ac3: bad ownership (want $uid:$gid): $(stat -c '%u:%g' "$d/f" 2>&1)"
}

test_ac4_missing_host_vars_falls_back_to_literal_defaults() {
  docker_ready || { skip "ac4: no docker daemon"; return; }
  local p; p=$(new_project ac4 $'MAX_TURNS=7\n')
  build_real "$p" wpq4_ac4 || { fail "ac4: dc build agent failed with no HOST_* set: $(tail -5 "$TMP/build.out")"; return; }
  local out; out=$(run_real "$p" wpq4_ac4 --entrypoint bash agent -lc 'id -un; id -u; id -g; echo $HOME' 2>&1)
  [ "$(echo "$out" | tail -4)" = $'agent\n1000\n1000\n/home/agent' ] \
    && pass "ac4: .env with no HOST_USER/HOST_UID/HOST_GID/CONTAINER_HOME still builds/runs with today's defaults" \
    || fail "ac4: got: $out"
}

test_ac5_rerun_is_idempotent() {
  docker_ready || { skip "ac5: no docker daemon"; return; }
  local p; p=$(new_project ac5 "$ENV_ALICE")
  build_real "$p" wpq4_ac5 || { fail "ac5: first dc build agent failed: $(tail -5 "$TMP/build.out")"; return; }
  local out1; out1=$(run_real "$p" wpq4_ac5 --entrypoint bash agent -lc 'id -un; id -u; id -g; echo $HOME' 2>&1)
  build_real "$p" wpq4_ac5 || { fail "ac5: second dc build agent (unchanged .env) failed: $(tail -5 "$TMP/build.out")"; return; }
  local out2; out2=$(run_real "$p" wpq4_ac5 --entrypoint bash agent -lc 'id -un; id -u; id -g; echo $HOME' 2>&1)
  [ "$out1" = "$out2" ] && [ "$(echo "$out1" | tail -4)" = $'alice\n1234\n1234\n/home/alice' ] \
    && pass "ac5: re-running the build with unchanged .env leaves the image's account unchanged" \
    || fail "ac5: identity drifted across rebuilds: first=[$out1] second=[$out2]"
}

test_ac6_arch_docs_explain_how_build_args_reach_compose() {
  grep -qiE 'HOST_UID|HOST_GID|HOST_USER' docs/ARCHITECTURE.md \
    || { fail "ac6: ARCHITECTURE.md no longer documents HOST_UID/HOST_GID/HOST_USER at all"; return; }
  grep -qiE 'env-file|--env-file|exported|shell environment|\bdc\(\)' docs/ARCHITECTURE.md \
    && pass "ac6: ARCHITECTURE.md explains how HOST_* values actually reach Compose's build-arg interpolation" \
    || fail "ac6: ARCHITECTURE.md documents HOST_UID/HOST_GID/HOST_USER as build args but never explains how they reach Compose's own interpolation (vs. just being written to .env) - see agent-factory-wpq4"
}

test_ac6_no_stale_env_file_delivers_build_args_claim() {
  local out; out=$(grep -niE 'env_file' README.md docs/ARCHITECTURE.md | grep -iE 'HOST_UID|HOST_GID|HOST_USER|build.?arg')
  [ -z "$out" ] && pass "ac6: no doc claims the runtime env_file: mechanism is what delivers HOST_* to the image build" \
    || fail "ac6: $out"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "passed=$PASS failed=$FAIL skipped=$SKIP"
[ "$FAIL" -eq 0 ]
