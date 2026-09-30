#!/usr/bin/env bash
# Acceptance tests for agent-factory-wc2k: after bin/start.sh, the `ops` window's active pane is
# the shell pane (not the board pane), with everything else about both windows unchanged.
# One function per acceptance criterion in docs/stories/agent-factory-wc2k.md (test_acN_...).
# Runs the REAL bin/start.sh against a REAL tmux server on a private socket (-L), with only
# `docker` stubbed (its `compose ... run` just sleeps, so panes stay alive; everything else is a
# no-op). SKIPped when tmux is not installed.
# Run directly: bash tests/agent-factory-wc2k_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }

TMP="$(mktemp -d)"
SOCKS=()
cleanup() {
  local s; for s in "${SOCKS[@]:-}"; do [ -n "$s" ] && "$TMUX_BIN" -L "$s" kill-server >/dev/null 2>&1; done
  rm -rf "$TMP"
}
trap cleanup EXIT
TMUX_BIN="$(command -v tmux || true)"
unset TMUX

# setup NAME -> makes project + stubs in $TMP/NAME, sets P (project), SOCK, SESSION, STUBS.
setup() {
  P="$TMP/$1"; SOCK="wc2k_$1_$$"; SESSION=factory; STUBS="$P-stubs"; SOCKS+=("$SOCK")
  mkdir -p "$P/.agent-factory" "$STUBS"
  git -C "$P" init -q; git -C "$P" config user.email t@t; git -C "$P" config user.name t
  echo x > "$P/f"; git -C "$P" add f; git -C "$P" commit -qm init
  echo '.agent-factory/' > "$P/.git/info/exclude"
  : > "$P/.agent-factory/.env"
  cat > "$STUBS/docker" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = run ] && exec sleep 600; done
exit 0
STUB
  printf '#!/usr/bin/env bash\nexec "%s" -L "%s" -f /dev/null "$@"\n' "$TMUX_BIN" "$SOCK" > "$STUBS/tmux"
  chmod +x "$STUBS/docker" "$STUBS/tmux"
}
t() { "$TMUX_BIN" -L "$SOCK" "$@"; }
start() { ( export PROJECT_DIR="$P" SESSION="$SESSION" PATH="$STUBS:$PATH"; bash "$REPO_ROOT/bin/start.sh" ) 2>&1; }
need_tmux() { [ -n "$TMUX_BIN" ] || { skip "$1: tmux not installed"; return 1; }; }

active_window() { t list-windows -t "$SESSION" -F '#{window_active} #{window_name}' | awk '$1==1{print $2}'; }
active_pane_title() { t list-panes -t "$SESSION:$1" -F '#{pane_active} #{pane_title}' | awk '$1==1{print $2}'; }

test_ac1_ops_active_window_and_shell_pane_active() {
  need_tmux ac1 || return
  setup ac1; start >"$TMP/ac1.out" || { fail "ac1: start.sh failed: $(tail -5 "$TMP/ac1.out")"; return; }
  local w p; w=$(active_window); p=$(active_pane_title ops)
  [ "$w" = ops ] && [ "$p" = shell ] \
    && pass "ac1: active window is ops and its active pane is the shell pane" \
    || fail "ac1: active window='$w' (want ops), active ops pane='$p' (want shell)"
}

test_ac2_ops_panes_layout_and_options_unchanged() {
  need_tmux ac2 || return
  setup ac2; start >"$TMP/ac2.out" || { fail "ac2: start.sh failed: $(tail -5 "$TMP/ac2.out")"; return; }
  local rows; rows=$(t list-panes -t "$SESSION:ops" -F '#{pane_title} #{pane_top} #{pane_height} #{pane_width}' | sort)
  local n; n=$(echo "$rows" | wc -l)
  [ "$n" = 2 ] || { fail "ac2: want 2 ops panes, got $n: $rows"; return; }
  local btop bh bw stop sh sw
  read -r _ btop bh bw <<<"$(echo "$rows" | grep '^board ')"
  read -r _ stop sh sw <<<"$(echo "$rows" | grep '^shell ')"
  [ -n "${btop:-}" ] && [ -n "${stop:-}" ] || { fail "ac2: panes not titled board+shell: $rows"; return; }
  [ "$btop" -lt "$stop" ] && [ "$bw" = "$sw" ] \
    && pass "ac2: board pane sits above the shell pane (full width, both titled as before)" \
    || fail "ac2: board not above shell: $rows"
  # -p 33 split: board is roughly a third of the window (allowing for border rows)
  local pct=$(( bh * 100 / (bh + sh) ))
  [ "$pct" -ge 28 ] && [ "$pct" -le 38 ] \
    && pass "ac2: board/shell size ratio unchanged (~33% board, got ${pct}%)" \
    || fail "ac2: board is ${pct}% of pane height (want ~33%): $rows"
  local rs pbs pbf
  rs=$(t show-options -wv -t "$SESSION:ops" remain-on-exit)
  pbs=$(t show-options -wv -t "$SESSION:ops" pane-border-status)
  pbf=$(t show-options -wv -t "$SESSION:ops" pane-border-format)
  [ "$rs" = on ] && [ "$pbs" = top ] && [ "$pbf" = '#{pane_title}' ] \
    && pass "ac2: ops window options unchanged (remain-on-exit on, border status top, title format)" \
    || fail "ac2: options changed: remain-on-exit=$rs border-status=$pbs format=$pbf"
}

test_ac3_agents_window_unchanged() {
  need_tmux ac3 || return
  setup ac3; start >"$TMP/ac3.out" || { fail "ac3: start.sh failed: $(tail -5 "$TMP/ac3.out")"; return; }
  local titles; titles=$(t list-panes -t "$SESSION:agents" -F '#{pane_title}' | tr '\n' ' ')
  [ "$titles" = "team-lead po architect qa engineer reviewer " ] \
    && pass "ac3: agents window has the six titled panes in order" \
    || fail "ac3: agents pane titles: '$titles'"
  local before after
  before=$(t display -p -t "$SESSION:agents" '#{window_layout}')
  t select-layout -t "$SESSION:agents" tiled >/dev/null
  after=$(t display -p -t "$SESSION:agents" '#{window_layout}')
  [ "$before" = "$after" ] \
    && pass "ac3: agents window layout is still tiled" \
    || fail "ac3: agents layout not tiled: '$before' vs re-tiled '$after'"
  local rs pbs pbf
  rs=$(t show-options -wv -t "$SESSION:agents" remain-on-exit)
  pbs=$(t show-options -wv -t "$SESSION:agents" pane-border-status)
  pbf=$(t show-options -wv -t "$SESSION:agents" pane-border-format)
  [ "$rs" = on ] && [ "$pbs" = top ] && [ "$pbf" = '#{pane_title}' ] \
    && pass "ac3: agents window options unchanged" \
    || fail "ac3: options changed: remain-on-exit=$rs border-status=$pbs format=$pbf"
}

test_ac4_rerun_reports_running_and_changes_no_focus() {
  need_tmux ac4 || return
  setup ac4; start >"$TMP/ac4.out" || { fail "ac4: first start.sh failed: $(tail -5 "$TMP/ac4.out")"; return; }
  # Move focus somewhere non-default so any focus change by the rerun is visible.
  t select-window -t "$SESSION:agents"; t select-pane -t "$SESSION:agents.0"
  t select-window -t "$SESSION:ops";    t select-pane -t "$SESSION:ops" -U   # board pane (above shell)
  t select-window -t "$SESSION:agents"
  local wb pab pob; wb=$(active_window); pab=$(active_pane_title agents); pob=$(active_pane_title ops)
  local out; out=$(start)
  local wa paa poa; wa=$(active_window); paa=$(active_pane_title agents); poa=$(active_pane_title ops)
  echo "$out" | grep -qi 'already running' \
    && pass "ac4: second start.sh reports it is already running" \
    || fail "ac4: no 'Already running' message: $out"
  [ "$wb/$pab/$pob" = "$wa/$paa/$poa" ] \
    && pass "ac4: rerun leaves active window and panes untouched ($wa/$paa/$poa)" \
    || fail "ac4: focus changed: before $wb/$pab/$pob, after $wa/$paa/$poa"
}

for f in $(declare -F | awk '{print $3}' | grep '^test_'); do "$f"; done
echo "passed=$PASS failed=$FAIL skipped=$SKIP"
[ "$FAIL" -eq 0 ]
