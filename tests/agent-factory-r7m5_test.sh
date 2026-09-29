#!/usr/bin/env bash
# Acceptance tests for agent-factory-r7m5: feature.sh priority flag.
# One function per acceptance criterion in docs/stories/agent-factory-r7m5.md (test_acN_...).
# Written from the story's acceptance criteria only - docs/design/agent-factory-r7m5.md does not
# exist (team-lead skipped the design stage for this story; see bd comments on
# agent-factory-k7al), so no design doc is read here.
#
# bin/feature.sh runs for real against a stub `bd` on PATH (same style as
# tests/agent-factory-icv_test.sh / tests/agent-factory-x8wj_test.sh use for bin/new-story.sh):
# the stub records the `bd create` flags it was called with instead of touching a real tracker,
# so these tests can assert on priority/description/labels without depending on a live `bd`.
#
# The flag shape tested here (`--priority <value>`, trailing after the positional title and
# optional description) mirrors new-story.sh's existing `--skip-design`/`--skip-tests` trailing-flag
# convention, per the story's Context section and team-lead's scoping note on agent-factory-k7al
# (the note that justified skipping design for this story in the first place).
#
# Written BEFORE implementation: expect every test below to fail right now, since bin/feature.sh
# has no --priority handling at all yet (confirmed by reading bin/feature.sh: it always calls
# `bd create ... -p 2 ...` with no flag parsing beyond the two positional args).
#
# Run directly: bash tests/agent-factory-r7m5_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/bd" <<'STUB'
#!/usr/bin/env bash
# Stub: `create <title> [-t type] [-p priority] [-l labels] [-d desc] [--json]` logs one line to
# $STUB_DIR/log and prints a fake issue id as JSON (feature.sh pipes this through jq). Anything
# else is a no-op success. If this stub is never invoked at all (e.g. feature.sh rejected an
# invalid priority before calling bd), $STUB_DIR/log simply never gets created/appended to - which
# is exactly what AC4 checks for ("no issue is created").
case "$1" in
  create)
    shift
    title=$1; shift
    type=""; priority=""; labels=""; desc=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) type=$2; shift ;;
        -p) priority=$2; shift ;;
        -l) labels=$2; shift ;;
        -d) desc=$2; shift ;;
        --json) : ;;
      esac
      shift
    done
    echo "create title=$title|type=$type|priority=$priority|labels=$labels|desc=$desc" >> "$STUB_DIR/log"
    echo '{"id":"issue-1"}'
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/bd"

# Runs bin/feature.sh with the stub bd on PATH. Sets globals: RC (exit code), ERR (stderr).
# Resets the log first so each test starts clean.
run_feature() {
  rm -f "$TMP/log"
  STUB_DIR="$TMP" PATH="$TMP/bin:$PATH" bash bin/feature.sh "$@" >/dev/null 2>"$TMP/stderr"
  RC=$?
  ERR=$(cat "$TMP/stderr")
}
LOG="$TMP/log"
log_line() { [ -f "$LOG" ] && tail -n1 "$LOG" || true; }
field() { log_line | grep -o "$1=[^|]*" | cut -d= -f2-; }  # field priority|type|labels|desc|title
# Beads accepts both "N" and "PN" for a priority; normalize so tests don't care which form
# feature.sh forwards to `bd create -p`.
norm_priority() { echo "$1" | tr 'p' 'P' | sed 's/^P//'; }

# ============================================================
# AC1 - no priority given -> issue priority is 2 (today's unchanged default).
# ============================================================

test_ac1_no_priority_defaults_to_2() {
  run_feature "A title"
  [ "$RC" = 0 ] || { fail "ac1: feature.sh exited $RC with no priority flag, expected 0 (stderr: $ERR)"; return; }
  [ -f "$LOG" ] || { fail "ac1: bd create was never called"; return; }
  local p; p=$(norm_priority "$(field priority)")
  [ "$p" = "2" ] || { fail "ac1: bd create -p was '$(field priority)' (normalized '$p'), expected 2"; return; }
  pass "ac1: no --priority given defaults the created issue's priority to 2"
}

# ============================================================
# AC2 - a valid supplied priority (any of Beads' accepted forms) is used instead of the default.
# ============================================================

test_ac2_numeric_priority_is_used() {
  run_feature "A title" --priority 0
  [ "$RC" = 0 ] || { fail "ac2: feature.sh exited $RC with --priority 0, expected 0 (stderr: $ERR)"; return; }
  [ -f "$LOG" ] || { fail "ac2: bd create was never called"; return; }
  local p; p=$(norm_priority "$(field priority)")
  [ "$p" = "0" ] || { fail "ac2: bd create -p was '$(field priority)' (normalized '$p'), expected 0"; return; }
  pass "ac2: --priority 0 sets the created issue's priority to 0"
}

test_ac2_p_form_priority_is_used() {
  run_feature "A title" --priority P4
  [ "$RC" = 0 ] || { fail "ac2: feature.sh exited $RC with --priority P4, expected 0 (stderr: $ERR)"; return; }
  [ -f "$LOG" ] || { fail "ac2: bd create was never called"; return; }
  local p; p=$(norm_priority "$(field priority)")
  [ "$p" = "4" ] || { fail "ac2: bd create -p was '$(field priority)' (normalized '$p'), expected 4 (from P4)"; return; }
  pass "ac2: --priority P4 (Beads' P-form) sets the created issue's priority to 4"
}

# ============================================================
# AC3 - title, description, and priority together: supplying a priority doesn't require omitting
# or reordering the description.
# ============================================================

test_ac3_description_and_priority_both_set() {
  run_feature "A title" "A description" --priority 1
  [ "$RC" = 0 ] || { fail "ac3: feature.sh exited $RC with title+description+priority, expected 0 (stderr: $ERR)"; return; }
  [ -f "$LOG" ] || { fail "ac3: bd create was never called"; return; }
  local p; p=$(norm_priority "$(field priority)")
  [ "$p" = "1" ] || { fail "ac3: bd create -p was '$(field priority)' (normalized '$p'), expected 1"; return; }
  [ "$(field desc)" = "A description" ] \
    || { fail "ac3: bd create -d was '$(field desc)', expected 'A description'"; return; }
  pass "ac3: title, description, and priority are all set together without reordering"
}

# ============================================================
# AC4 - an invalid priority (not one of Beads' accepted values) exits non-zero, names the bad
# value in an error message, and creates no issue.
# ============================================================

test_ac4_invalid_priority_rejected() {
  local bad
  for bad in 5 P9 abc -1; do
    run_feature "A title" --priority "$bad"
    [ "$RC" != 0 ] || { fail "ac4: feature.sh exited 0 with invalid --priority $bad, expected non-zero"; continue; }
    echo "$ERR" | grep -qF -- "$bad" \
      || { fail "ac4: error message for invalid --priority $bad doesn't name the bad value: '$ERR'"; continue; }
    [ -f "$LOG" ] && { fail "ac4: bd create was called despite invalid --priority $bad (no issue should be created)"; continue; }
    pass "ac4: invalid --priority $bad exits non-zero, names the value, and creates no issue"
  done
}

# ============================================================
# AC5 - no arguments, or a missing title, prints usage output that documents how to pass a
# priority, and exits non-zero.
# ============================================================

test_ac5_no_args_prints_usage_mentioning_priority_and_exits_nonzero() {
  run_feature
  [ "$RC" != 0 ] || { fail "ac5: feature.sh exited 0 with no arguments, expected non-zero"; return; }
  echo "$ERR" | grep -qi 'priority' \
    || { fail "ac5: usage output on no-args doesn't mention priority: '$ERR'"; return; }
  [ ! -f "$LOG" ] || fail "ac5: bd create was called despite no arguments"
  pass "ac5: no arguments prints usage mentioning priority and exits non-zero"
}

test_ac5_missing_title_prints_usage_mentioning_priority_and_exits_nonzero() {
  run_feature ""
  [ "$RC" != 0 ] || { fail "ac5: feature.sh exited 0 with an empty title, expected non-zero"; return; }
  echo "$ERR" | grep -qi 'priority' \
    || { fail "ac5: usage output on missing title doesn't mention priority: '$ERR'"; return; }
  [ ! -f "$LOG" ] || fail "ac5: bd create was called despite a missing title"
  pass "ac5: a missing title prints usage mentioning priority and exits non-zero"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "---"; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
