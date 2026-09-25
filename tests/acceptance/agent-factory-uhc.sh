#!/usr/bin/env bash
# Acceptance tests for agent-factory-uhc (tmux layout: move board into ops, give team-lead its
# old slot). One test function per acceptance criterion in docs/stories/agent-factory-uhc.md -
# see that file for the criteria these are derived from. No unit-test framework applies here
# (docs/ARCHITECTURE.md "Test strategy"); this is a plain shell acceptance script, run directly:
#   bash tests/acceptance/agent-factory-uhc.sh
# PASS/FAIL/SKIP is printed per criterion; overall exit is non-zero if any criterion FAILs.
#
# bin/start.sh's job is to issue a specific sequence of `tmux` (and `docker compose`) commands.
# Rather than requiring a real tmux/docker to be installed (bin/start.sh runs on the *host*, so
# neither is expected to be present inside an agent's own container - confirmed absent in this
# environment: no tmux binary, no docker daemon, no root to install either), most tests here
# replace both `tmux` and `docker` on PATH with fake scripts that just log every invocation
# verbatim. That makes the pane-composition/order/options criteria (AC1, AC2, AC3, AC5, AC6, AC7)
# fully testable anywhere, by inspecting the exact commands bin/start.sh issued. AC4 (real pane
# *geometry* - above/below, rendered height) has no such proxy - a fake tmux can't compute layout
# - so it requires a real tmux and SKIPs where one isn't installed, same convention as this
# project's existing docker-dependent acceptance tests (e.g. tests/acceptance/agent-factory-jqn.sh)
# use for an absent docker/factory-agent:latest.
#
# Written before the implementation exists (stage:tests): every test here targets bin/start.sh as
# it is DESIGNED to behave per the story, not as it behaves today. Until this story's
# implementation lands (and agent-factory-dx0's team-lead support is on main), AC1/AC2/AC3/AC5/AC7
# are all expected to FAIL for that reason - that is a correct failure, not a broken test. AC6 is
# expected to PASS already (unchanged behaviour).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$KIT_DIR"

pass=0
fail=0
skip=0

ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
skp() { echo "SKIP: $1"; skip=$((skip+1)); }

have_tmux()       { command -v tmux >/dev/null 2>&1; }
have_shellcheck() { command -v shellcheck >/dev/null 2>&1; }

# --- fixtures -----------------------------------------------------------------------------
cleanup_dirs=()
trap 'for d in "${cleanup_dirs[@]}"; do rm -rf "$d"; done' EXIT

make_tmpproject() {  # scratch git repo standing in for PROJECT_DIR
  # NB: never call this as `x=$(make_tmpproject)` - command substitution runs in a subshell, so
  # the cleanup_dirs+=() below would be lost. Callers register cleanup themselves instead.
  local d
  d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t.example -c user.name=t commit -q --allow-empty -m init
  echo "$d"
}

# Fake tmux: logs every invocation (tab-separated args, one call per line) to $TMUX_FAKE_LOG, and
# tracks only the one bit of state bin/start.sh actually branches on (does the session exist).
# Fake docker: logs every invocation to $DOCKER_FAKE_LOG and exits 0 - stands in both for `dc up
# -d dolt` (real docker, run directly by start.sh) and for the `docker compose run ...` command
# strings tmux is asked to launch in each pane (never actually executed by our fake tmux, since it
# doesn't really spawn panes - it only records what it was asked to do).
install_fake_tmux_and_docker() {  # install_fake_tmux_and_docker <dir>
  local dir=$1
  cat > "$dir/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
{ args=("$@"); (IFS=$'\t'; echo "${args[*]}"); } >> "$TMUX_FAKE_LOG"
case "${1:-}" in
  has-session)
    [ -f "$TMUX_FAKE_STATE/exists" ] && exit 0 || exit 1 ;;
  new-session)
    mkdir -p "$TMUX_FAKE_STATE"
    touch "$TMUX_FAKE_STATE/exists" ;;
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

# Parses the fake tmux log into "<window>\t<cmd>" lines, one per pane-creation call
# (new-session/split-window/new-window), in log order - independent of flag order or which
# helper/flags bin/start.sh's implementation uses to issue them.
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

pane_cmds_for_window() { parsed_pane_creation_calls "$1" | awk -F'\t' -v w="$2" '$1==w {print $2}'; }
pane_roles_for_window() { pane_cmds_for_window "$1" "$2" | grep -oE 'ROLE=[A-Za-z_-]+' | sed 's/ROLE=//'; }

# Parses "<window> set-option -w ..." calls into "<option>=<value>" lines for the given window.
set_option_calls_for_window() {  # <log> <window>
  awk -F'\t' -v w="$2" '
    $1=="set-option" {
      target=""; opt_start=0
      for (i=1;i<=NF;i++) if ($i=="-t") { n=split($(i+1),p,":"); target=p[n]; opt_start=i+2 }
      if (target==w && opt_start>0) {
        opt=$(opt_start); val=""
        for (i=opt_start+1;i<=NF;i++) val = val (val=="" ? "" : " ") $i
        print opt "=" val
      }
    }
  ' "$1"
}

count_lines() { [ -n "$1" ] && printf '%s\n' "$1" | grep -c . || echo 0; }

LAST_STDOUT=""
LAST_STATUS=0
LAST_TMUX_LOG=""
LAST_SESSION=""

run_start_sh() {  # run_start_sh <0|1: session already exists>
  local pre_exists=$1
  local proj fakebin tmux_log docker_log state_dir session
  proj=$(make_tmpproject); cleanup_dirs+=("$proj")
  fakebin=$(mktemp -d); cleanup_dirs+=("$fakebin")
  install_fake_tmux_and_docker "$fakebin"
  tmux_log=$(mktemp); cleanup_dirs+=("$tmux_log")
  docker_log=$(mktemp); cleanup_dirs+=("$docker_log")
  state_dir=$(mktemp -d); cleanup_dirs+=("$state_dir")
  session="uhc-test-$$-$RANDOM"
  if [ "$pre_exists" = 1 ]; then
    mkdir -p "$state_dir"
    touch "$state_dir/exists"
  fi
  LAST_STDOUT=$(PATH="$fakebin:$PATH" TMUX_FAKE_LOG="$tmux_log" TMUX_FAKE_STATE="$state_dir" \
                DOCKER_FAKE_LOG="$docker_log" SESSION="$session" PROJECT_DIR="$proj" \
                bash "$KIT_DIR/bin/start.sh" 2>&1)
  LAST_STATUS=$?
  LAST_TMUX_LOG=$tmux_log
  LAST_SESSION=$session
}

EXPECTED_ROLES=(po architect qa engineer reviewer team-lead)

# AC1: agents window has exactly six panes, one per role in po/architect/qa/engineer/reviewer/
# team-lead, and no board pane.
test_ac1_agents_window_six_role_panes_no_board() {
  run_start_sh 0
  local roles count cmds sorted expected_sorted
  roles=$(pane_roles_for_window "$LAST_TMUX_LOG" agents)
  count=$(count_lines "$roles")
  if [ "$count" -ne 6 ]; then
    bad "ac1: agents window has $count pane-creation calls, expected exactly 6 (one per role); stdout: $LAST_STDOUT"
    return
  fi
  sorted=$(sort <<<"$roles")
  expected_sorted=$(printf '%s\n' "${EXPECTED_ROLES[@]}" | sort)
  if [ "$sorted" != "$expected_sorted" ]; then
    bad "ac1: agents window ROLE set was [$(tr '\n' ' ' <<<"$roles")], expected exactly {po,architect,qa,engineer,reviewer,team-lead}"
    return
  fi
  cmds=$(pane_cmds_for_window "$LAST_TMUX_LOG" agents)
  if grep -q 'board\.sh' <<<"$cmds"; then
    bad "ac1: agents window still runs board.sh in one of its panes - board must be removed from the agents window"
    return
  fi
  ok "ac1: agents window has exactly 6 panes, one per role (po architect qa engineer reviewer team-lead), and no board pane"
}

# AC2: team-lead occupies board's old (first) slot; the other five roles keep their existing
# relative order.
test_ac2_team_lead_first_others_keep_order() {
  run_start_sh 0
  local roles_ordered expected
  roles_ordered=$(pane_roles_for_window "$LAST_TMUX_LOG" agents)
  expected=$(printf '%s\n' team-lead po architect qa engineer reviewer)
  if [ "$roles_ordered" != "$expected" ]; then
    bad "ac2: agents window pane-creation order was [$(tr '\n' ' ' <<<"$roles_ordered")], expected [team-lead po architect qa engineer reviewer] (team-lead first, in board's old slot; others unchanged)"
    return
  fi
  ok "ac2: team-lead is created first (board's former slot); po architect qa engineer reviewer keep their relative order"
}

# AC3: ops window contains exactly two panes: the pre-existing interactive shell pane, and a
# board pane running the same command board.sh was run with in the agents window before this
# change (ROLE=shell, --entrypoint bash agent, bin/board.sh).
test_ac3_ops_window_shell_and_board() {
  run_start_sh 0
  local cmds count shell_cmd board_cmd
  cmds=$(pane_cmds_for_window "$LAST_TMUX_LOG" ops)
  count=$(count_lines "$cmds")
  if [ "$count" -ne 2 ]; then
    bad "ac3: ops window has $count pane-creation calls, expected exactly 2 (shell + board); calls: [$cmds]"
    return
  fi
  shell_cmd=$(grep 'ops-shell\.sh' <<<"$cmds" || true)
  board_cmd=$(grep 'board\.sh' <<<"$cmds" || true)
  if [ -z "$shell_cmd" ]; then
    bad "ac3: ops window is missing the pre-existing interactive shell pane (bin/ops-shell.sh); calls: [$cmds]"
    return
  fi
  if [ -z "$board_cmd" ]; then
    bad "ac3: ops window is missing a board pane (bin/board.sh); calls: [$cmds]"
    return
  fi
  if ! grep -q 'ROLE=shell' <<<"$board_cmd" || ! grep -q -- '--entrypoint bash agent' <<<"$board_cmd"; then
    bad "ac3: ops window's board pane doesn't run the same command board.sh was run with in the agents window before this change (expected ROLE=shell, --entrypoint bash agent, .../bin/board.sh); got: $board_cmd"
    return
  fi
  ok "ac3: ops window has exactly two panes - the pre-existing shell pane and a board pane running the same command board.sh was run with before"
}

# AC4: the board pane is positioned above the shell pane in the ops window, sized to
# approximately one third of the window's height. Needs a real tmux to compute actual rendered
# geometry (top offset, height) - a fake tmux can log flags but can't tell us where tmux itself
# would actually place/size the panes, so this SKIPs without one.
test_ac4_board_pane_above_and_one_third_height() {
  if ! have_tmux; then
    skp "ac4: tmux is not installed in this environment - cannot verify real pane geometry (board above shell, sized ~1/3 of the ops window's height)"
    return
  fi
  local proj fakebin docker_log session out status
  proj=$(make_tmpproject); cleanup_dirs+=("$proj")
  fakebin=$(mktemp -d); cleanup_dirs+=("$fakebin")
  install_fake_tmux_and_docker "$fakebin"
  docker_log=$(mktemp); cleanup_dirs+=("$docker_log")
  session="uhc-ac4-$$-$RANDOM"
  out=$(PATH="$fakebin:$PATH" DOCKER_FAKE_LOG="$docker_log" SESSION="$session" PROJECT_DIR="$proj" \
        bash "$KIT_DIR/bin/start.sh" 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    bad "ac4: bin/start.sh exited $status under a real tmux; output: $out"
    tmux kill-session -t "$session" 2>/dev/null || true
    return
  fi
  local geo board_line shell_line board_top board_height win_height shell_top pct
  geo=$(tmux list-panes -t "$session:ops" -F '#{pane_top}	#{pane_height}	#{window_height}	#{pane_start_command}' 2>&1)
  tmux kill-session -t "$session" 2>/dev/null || true
  board_line=$(grep 'board\.sh' <<<"$geo" || true)
  shell_line=$(grep 'ops-shell\.sh' <<<"$geo" || true)
  if [ -z "$board_line" ] || [ -z "$shell_line" ]; then
    bad "ac4: couldn't find both a board.sh pane and an ops-shell.sh pane in the ops window's real layout; list-panes output: [$geo]"
    return
  fi
  board_top=$(cut -f1 <<<"$board_line")
  board_height=$(cut -f2 <<<"$board_line")
  win_height=$(cut -f3 <<<"$board_line")
  shell_top=$(cut -f1 <<<"$shell_line")
  if [ "$board_top" -ge "$shell_top" ]; then
    bad "ac4: board pane (top=$board_top) is not above the shell pane (top=$shell_top) in the ops window"
    return
  fi
  pct=$(( board_height * 100 / win_height ))
  if [ "$pct" -lt 20 ] || [ "$pct" -gt 45 ]; then
    bad "ac4: board pane height is $board_height/$win_height (${pct}%) of the ops window, expected approximately one third (20-45%)"
    return
  fi
  ok "ac4: board pane sits above the shell pane in the ops window, sized ~${pct}% (~1/3) of the window's height"
}

# AC5: the agents window's remain-on-exit / pane-border-status / pane-border-format window
# options are also set on the ops window.
test_ac5_ops_window_options_match_agents() {
  run_start_sh 0
  local agents_opts ops_opts want
  agents_opts=$(set_option_calls_for_window "$LAST_TMUX_LOG" agents | sort)
  ops_opts=$(set_option_calls_for_window "$LAST_TMUX_LOG" ops | sort)
  want=$(printf '%s\n' 'remain-on-exit=on' 'pane-border-status=top' 'pane-border-format=#{pane_title}' | sort)
  if [ "$agents_opts" != "$want" ]; then
    bad "ac5: agents window's own remain-on-exit/pane-border-status/pane-border-format options changed unexpectedly: got [$agents_opts]"
    return
  fi
  if [ "$ops_opts" != "$want" ]; then
    bad "ac5: ops window doesn't have the same remain-on-exit/pane-border-status/pane-border-format options as the agents window: got [$ops_opts], expected [$want]"
    return
  fi
  ok "ac5: ops window has the same remain-on-exit, pane-border-status, and pane-border-format options as the agents window"
}

# AC6: a second bin/start.sh call against an already-running session still prints "Already
# running" and exits 0 without altering the existing layout - unchanged from current behaviour.
test_ac6_already_running_short_circuits_unchanged() {
  run_start_sh 1
  if [ "$LAST_STATUS" -ne 0 ]; then
    bad "ac6: bin/start.sh exited $LAST_STATUS against an already-running session, expected 0; output: $LAST_STDOUT"
    return
  fi
  if ! grep -q 'Already running' <<<"$LAST_STDOUT"; then
    bad "ac6: bin/start.sh didn't print 'Already running' against an already-running session; output: $LAST_STDOUT"
    return
  fi
  local calls
  calls=$(wc -l < "$LAST_TMUX_LOG" | tr -d ' ')
  if [ "$calls" -ne 1 ]; then
    bad "ac6: bin/start.sh issued $calls tmux command(s) against an already-running session (expected exactly 1: has-session), i.e. it altered or re-touched the layout instead of short-circuiting; log: $(cat "$LAST_TMUX_LOG")"
    return
  fi
  ok "ac6: a second run against an already-running session still prints 'Already running', exits 0, and issues no other tmux commands"
}

# AC7: the startup summary reflects the new layout - six roles including team-lead in agents;
# board mentioned as part of ops.
test_ac7_summary_reflects_new_layout() {
  run_start_sh 0
  local agents_line ops_lines role missing
  agents_line=$(grep -i "'agents'" <<<"$LAST_STDOUT" || true)
  if [ -z "$agents_line" ]; then
    bad "ac7: startup summary has no line describing the agents window; output: $LAST_STDOUT"
    return
  fi
  missing=""
  for role in "${EXPECTED_ROLES[@]}"; do
    grep -q "$role" <<<"$agents_line" || missing="$missing $role"
  done
  if [ -n "$missing" ]; then
    bad "ac7: agents-window summary line doesn't mention role(s):$missing; line: $agents_line"
    return
  fi
  if grep -qi 'board' <<<"$agents_line"; then
    bad "ac7: agents-window summary line still mentions board (board moved to ops); line: $agents_line"
    return
  fi
  ops_lines=$(grep -i "ops" <<<"$LAST_STDOUT" || true)
  if ! grep -qi 'board' <<<"$ops_lines"; then
    bad "ac7: no summary line mentions both ops and board - the printed hint text doesn't reflect board's new home; output: $LAST_STDOUT"
    return
  fi
  ok "ac7: startup summary lists all six agents-window roles (including team-lead), omits board from that line, and mentions board as part of ops"
}

# Cross-cutting: shellcheck the touched script (docs/ARCHITECTURE.md convention for bash
# changes). Not tied to a single AC; informational quality gate for the implementer.
test_shellcheck_touched_scripts() {
  if ! have_shellcheck; then
    skp "shellcheck: not installed in this environment"
    return
  fi
  if (cd bin && shellcheck -x start.sh); then
    ok "shellcheck: bin/start.sh clean"
  else
    bad "shellcheck: findings in bin/start.sh"
  fi
}

test_ac1_agents_window_six_role_panes_no_board
test_ac2_team_lead_first_others_keep_order
test_ac3_ops_window_shell_and_board
test_ac4_board_pane_above_and_one_third_height
test_ac5_ops_window_options_match_agents
test_ac6_already_running_short_circuits_unchanged
test_ac7_summary_reflects_new_layout
test_shellcheck_touched_scripts

echo "---"
echo "pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
