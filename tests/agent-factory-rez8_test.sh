#!/usr/bin/env bash
# Acceptance tests for agent-factory-rez8: shutdown vs. startup (bin/stop.sh / bin/start.sh).
# One function per acceptance criterion in docs/stories/agent-factory-rez8.md (test_acN_...).
# Run directly: bash tests/agent-factory-rez8_test.sh
#
# AC4 and AC6 (stop.sh "now" and "clear") are pure command-composition checks: a fake `tmux` and
# `docker` go on PATH (state-tracking, logging every invocation - same technique as
# tests/acceptance/agent-factory-uhc.sh uses for bin/start.sh), so no real docker/tmux is needed.
#
# AC2, AC3 and AC5 exercise bin/start.sh's own has-session / STOP-cleanup / pane-creation logic in
# isolation, also via the fake tmux+docker, by directly constructing the *post-condition* state
# AC1's fix is responsible for producing (tmux session gone after a completed graceful stop, or
# killed by `now`) rather than trying to reproduce how it got there. Per the story's own Context
# section, start.sh's unconditional "rm STOP, then create all 6 role panes" logic already does the
# right thing today WHENEVER the has-session check correctly reports no session - the bug that
# breaks AC2/AC3/AC5 in real operation is entirely AC1's missing teardown, not a separate bug in
# start.sh. So it is expected and correct for AC2/AC3/AC5 to already PASS here before this story's
# implementation lands (regression guards, same convention as agent-factory-uhc_test.sh's AC6) -
# AC1 is the one this story must actually make pass.
#
# AC1 is a real end-to-end behaviour (something must notice that every role container has exited
# and then tear down ops/board/tmux with no further operator command) that no fake can stand in
# for without assuming a specific implementation mechanism this story hasn't chosen yet. It runs
# against real docker + real tmux, using lightweight stand-in containers (factory-agent:latest,
# overridden to just `sleep`) for the 8 containers stop.sh/start.sh actually name, and SKIPs
# whenever docker, tmux, or the factory-agent:latest image aren't available - true in this
# environment (no docker daemon, no tmux binary) - or whenever a real factory-* container with one
# of these names already exists, to avoid ever touching an operator's actually-running factory.
#
# Written BEFORE implementation (stage:tests): AC1 is expected to SKIP (docker/tmux missing) or,
# on a machine that does have them, to FAIL right now, since neither stop.sh nor start.sh has any
# mechanism yet to tear down ops/board/the tmux session once role agents exit. AC4 is expected to
# FAIL today: stop.sh's `now` container list omits team-lead (bin/stop.sh:13).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR" || exit 1
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }

# --- fixtures -----------------------------------------------------------------------------
cleanup_dirs=()
cleanup_cmds=()
trap 'for c in "${cleanup_cmds[@]}"; do eval "$c" >/dev/null 2>&1 || true; done; for d in "${cleanup_dirs[@]}"; do rm -rf "$d"; done' EXIT

make_tmpproject() {  # scratch git repo standing in for PROJECT_DIR
  local d
  d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t.example -c user.name=t commit -q --allow-empty -m init
  cleanup_dirs+=("$d")
  echo "$d"
}

# Fake tmux: logs every invocation (tab-separated args, one call per line) to $TMUX_FAKE_LOG, and
# tracks only the bit of state stop.sh/start.sh actually branch on (does the session exist) -
# has-session/new-session/kill-session all update $TMUX_FAKE_STATE/exists; every other subcommand
# is just logged. Fake docker: logs every invocation to $DOCKER_FAKE_LOG and exits 0.
install_fakes() {  # install_fakes <bindir>
  local dir=$1
  cat > "$dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
{ args=("$@"); (IFS=$'\t'; echo "${args[*]}"); } >> "$TMUX_FAKE_LOG"
case "${1:-}" in
  has-session)   [ -f "$TMUX_FAKE_STATE/exists" ] && exit 0 || exit 1 ;;
  new-session)   mkdir -p "$TMUX_FAKE_STATE"; touch "$TMUX_FAKE_STATE/exists" ;;
  kill-session)  rm -f "$TMUX_FAKE_STATE/exists" ;;
esac
exit 0
FAKE_TMUX
  chmod +x "$dir/tmux"
  cat > "$dir/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
{ args=("$@"); (IFS=$'\t'; echo "${args[*]}"); } >> "${DOCKER_FAKE_LOG:-/dev/null}"
exit 0
FAKE_DOCKER
  chmod +x "$dir/docker"
}

# Parses the fake tmux log into "<window>\t<cmd>" lines for new-session/split-window/new-window
# calls, in log order - same parser as agent-factory-uhc_test.sh uses.
parsed_pane_creation_calls() {  # <log>
  awk -F'\t' '
    $1=="new-session" || $1=="split-window" || $1=="new-window" {
      window=""
      if ($1=="split-window") {
        for (i=1;i<=NF;i++) if ($i=="-t") { n=split($(i+1), p, ":"); window=p[n] }
      } else {
        for (i=1;i<=NF;i++) if ($i=="-n") { window=$(i+1) }
      }
      printf "%s\t%s\n", window, $NF
    }
  ' "$1"
}
pane_cmds_for_window()  { parsed_pane_creation_calls "$1" | awk -F'\t' -v w="$2" '$1==w {print $2}'; }
pane_roles_for_window() { pane_cmds_for_window "$1" "$2" | grep -oE 'ROLE=[A-Za-z_-]+' | sed 's/ROLE=//'; }
count_lines() { [ -n "$1" ] && printf '%s\n' "$1" | grep -c . || echo 0; }

# run_start_sh <fakebin> <tmux_log> <tmux_state> <docker_log> <project> <session>
run_start_sh() {
  PATH="$1:$PATH" TMUX_FAKE_LOG="$2" TMUX_FAKE_STATE="$3" DOCKER_FAKE_LOG="$4" \
    SESSION="$6" PROJECT_DIR="$5" bash "$KIT_DIR/bin/start.sh" > "$TMP_OUT" 2>&1
  echo $?
}

# ============================================================
# AC2: after a completed graceful stop (session already gone - AC1's job), start.sh removes any
# leftover STOP flags and actually launches every role's agent-loop pane.
# ============================================================
test_ac2_start_clears_stop_and_launches_all_six_roles() {
  local proj fakebin tmux_log tmux_state docker_log session status
  proj=$(make_tmpproject)
  mkdir -p "$proj/.agent-factory/control"
  touch "$proj/.agent-factory/control/STOP" "$proj/.agent-factory/control/STOP.qa"
  fakebin=$(mktemp -d); cleanup_dirs+=("$fakebin"); install_fakes "$fakebin"
  tmux_log=$(mktemp); cleanup_dirs+=("$tmux_log")
  tmux_state=$(mktemp -d); cleanup_dirs+=("$tmux_state")   # no "exists" marker: session is gone
  docker_log=$(mktemp); cleanup_dirs+=("$docker_log")
  session="rez8-ac2-$$-$RANDOM"
  TMP_OUT=$(mktemp); cleanup_dirs+=("$TMP_OUT")

  status=$(run_start_sh "$fakebin" "$tmux_log" "$tmux_state" "$docker_log" "$proj" "$session")
  if [ "$status" -ne 0 ]; then
    fail "ac2: bin/start.sh exited $status with no pre-existing session; output: $(cat "$TMP_OUT")"
    return
  fi
  if [ -f "$proj/.agent-factory/control/STOP" ] || [ -f "$proj/.agent-factory/control/STOP.qa" ]; then
    fail "ac2: STOP flag(s) still present after start.sh ran against a session-free state"
    return
  fi
  local roles sorted expected
  roles=$(pane_roles_for_window "$tmux_log" agents)
  sorted=$(sort <<<"$roles")
  expected=$(printf '%s\n' po architect qa engineer reviewer team-lead | sort)
  if [ "$sorted" != "$expected" ]; then
    fail "ac2: agents window pane ROLE set was [$(tr '\n' ' ' <<<"$roles")], expected exactly {po,architect,qa,engineer,reviewer,team-lead} - a leftover STOP flag must not block any role's pane from actually running its agent loop"
    return
  fi
  pass "ac2: with no session already running, start.sh clears leftover STOP flags and launches all six roles' agent-loop panes"
}

# ============================================================
# AC3: unchanged - a genuinely still-running factory (session alive) makes start.sh short-circuit
# with "Already running", exit 0, and alter nothing.
# ============================================================
test_ac3_already_running_short_circuits_unchanged() {
  local proj fakebin tmux_log tmux_state docker_log session status calls
  proj=$(make_tmpproject)
  fakebin=$(mktemp -d); cleanup_dirs+=("$fakebin"); install_fakes "$fakebin"
  tmux_log=$(mktemp); cleanup_dirs+=("$tmux_log")
  tmux_state=$(mktemp -d); cleanup_dirs+=("$tmux_state"); mkdir -p "$tmux_state"; touch "$tmux_state/exists"
  docker_log=$(mktemp); cleanup_dirs+=("$docker_log")
  session="rez8-ac3-$$-$RANDOM"
  TMP_OUT=$(mktemp); cleanup_dirs+=("$TMP_OUT")

  status=$(run_start_sh "$fakebin" "$tmux_log" "$tmux_state" "$docker_log" "$proj" "$session")
  if [ "$status" -ne 0 ]; then
    fail "ac3: bin/start.sh exited $status against an already-running session, expected 0; output: $(cat "$TMP_OUT")"
    return
  fi
  if ! grep -q 'Already running' "$TMP_OUT"; then
    fail "ac3: bin/start.sh didn't print 'Already running' against an already-running session; output: $(cat "$TMP_OUT")"
    return
  fi
  calls=$(wc -l < "$tmux_log" | tr -d ' ')
  if [ "$calls" -ne 1 ]; then
    fail "ac3: bin/start.sh issued $calls tmux command(s) against an already-running session (expected exactly 1: has-session) - it altered something instead of short-circuiting; log: $(cat "$tmux_log")"
    return
  fi
  pass "ac3: a genuinely still-running factory still short-circuits with 'Already running', exits 0, and issues no other tmux commands"
}

# ============================================================
# AC4: stop.sh now stops all six role containers plus ops and board, and kills the tmux session,
# immediately - closing the current gap where team-lead is left running.
# ============================================================
test_ac4_now_stops_all_roles_plus_ops_board_and_kills_session() {
  local proj fakebin tmux_log tmux_state docker_log session status stopped expected
  proj=$(make_tmpproject)
  fakebin=$(mktemp -d); cleanup_dirs+=("$fakebin"); install_fakes "$fakebin"
  tmux_log=$(mktemp); cleanup_dirs+=("$tmux_log")
  tmux_state=$(mktemp -d); cleanup_dirs+=("$tmux_state"); mkdir -p "$tmux_state"; touch "$tmux_state/exists"
  docker_log=$(mktemp); cleanup_dirs+=("$docker_log")
  session="rez8-ac4-$$-$RANDOM"

  PATH="$fakebin:$PATH" TMUX_FAKE_LOG="$tmux_log" TMUX_FAKE_STATE="$tmux_state" DOCKER_FAKE_LOG="$docker_log" \
    SESSION="$session" PROJECT_DIR="$proj" bash "$KIT_DIR/bin/stop.sh" now > "$TMP_OUT2" 2>&1
  status=$?
  if [ "$status" -ne 0 ]; then
    fail "ac4: bin/stop.sh now exited $status; output: $(cat "$TMP_OUT2")"
    return
  fi
  stopped=$(grep -E '^stop\b' "$docker_log" | tr '\t' '\n' | grep -v '^stop$' | sort -u)
  expected=$(printf '%s\n' factory-po factory-architect factory-qa factory-engineer factory-reviewer factory-team-lead factory-ops factory-board | sort)
  if [ "$stopped" != "$expected" ]; then
    fail "ac4: 'docker stop' was called for [$(tr '\n' ' ' <<<"$stopped")], expected exactly the eight factory-* containers po/architect/qa/engineer/reviewer/team-lead/ops/board - team-lead must not be left out"
    return
  fi
  if ! grep -qE "^kill-session\s.*$session" "$tmux_log"; then
    fail "ac4: tmux kill-session for session '$session' was not issued; log: $(cat "$tmux_log")"
    return
  fi
  pass "ac4: stop.sh now stops all six role containers (including team-lead) plus ops and board, and kills the tmux session"
}

# ============================================================
# AC5: after stop.sh now has torn everything down, start.sh starts a fresh session the same way
# as AC2 - no leftover STOP flag (even one dating from an earlier graceful attempt) blocks it.
# ============================================================
test_ac5_start_after_now_clears_leftover_stop_and_launches_all_six_roles() {
  local proj fakebin tmux_log tmux_state docker_log session status roles sorted expected
  proj=$(make_tmpproject)
  fakebin=$(mktemp -d); cleanup_dirs+=("$fakebin"); install_fakes "$fakebin"
  tmux_state=$(mktemp -d); cleanup_dirs+=("$tmux_state"); mkdir -p "$tmux_state"; touch "$tmux_state/exists"
  session="rez8-ac5-$$-$RANDOM"

  tmux_log=$(mktemp); cleanup_dirs+=("$tmux_log")
  docker_log=$(mktemp); cleanup_dirs+=("$docker_log")
  TMP_OUT2=$(mktemp); cleanup_dirs+=("$TMP_OUT2")
  PATH="$fakebin:$PATH" TMUX_FAKE_LOG="$tmux_log" TMUX_FAKE_STATE="$tmux_state" DOCKER_FAKE_LOG="$docker_log" \
    SESSION="$session" PROJECT_DIR="$proj" bash "$KIT_DIR/bin/stop.sh" now > "$TMP_OUT2" 2>&1
  status=$?
  if [ "$status" -ne 0 ] || [ -f "$tmux_state/exists" ]; then
    fail "ac5: setup step (stop.sh now) didn't leave the session torn down (status=$status, exists=$([ -f "$tmux_state/exists" ] && echo yes || echo no)); output: $(cat "$TMP_OUT2")"
    return
  fi
  # Leftover STOP flag, e.g. from an earlier graceful attempt the operator gave up waiting on.
  mkdir -p "$proj/.agent-factory/control"
  touch "$proj/.agent-factory/control/STOP"

  tmux_log=$(mktemp); cleanup_dirs+=("$tmux_log")   # fresh log for the start.sh call itself
  docker_log=$(mktemp); cleanup_dirs+=("$docker_log")
  TMP_OUT=$(mktemp); cleanup_dirs+=("$TMP_OUT")
  status=$(run_start_sh "$fakebin" "$tmux_log" "$tmux_state" "$docker_log" "$proj" "$session")
  if [ "$status" -ne 0 ]; then
    fail "ac5: bin/start.sh exited $status after stop.sh now; output: $(cat "$TMP_OUT")"
    return
  fi
  if [ -f "$proj/.agent-factory/control/STOP" ]; then
    fail "ac5: leftover STOP flag still present after start.sh ran following stop.sh now"
    return
  fi
  roles=$(pane_roles_for_window "$tmux_log" agents)
  sorted=$(sort <<<"$roles")
  expected=$(printf '%s\n' po architect qa engineer reviewer team-lead | sort)
  if [ "$sorted" != "$expected" ]; then
    fail "ac5: agents window pane ROLE set was [$(tr '\n' ' ' <<<"$roles")], expected exactly {po,architect,qa,engineer,reviewer,team-lead}"
    return
  fi
  pass "ac5: after stop.sh now, start.sh clears a leftover STOP flag and launches all six roles the same way as after a completed graceful stop"
}

# ============================================================
# AC6: stop.sh clear continues to only remove STOP flag files - no docker/tmux side effects.
# ============================================================
test_ac6_clear_only_removes_stop_flags() {
  local proj fakebin tmux_log tmux_state docker_log session status
  proj=$(make_tmpproject)
  mkdir -p "$proj/.agent-factory/control"
  touch "$proj/.agent-factory/control/STOP" "$proj/.agent-factory/control/STOP.po" "$proj/.agent-factory/control/STOP.qa"
  echo keep > "$proj/.agent-factory/control/not-a-stop-file"
  fakebin=$(mktemp -d); cleanup_dirs+=("$fakebin"); install_fakes "$fakebin"
  tmux_log=$(mktemp); cleanup_dirs+=("$tmux_log")
  tmux_state=$(mktemp -d); cleanup_dirs+=("$tmux_state")
  docker_log=$(mktemp); cleanup_dirs+=("$docker_log")
  session="rez8-ac6-$$-$RANDOM"
  TMP_OUT=$(mktemp); cleanup_dirs+=("$TMP_OUT")

  PATH="$fakebin:$PATH" TMUX_FAKE_LOG="$tmux_log" TMUX_FAKE_STATE="$tmux_state" DOCKER_FAKE_LOG="$docker_log" \
    SESSION="$session" PROJECT_DIR="$proj" bash "$KIT_DIR/bin/stop.sh" clear > "$TMP_OUT" 2>&1
  status=$?
  if [ "$status" -ne 0 ]; then
    fail "ac6: bin/stop.sh clear exited $status; output: $(cat "$TMP_OUT")"
    return
  fi
  if [ -f "$proj/.agent-factory/control/STOP" ] || [ -f "$proj/.agent-factory/control/STOP.po" ] || [ -f "$proj/.agent-factory/control/STOP.qa" ]; then
    fail "ac6: a STOP flag file survived stop.sh clear"
    return
  fi
  if [ ! -f "$proj/.agent-factory/control/not-a-stop-file" ]; then
    fail "ac6: stop.sh clear removed a file that wasn't a STOP flag"
    return
  fi
  if [ -s "$tmux_log" ] || [ -s "$docker_log" ]; then
    fail "ac6: stop.sh clear issued tmux/docker commands - it must have no effect on running containers or the tmux session; tmux log: $(cat "$tmux_log"), docker log: $(cat "$docker_log")"
    return
  fi
  pass "ac6: stop.sh clear removes only STOP flag files and has no effect on containers or the tmux session"
}

# ============================================================
# AC1: once every role agent has exited after a graceful stop, ops and board are also stopped and
# the tmux session no longer exists, with no further manual commands. Needs real docker + tmux -
# no fake can stand in for "something notices the containers exited" without assuming a mechanism
# this story hasn't designed yet.
# ============================================================
ROLE_CONTAINERS=(po architect qa engineer reviewer team-lead)
ALL_CONTAINERS=(po architect qa engineer reviewer team-lead ops board)

docker_ready()     { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
have_tmux_bin()    { command -v tmux >/dev/null 2>&1; }
have_agent_image() { docker image inspect factory-agent:latest >/dev/null 2>&1; }
no_live_factory_containers() {
  ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE '^factory-(po|architect|qa|engineer|reviewer|team-lead|ops|board)$'
}

test_ac1_graceful_teardown_of_ops_board_and_session_once_agents_exit() {
  if ! docker_ready; then skip "ac1: no docker daemon available"; return; fi
  if ! have_tmux_bin; then skip "ac1: tmux is not installed"; return; fi
  if ! have_agent_image; then skip "ac1: factory-agent:latest image not built locally"; return; fi
  if ! no_live_factory_containers; then
    skip "ac1: a real factory-* container already exists on this host - refusing to run a test that could interfere with an actually-running factory"
    return
  fi

  local proj session c
  proj=$(make_tmpproject)
  session="rez8-ac1-$$-$RANDOM"

  tmux new-session -d -s "$session" -n agents "sleep 3600" || { fail "ac1: couldn't start a real tmux session for the test fixture"; return; }
  cleanup_cmds+=("tmux kill-session -t '$session'")

  for c in "${ALL_CONTAINERS[@]}"; do
    docker run -d --rm --name "factory-$c" --entrypoint sleep factory-agent:latest 3600 >/dev/null 2>&1 \
      || { fail "ac1: couldn't start stand-in container factory-$c"; return; }
    cleanup_cmds+=("docker rm -f factory-$c")
  done

  ( PROJECT_DIR="$proj" SESSION="$session" bash "$KIT_DIR/bin/stop.sh" graceful >/dev/null 2>&1 ) &
  local stop_pid=$!
  sleep 1
  if [ ! -f "$proj/.agent-factory/control/STOP" ]; then
    fail "ac1: bin/stop.sh graceful did not set the STOP flag"
    kill "$stop_pid" 2>/dev/null || true
    return
  fi

  # Simulate every role agent finishing its current session and exiting on its own (what
  # agent-loop.sh's stopping()/exit 0 would eventually cause) - not a further manual command by
  # the operator, just the natural attrition AC1 describes.
  for c in "${ROLE_CONTAINERS[@]}"; do docker stop "factory-$c" >/dev/null 2>&1 & done
  wait

  local waited=0 ops_gone=0 board_gone=0 session_gone=0
  while [ "$waited" -lt 30 ]; do
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'factory-ops'   || ops_gone=1
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'factory-board' || board_gone=1
    tmux has-session -t "$session" 2>/dev/null || session_gone=1
    [ "$ops_gone" = 1 ] && [ "$board_gone" = 1 ] && [ "$session_gone" = 1 ] && break
    sleep 1; waited=$((waited + 1))
  done
  kill "$stop_pid" 2>/dev/null || true

  if [ "$ops_gone" != 1 ] || [ "$board_gone" != 1 ] || [ "$session_gone" != 1 ]; then
    fail "ac1: after every role agent exited, within ${waited}s: ops stopped=$ops_gone board stopped=$board_gone tmux session gone=$session_gone (all must be 1, with no further manual commands beyond the original 'stop.sh graceful')"
    return
  fi
  pass "ac1: once every role agent has exited following stop.sh graceful, ops and board are stopped and the tmux session is gone, with no further manual commands"
}

# ============================================================
# Cross-cutting: shellcheck the touched scripts (docs/ARCHITECTURE.md convention for bash
# changes). Not tied to a single AC; informational quality gate for the implementer.
# ============================================================
test_shellcheck_touched_scripts() {
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip "shellcheck: not installed in this environment"
    return
  fi
  if (cd bin && shellcheck -x stop.sh start.sh); then
    pass "shellcheck: bin/stop.sh, bin/start.sh clean"
  else
    fail "shellcheck: findings in bin/stop.sh and/or bin/start.sh"
  fi
}

TMP_OUT=$(mktemp); cleanup_dirs+=("$TMP_OUT")
TMP_OUT2=$(mktemp); cleanup_dirs+=("$TMP_OUT2")

test_ac1_graceful_teardown_of_ops_board_and_session_once_agents_exit
test_ac2_start_clears_stop_and_launches_all_six_roles
test_ac3_already_running_short_circuits_unchanged
test_ac4_now_stops_all_roles_plus_ops_board_and_kills_session
test_ac5_start_after_now_clears_leftover_stop_and_launches_all_six_roles
test_ac6_clear_only_removes_stop_flags
test_shellcheck_touched_scripts

echo "---"
echo "passed=$PASS failed=$FAIL skipped=$SKIP"
[ "$FAIL" -eq 0 ]
