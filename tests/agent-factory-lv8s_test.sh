#!/usr/bin/env bash
# Acceptance tests for agent-factory-lv8s: "Stale multi-line alert tail shown in recent alerts".
#
# One function per acceptance criterion in docs/stories/agent-factory-lv8s.md (test_acN_...).
# Written from the story ONLY (not docs/design/agent-factory-lv8s.md).
#
# Test surface: bin/board.sh's recent_alerts(), same entry point as tests/agent-factory-b50b_test.sh.
# Multi-line alerts are a timestamped first line followed by headerless continuation lines. The
# interesting cases are alerts longer than the old 6-physical-line tail window, so the header
# line sits before the window.
#
# NOTE: this story deliberately changes agent-factory-b50b AC4 ("orphaned leading continuation
# lines are shown"): when the header can be found, orphan tails of aged-out alerts are now hidden.
#
# Run directly: bash tests/agent-factory-lv8s_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

STUB_BD_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_BD_DIR"' EXIT

cat > "$STUB_BD_DIR/bd" <<'STUBEOF'
#!/usr/bin/env bash
if [ "$1" = "show" ] && [ "$2" = "issue-still-flagged" ]; then
  echo '{"id":"issue-still-flagged","status":"open","labels":["needs-human"]}'
  exit 0
fi
if [ "$1" = "show" ] && [ "$2" = "issue-resolved" ]; then
  echo '{"id":"issue-resolved","status":"open","labels":[]}'
  exit 0
fi
exit 1
STUBEOF
chmod +x "$STUB_BD_DIR/bd"

now_ts() { date -u -d "$1" +%FT%TZ; }

RESULT_OUT=""; RESULT_RC=0
run_recent_alerts() {
  local content="$1" tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/control"
  printf '%s' "$content" > "$tmp/control/alerts.log"
  RESULT_OUT="$(DATA_DIR="$tmp" PATH="$STUB_BD_DIR:$PATH" timeout 5 bash -c '
    source bin/board.sh
    recent_alerts
  ' 2>&1)"
  RESULT_RC=$?
  rm -rf "$tmp"
}

shown() { printf '%s\n' "$RESULT_OUT" | grep -qxF -- "$1"; }

assert_none_shown() {
  local label="$1"; shift
  local l ok=1
  [ "$RESULT_RC" -eq 0 ] || { fail "$label: unexpected rc=$RESULT_RC output=$RESULT_OUT"; return; }
  for l in "$@"; do
    shown "$l" && { fail "$label: line should be hidden but is shown: $l
Got:
$RESULT_OUT"; ok=0; }
  done
  [ "$ok" = 1 ] && pass "$label"
}

assert_all_shown_in_order() {
  local label="$1"; shift
  local expected actual
  [ "$RESULT_RC" -eq 0 ] || { fail "$label: unexpected rc=$RESULT_RC output=$RESULT_OUT"; return; }
  expected="$(printf '%s\n' "$@")"
  actual="$(printf '%s\n' "$RESULT_OUT" | grep -xF -f <(printf '%s\n' "$@") || true)"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label: expected lines in order:
$expected
Got:
$RESULT_OUT"
  fi
}

# conts PREFIX N: print N continuation lines PREFIX-1..PREFIX-N (no timestamp / [agent] header).
conts() { local i; for i in $(seq 1 "$2"); do echo "$1-$i"; done; }
conts_list() { local i; for i in $(seq 1 "$2"); do printf '%s\n' "$1-$i"; done; }

# --- AC1: header before the window, alert past the age limit: no continuation line shown. ---
test_ac1_orphan_tail_of_old_alert_hidden() {
  local old newer
  old="$(now_ts '3 days ago') [engineer] preflight: harness failed to run (check auth): first line"
  newer="$(now_ts '2 minutes ago') [qa] git sync failed; releasing issue-x"
  # Window (last 6 lines) = OLD-4..OLD-8 + the newer alert: starts mid old alert.
  run_recent_alerts "$old
$(conts OLD 8)
$newer
"
  local all=(); mapfile -t all < <(conts_list OLD 8)
  assert_none_shown "ac1: continuation tail of an aged-out alert is hidden" "${all[@]}" "$old"
  shown "$newer" && pass "ac1: the newer alert is still shown" || fail "ac1: newer alert missing: $RESULT_OUT"
}

test_ac1_old_alert_tail_only_log_hidden() {
  local old
  old="$(now_ts '90 minutes ago') [engineer] daily budget reached (42.00 USD); pausing 3600s"
  run_recent_alerts "$old
$(conts OLD 9)
"
  local all=(); mapfile -t all < <(conts_list OLD 9)
  assert_none_shown "ac1: log ending in an old alert's tail shows nothing of it" "${all[@]}" "$old"
}

test_ac1_regression_real_copilot_case() {
  # Five agents each logged a 3-line copilot auth alert 3 days ago, then unrelated newer alerts.
  local t3d t5m out a
  t3d="$(now_ts '3 days ago')"; t5m="$(now_ts '5 minutes ago')"
  local log="" agent
  for agent in po architect engineer qa reviewer; do
    log+="$t3d [$agent] preflight: harness failed to run (check auth): Error: No authentication information found.
Copilot can be authenticated with GitHub using an OAuth Token or a Fine-Grained Personal Access Token.
Set COPILOT_GITHUB_TOKEN.
"
  done
  log+="$t5m [qa] git sync failed; releasing issue-x
"
  run_recent_alerts "$log"
  assert_none_shown "ac1: stale Copilot auth tail not shown on the board" \
    "Copilot can be authenticated with GitHub using an OAuth Token or a Fine-Grained Personal Access Token." \
    "Set COPILOT_GITHUB_TOKEN."
}

# --- AC2: header before the window, alert still young: header shown with its tail. ---
test_ac2_young_long_alert_header_shown_with_tail() {
  local hdr
  hdr="$(now_ts '5 minutes ago') [engineer] git sync failed; releasing issue-x"
  # 8 continuation lines so the header is outside the last-6 window.
  run_recent_alerts "$hdr
$(conts YNG 8)
"
  assert_all_shown_in_order "ac2: header is shown (never a headerless fragment) before its continuations" \
    "$hdr" YNG-3 YNG-4 YNG-5 YNG-6 YNG-7 YNG-8
}

test_ac2_young_alert_then_newer_alert_header_shown() {
  local hdr newer
  hdr="$(now_ts '10 minutes ago') [engineer] git sync failed; releasing issue-x"
  newer="$(now_ts '1 minutes ago') [qa] git sync failed; releasing issue-y"
  run_recent_alerts "$hdr
$(conts YNG 6)
$newer
"
  assert_all_shown_in_order "ac2: window starting mid-alert still shows the young alert's header" \
    "$hdr" YNG-6 "$newer"
}

# --- AC3: header in window, aged out or superseded: all hidden (existing behaviour). ---
test_ac3_aged_out_header_in_window_hides_all() {
  local old
  old="$(now_ts '90 minutes ago') [engineer] daily budget reached (42.00 USD); pausing 3600s"
  run_recent_alerts "$old
AGED-1
AGED-2
"
  assert_none_shown "ac3: aged-out header and its continuations hidden" "$old" AGED-1 AGED-2
}

test_ac3_superseded_header_in_window_hides_all() {
  local t_old t_new old newer
  t_old="$(now_ts '45 minutes ago')"; t_new="$(now_ts '5 minutes ago')"
  old="$t_old [engineer] preflight: harness failed to run (check auth): boom"
  newer="$t_new [engineer] preflight: harness failed to run (check auth): boom again"
  run_recent_alerts "$old
SUP-1
SUP-2
$newer
"
  assert_none_shown "ac3: superseded header and its continuations hidden" "$old" SUP-1 SUP-2
}

# --- AC4: header in window, current: all shown (existing behaviour). ---
test_ac4_current_header_in_window_shows_all() {
  local hdr
  hdr="$(now_ts '5 minutes ago') [engineer] git sync failed; releasing issue-x"
  run_recent_alerts "$hdr
CUR-1
CUR-2
"
  assert_all_shown_in_order "ac4: current header and continuations all shown" "$hdr" CUR-1 CUR-2
}

# --- AC5: long, most recent, current alert: complete text including header. ---
test_ac5_long_current_alert_shown_in_full() {
  local hdr
  hdr="$(now_ts '2 minutes ago') [engineer] preflight: harness failed to run (check auth): long error"
  run_recent_alerts "$hdr
$(conts LONG 12)
"
  local all=(); mapfile -t all < <(conts_list LONG 12)
  assert_all_shown_in_order "ac5: all 13 lines of the long current alert are shown, in order" "$hdr" "${all[@]}"
}

test_ac5_long_current_alert_after_older_alert() {
  local old hdr
  old="$(now_ts '2 days ago') [qa] git sync failed; releasing issue-old"
  hdr="$(now_ts '2 minutes ago') [engineer] git sync failed; releasing issue-new"
  run_recent_alerts "$old
OLDC-1
$hdr
$(conts LONG 10)
"
  local all=(); mapfile -t all < <(conts_list LONG 10)
  assert_all_shown_in_order "ac5: long current alert shown in full" "$hdr" "${all[@]}"
  assert_none_shown "ac5: the older alert is not shown" "$old" OLDC-1
}

test_ac1_orphan_tail_of_old_alert_hidden
test_ac1_old_alert_tail_only_log_hidden
test_ac1_regression_real_copilot_case
test_ac2_young_long_alert_header_shown_with_tail
test_ac2_young_alert_then_newer_alert_header_shown
test_ac3_aged_out_header_in_window_hides_all
test_ac3_superseded_header_in_window_hides_all
test_ac4_current_header_in_window_shows_all
test_ac5_long_current_alert_shown_in_full
test_ac5_long_current_alert_after_older_alert

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
