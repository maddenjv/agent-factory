#!/usr/bin/env bash
# Acceptance tests for agent-factory-dx0: team-lead agent triages needs-team-lead issues.
# One function per acceptance criterion in docs/stories/agent-factory-dx0.md (test_acN_...).
#
# AC1/AC2 (polling behaviour) run the real bin/agent-loop.sh with ROLE=team-lead against a stub
# `bd`, a stub `claude`, and a scratch git origin - same harness style as
# tests/agent-factory-stg_test.sh. The stub `bd ready` filters by whatever --label argument (if
# any) it's given, mirroring real `bd ready --label X`, so the test doesn't assume which label
# string the implementation queries by - it only asserts the outcome AC1 requires: an issue is
# claimed because it carries `needs-team-lead` (regardless of its other role:/stage: labels), and
# an issue carrying only `role:team-lead` (no `needs-team-lead`) is never claimed on that basis.
#
# AC3-AC7 (investigate/reroute/fix/escalate/handoff-comment behaviour) are content checks on
# agents/team-lead.md, the same way tests/agent-factory-h71_test.sh checks prose instructions for
# a role's decision-making - that behaviour is the LLM following its prompt, not code we can run
# directly.
#
# Written BEFORE implementation: expect every test below to fail right now, for two legitimate
# reasons rather than a broken harness: (a) agents/team-lead.md does not exist yet, and (b)
# bin/agent-loop.sh's next_issue() still polls `bd ready --label role:$ROLE` unchanged, so with
# ROLE=team-lead it finds issues labelled role:team-lead (which nothing produces) instead of
# needs-team-lead - confirmed by running ROLE=team-lead through unmodified bin/agent-loop.sh,
# which claims an issue carrying only role:team-lead and ignores needs-team-lead entirely. (Note:
# bin/agent-loop.sh:35 `model_var="MODEL_${ROLE^^}"` / `${!model_var}` also logs a harmless
# "invalid variable name" warning for this hyphenated role name - it does not affect control flow
# and is not part of this story's acceptance criteria.)
#
# Run directly: bash tests/agent-factory-dx0_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# ============================================================
# AC1 / AC2 - polling: found via the needs-team-lead label itself (not a role:team-lead label),
# and needs-human issues are never claimed or modified.
# ============================================================

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

# issue-A: needs-team-lead + unrelated role:/stage: labels -> must be claimed (AC1).
# issue-B: an ordinary role:qa issue, no needs-team-lead at all -> must never be claimed.
# issue-D: only role:team-lead (no needs-team-lead) -> must never be claimed; catches an
#          implementation that (like the other five roles) polls by role:$ROLE unchanged.
cat > "$TMP/issues_ac1.json" <<'JSON'
[
  {"id":"issue-A","status":"open","assignee":"","labels":["needs-team-lead","role:qa","stage:verify"]},
  {"id":"issue-B","status":"open","assignee":"","labels":["role:qa","stage:verify"]},
  {"id":"issue-D","status":"open","assignee":"","labels":["role:team-lead"]}
]
JSON

# issue-E: needs-team-lead AND needs-human, and (unlike the AC1 fixture) the ONLY
# needs-team-lead-labelled issue around - so if the needs-human exclusion were ever dropped, E
# would be exactly what gets picked and claimed, not silently shadowed by another candidate.
cat > "$TMP/issues_ac2.json" <<'JSON'
[
  {"id":"issue-E","status":"open","assignee":"","labels":["needs-team-lead","needs-human"]},
  {"id":"issue-B","status":"open","assignee":"","labels":["role:qa","stage:verify"]}
]
JSON

cat > "$TMP/stubs/bd" <<'STUB'
#!/usr/bin/env bash
echo "bd $*" >> "$W/bdlog"
case "$1" in
  ready)
    label=""
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
      [ "${args[$i]}" = "--label" ] && label="${args[$((i + 1))]}"
    done
    if [ -n "$label" ]; then
      jq -c --arg l "$label" '[.[] | select((.labels // []) | index($l))]' "$W/issues.json"
    else
      cat "$W/issues.json"
    fi
    ;;
  show)
    jq -c --arg id "$2" '[.[] | select(.id == $id)]' "$W/issues.json"
    ;;
  list) echo '[]' ;;
  *) ;;
esac
exit 0
STUB
chmod +x "$TMP/stubs/bd"

cat > "$TMP/stubs/claude" <<'STUB'
#!/usr/bin/env bash
echo x >> "$W/claude_runs"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0}'
touch "$W/data/control/STOP"
exit 0
STUB
chmod +x "$TMP/stubs/claude"

ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN" && git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# run_loop FIXTURE: one pass of bin/agent-loop.sh ROLE=team-lead against the stubs above; sets W.
run_loop() {
  W="$TMP/run.$RANDOM"; mkdir -p "$W/data/control" "$W/home"; : > "$W/bdlog"; : > "$W/claude_runs"
  cp "$1" "$W/issues.json"
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home"
    PATH="$TMP/stubs:$PATH" ROLE=team-lead KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 \
      timeout 30 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 )
}
claimed() { grep -qE "bd update $1 --claim" "$W/bdlog"; }

test_ac1_finds_work_via_needs_team_lead_label_not_role_label() {
  run_loop "$TMP/issues_ac1.json"
  if claimed issue-D; then
    fail "ac1: claimed issue-D, which carries only role:team-lead (no needs-team-lead) - team-lead must find work via the needs-team-lead label itself, not a role:team-lead label"
    return
  fi
  if claimed issue-B; then
    fail "ac1: claimed issue-B, which has no needs-team-lead label at all"
    return
  fi
  claimed issue-A \
    && pass "ac1: claimed issue-A via its needs-team-lead label, despite carrying unrelated role:/stage: labels" \
    || fail "ac1: issue-A (needs-team-lead, role:qa, stage:verify) was never claimed. bdlog:$(cat "$W/bdlog") out:$(cat "$W/out")"
}

test_ac2_never_claims_or_modifies_needs_human_issues() {
  run_loop "$TMP/issues_ac2.json"
  if claimed issue-E; then fail "ac2: claimed issue-E, which is labelled needs-human"; return; fi
  if grep -qE '^bd (update|label) issue-E' "$W/bdlog"; then
    fail "ac2: modified issue-E (labelled needs-human): $(grep issue-E "$W/bdlog")"
    return
  fi
  pass "ac2: needs-human issue-E was never claimed or modified"
}

# ============================================================
# AC3-AC7 - investigate/reroute/fix/escalate/handoff-comment: prose checks on agents/team-lead.md,
# the role prompt that drives this decision-making (not directly executable code).
# ============================================================

TL="agents/team-lead.md"

test_ac3_investigates_before_deciding() {
  [ -f "$TL" ] || { fail "ac3: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$TL")
  echo "$c" | grep -qiE 'comment|notes history|full history' \
    || { fail "ac3: no instruction to read the issue's full comment/notes history"; return; }
  echo "$c" | grep -qE 'docs/stories/<story-id>\.md' \
    || { fail "ac3: no instruction to read docs/stories/<story-id>.md"; return; }
  echo "$c" | grep -qE 'docs/design/<story-id>\.md' \
    || { fail "ac3: no instruction to read docs/design/<story-id>.md (if present)"; return; }
  echo "$c" | grep -qiE 'story:<story-id>|sibling issue|other issues in the same' \
    || { fail "ac3: no instruction to read the other issues in the same story:<id> chain"; return; }
  pass "ac3: prompt requires reading history, story doc, design doc, and sibling issues before routing"
}

test_ac4_reroute_updates_labels_comments_and_clears_needs_team_lead() {
  [ -f "$TL" ] || { fail "ac4: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$TL")
  echo "$c" | grep -qiE 'wrong role|wrong stage|reroute' \
    || { fail "ac4: no guidance for detecting the wrong role/stage and rerouting"; return; }
  echo "$c" | grep -qE 'role:|stage:' \
    || { fail "ac4: no instruction to update role:/stage: labels"; return; }
  echo "$c" | grep -qE 'bd comment' \
    || { fail "ac4: no instruction to leave a bd comment explaining the diagnosis and change"; return; }
  echo "$c" | grep -qiE '(remove|clear)[^.\n]*needs-team-lead|no longer[^.\n]*needs-team-lead' \
    || { fail "ac4: no instruction to remove the needs-team-lead label after rerouting"; return; }
  pass "ac4: reroute path updates role:/stage:/deps, comments the diagnosis, clears needs-team-lead"
}

test_ac5_direct_fix_comments_and_clears_needs_team_lead() {
  [ -f "$TL" ] || { fail "ac5: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$TL")
  echo "$c" | grep -qiE 'stale status|wrong dependency|already correct' \
    || { fail "ac5: no guidance for a direct fix when the role/stage was already correct"; return; }
  echo "$c" | grep -qE 'bd comment' \
    || { fail "ac5: no instruction to leave a bd comment explaining what was wrong/changed"; return; }
  echo "$c" | grep -qiE '(remove|clear)[^.\n]*needs-team-lead|no longer[^.\n]*needs-team-lead' \
    || { fail "ac5: no instruction to clear needs-team-lead after a direct fix"; return; }
  pass "ac5: direct-fix path comments what was wrong/changed and clears needs-team-lead"
}

test_ac6_escalates_to_human_when_it_cannot_resolve() {
  [ -f "$TL" ] || { fail "ac6: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$TL")
  echo "$c" | grep -qE -- '--append-notes' \
    || { fail "ac6: no --append-notes escalation step"; return; }
  echo "$c" | grep -qE 'needs-human' \
    || { fail "ac6: no needs-human labelling on escalation"; return; }
  echo "$c" | grep -qiE '\bstop\b' \
    || { fail "ac6: no instruction to stop after escalating"; return; }
  pass "ac6: when stuck, appends notes explaining what's needed, labels needs-human, stops"
}

test_ac7_handoff_comment_readable_without_other_context() {
  [ -f "$TL" ] || { fail "ac7: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$TL")
  echo "$c" | grep -qiE 'no other context|without other context|understandable|root cause' \
    || { fail "ac7: no requirement that the comment/notes thread be understandable with no other context"; return; }
  pass "ac7: prompt holds team-lead to the same standalone-readable handoff bar as other roles"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
