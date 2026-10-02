#!/usr/bin/env bash
# Acceptance tests for agent-factory-b50b: "Multi-line alerts must age out of recent alerts".
#
# One function per acceptance criterion in docs/stories/agent-factory-b50b.md (test_acN_...).
# Written from the story ONLY (not docs/design/agent-factory-b50b.md).
#
# Test surface: bin/board.sh's recent_alerts(), same entry point as tests/agent-factory-47q_test.sh
# and tests/agent-factory-wzg_test.sh. A multi-line alert is modelled as a timestamped first line
# followed by continuation lines with no timestamp / [agent] prefix, exactly as agent-loop.sh writes
# Copilot's "No authentication information found" preflight output into alerts.log.
#
# Run directly: bash tests/agent-factory-b50b_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

STUB_BD_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_BD_DIR"' EXIT

# Stub `bd`: issue-still-flagged keeps needs-human; issue-resolved has lost the label.
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

# Continuation lines, distinctive so grep can attribute them to a given alert.
C1="No authentication information found."
C2="Please run 'copilot login' to authenticate."
C3="Or set the COPILOT_GITHUB_TOKEN environment variable."

# Sets RESULT_OUT / RESULT_RC / DISK_UNCHANGED (1 if alerts.log bytes identical after the run).
run_recent_alerts() {
  local content="$1" tmp before after
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/control"
  printf '%s' "$content" > "$tmp/control/alerts.log"
  before="$(cksum < "$tmp/control/alerts.log")"
  RESULT_OUT="$(DATA_DIR="$tmp" PATH="$STUB_BD_DIR:$PATH" timeout 5 bash -c '
    source bin/board.sh
    recent_alerts
  ' 2>&1)"
  RESULT_RC=$?
  after="$(cksum < "$tmp/control/alerts.log")"
  DISK_UNCHANGED=0
  [ "$before" = "$after" ] && DISK_UNCHANGED=1
  rm -rf "$tmp"
}

shown() { printf '%s\n' "$RESULT_OUT" | grep -qxF -- "$1"; }

# Asserts none of the given lines are shown.
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

# Asserts all given lines are shown, in the given order.
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

copilot_alert() {  # $1 = timestamp, $2 = agent
  printf '%s [%s] preflight: harness failed to run (check auth): %s\n%s\n%s\n' "$1" "$2" "$C1" "$C2" "$C3"
}

# --- AC1: continuation lines of an alert whose first line is dropped are dropped too. ---
test_ac1_continuations_hidden_when_first_line_too_old() {
  local first
  first="$(now_ts '90 minutes ago')"
  run_recent_alerts "$(copilot_alert "$first" engineer)
"
  assert_none_shown "ac1: continuation lines hidden when first line is past the age cutoff" \
    "$C1" "$C2" "$C3"
}

test_ac1_continuations_hidden_when_first_line_superseded() {
  local t_old t_new newer
  t_old="$(now_ts '45 minutes ago')"   # inside age cutoff: only the superseded-start rule drops it
  t_new="$(now_ts '5 minutes ago')"
  newer="$t_new [engineer] preflight: harness failed to run (check auth): second failure"
  run_recent_alerts "$(copilot_alert "$t_old" engineer)
$newer
"
  assert_none_shown "ac1: continuation lines hidden when first line is superseded by a later start" \
    "$C1" "$C2" "$C3"
  if shown "$newer"; then pass "ac1: the superseding (newer) alert itself is still shown"
  else fail "ac1: the newer alert is missing: $RESULT_OUT"; fi
}

test_ac1_hidden_continuations_do_not_leak_onto_next_alert() {
  # A dropped alert's continuations must not be attributed to (or hide) the following alert.
  local t_old t_new later
  t_old="$(now_ts '90 minutes ago')"
  t_new="$(now_ts '2 minutes ago')"
  later="$t_new [qa] circuit breaker: 5 consecutive failures; stopping qa"
  run_recent_alerts "$(copilot_alert "$t_old" engineer)
$later
"
  assert_all_shown_in_order "ac1: a fresh single-line alert after a dropped multi-line alert is shown" "$later"
  assert_none_shown "ac1: ...and the dropped alert's continuations stay hidden" "$C1" "$C2" "$C3"
}

# --- AC2: continuation lines of a shown alert are shown with it, in order. ---
test_ac2_continuations_shown_with_first_line() {
  local t first
  t="$(now_ts '5 minutes ago')"
  first="$t [engineer] preflight: harness failed to run (check auth): $C1"
  run_recent_alerts "$first
$C2
$C3
"
  assert_all_shown_in_order "ac2: first line and continuations shown, in order" "$first" "$C2" "$C3"
}

test_ac2_continuations_belong_to_their_own_alert() {
  # Old multi-line alert (dropped) followed by a fresh multi-line alert (shown): only the fresh
  # alert's continuations appear.
  local t_old t_new old_first new_first
  t_old="$(now_ts '90 minutes ago')"
  t_new="$(now_ts '3 minutes ago')"
  old_first="$t_old [engineer] daily budget reached (42.00 USD); pausing 3600s"
  new_first="$t_new [qa] git sync failed; releasing issue-x"
  run_recent_alerts "$old_first
OLD-CONT-1
OLD-CONT-2
$new_first
NEW-CONT-1
NEW-CONT-2
"
  assert_none_shown "ac2: continuations of the old (dropped) alert are hidden" "$old_first" "OLD-CONT-1" "OLD-CONT-2"
  assert_all_shown_in_order "ac2: continuations of the fresh alert are shown in order" \
    "$new_first" "NEW-CONT-1" "NEW-CONT-2"
}

# --- AC3: needs-human and usage-limit alerts: continuations follow the first line's decision. ---
test_ac3_needs_human_still_flagged_shows_continuations() {
  local t first
  t="$(now_ts '5 minutes ago')"
  first="$t [engineer] issue-still-flagged flagged needs-human by the agent"
  run_recent_alerts "$first
NH-CONT-1
NH-CONT-2
"
  assert_all_shown_in_order "ac3: needs-human still flagged: first line + continuations shown" \
    "$first" "NH-CONT-1" "NH-CONT-2"
}

test_ac3_needs_human_resolved_hides_continuations() {
  local t first
  t="$(now_ts '5 minutes ago')"
  first="$t [engineer] issue-resolved flagged needs-human by the agent"
  run_recent_alerts "$first
NH-CONT-1
NH-CONT-2
"
  assert_none_shown "ac3: needs-human resolved: first line + continuations hidden" \
    "$first" "NH-CONT-1" "NH-CONT-2"
}

test_ac3_usage_limit_active_shows_continuations() {
  local t first
  t="$(now_ts '10 seconds ago')"
  first="$t [engineer] preflight: usage limit hit (5-hour limit reached); waiting 100000s before retrying startup"
  run_recent_alerts "$first
UL-CONT-1
UL-CONT-2
"
  assert_all_shown_in_order "ac3: usage-limit wait active: first line + continuations shown" \
    "$first" "UL-CONT-1" "UL-CONT-2"
}

test_ac3_usage_limit_elapsed_hides_continuations() {
  local t first
  t="$(now_ts '30 minutes ago')"
  first="$t [engineer] preflight: usage limit hit (5-hour limit reached); waiting 60s before retrying startup"
  run_recent_alerts "$first
UL-CONT-1
UL-CONT-2
"
  assert_none_shown "ac3: usage-limit wait elapsed: first line + continuations hidden" \
    "$first" "UL-CONT-1" "UL-CONT-2"
}

# --- AC4 (superseded by lv8s): continuations of an old alert whose header is outside the tail window are hidden, never shown headerless. ---
test_ac4_truncated_alert_continuations_hidden() {
  local t_old t_new x y z
  t_old="$(now_ts '90 minutes ago')"
  t_new="$(now_ts '2 minutes ago')"
  x="$t_new [qa] git sync failed; releasing issue-a"
  y="$t_new [qa] git sync failed; releasing issue-b"
  z="$t_new [qa] git sync failed; releasing issue-c"
  # 7 lines: the tail-6 window starts at TRUNC-1, its first line's timestamped header is cut off.
  run_recent_alerts "$t_old [engineer] daily budget reached (42.00 USD); pausing 3600s
TRUNC-1
TRUNC-2
TRUNC-3
$x
$y
$z
"
  assert_none_shown "ac4 (lv8s): orphaned continuation lines of an aged alert are hidden" \
    "TRUNC-1" "TRUNC-2" "TRUNC-3"
  assert_all_shown_in_order "ac4 (lv8s): later alerts still shown, in order" "$x" "$y" "$z"
}

# --- AC5: single-line alerts only: unchanged from 2do / 47q / wzg. ---
test_ac5_single_line_alerts_unchanged() {
  local old fresh nonfmt
  old="$(now_ts '90 minutes ago') [engineer] daily budget reached (42.00 USD); pausing 3600s"
  fresh="$(now_ts '5 minutes ago') [qa] git sync failed; releasing issue-x"
  nonfmt="garbage line not in log format"
  run_recent_alerts "$old
$fresh
$nonfmt
"
  assert_none_shown "ac5: old single-line alert still dropped" "$old"
  assert_all_shown_in_order "ac5: fresh single-line alert and non-format line still shown" "$fresh" "$nonfmt"
}

# --- AC6: alerts.log is never modified. ---
test_ac6_alerts_log_unmodified() {
  local t_old t_new
  t_old="$(now_ts '90 minutes ago')"
  t_new="$(now_ts '2 minutes ago')"
  run_recent_alerts "$(copilot_alert "$t_old" engineer)
$(copilot_alert "$t_new" qa)
"
  if [ "$RESULT_RC" -eq 0 ] && [ "$DISK_UNCHANGED" = 1 ]; then
    pass "ac6: alerts.log unmodified after refresh with multi-line alerts"
  else
    fail "ac6: rc=$RESULT_RC disk_unchanged=$DISK_UNCHANGED"
  fi
}

test_ac1_continuations_hidden_when_first_line_too_old
test_ac1_continuations_hidden_when_first_line_superseded
test_ac1_hidden_continuations_do_not_leak_onto_next_alert
test_ac2_continuations_shown_with_first_line
test_ac2_continuations_belong_to_their_own_alert
test_ac3_needs_human_still_flagged_shows_continuations
test_ac3_needs_human_resolved_hides_continuations
test_ac3_usage_limit_active_shows_continuations
test_ac3_usage_limit_elapsed_hides_continuations
test_ac4_truncated_alert_continuations_hidden
test_ac5_single_line_alerts_unchanged
test_ac6_alerts_log_unmodified

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
