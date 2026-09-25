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
  ready|list)
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
  *) ;;
esac
exit 0
STUB
chmod +x "$TMP/stubs/bd"

# TL_OUTCOME (unset for AC1/AC2): stands in for what a real team-lead session would have done to
# issue-A via bd update calls, by editing issues.json directly (the bd stub is read-only against
# it) - reroute (AC4), escalate (AC6), or none (a session that neither rerouted nor escalated, the
# "did nothing" case every other role's crash/timeout already falls into).
cat > "$TMP/stubs/claude" <<'STUB'
#!/usr/bin/env bash
echo x >> "$W/claude_runs"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0}'
case "${TL_OUTCOME:-}" in
  reroute)
    jq '(.[] | select(.id=="issue-A").labels) |= ([.[] | select(. != "needs-team-lead" and . != "stage:verify")] + ["stage:design"])' \
      "$W/issues.json" > "$W/issues.json.tmp" && mv "$W/issues.json.tmp" "$W/issues.json"
    ;;
  fix)
    jq '(.[] | select(.id=="issue-A").labels) |= [.[] | select(. != "needs-team-lead")]' \
      "$W/issues.json" > "$W/issues.json.tmp" && mv "$W/issues.json.tmp" "$W/issues.json"
    ;;
  escalate)
    jq '(.[] | select(.id=="issue-A").labels) |= ([.[] | select(. != "needs-team-lead")] + ["needs-human"])
        | (.[] | select(.id=="issue-A").notes) = "team-lead: story doc and design doc disagree on X - need a human call"' \
      "$W/issues.json" > "$W/issues.json.tmp" && mv "$W/issues.json.tmp" "$W/issues.json"
    ;;
  none) : ;;
esac
touch "$W/data/control/STOP"
exit 0
STUB
chmod +x "$TMP/stubs/claude"

ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN" && git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# run_loop FIXTURE [TL_OUTCOME]: one pass of bin/agent-loop.sh ROLE=team-lead against the stubs
# above; sets W and RC.
run_loop() {
  W="$TMP/run.$RANDOM"; mkdir -p "$W/data/control" "$W/home"; : > "$W/bdlog"; : > "$W/claude_runs"
  cp "$1" "$W/issues.json"
  RC=0
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home" TL_OUTCOME="${2:-}"
    PATH="$TMP/stubs:$PATH" ROLE=team-lead KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 \
      timeout 30 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
}
claimed() { grep -qE "bd update $1 --claim" "$W/bdlog"; }

test_ac1_startup_does_not_crash_on_hyphenated_role() {
  run_loop "$TMP/issues_ac1.json"
  if grep -qi 'invalid variable name' "$W/out"; then
    fail "ac1: ROLE=team-lead still crashes model selection with 'invalid variable name': $(cat "$W/out")"
    return
  fi
  grep -q 'started: role=team-lead' "$W/out" \
    && pass "ac1: ROLE=team-lead reaches the main loop (no crash on the hyphenated role name)" \
    || fail "ac1: never logged 'started: role=team-lead'. out:$(cat "$W/out")"
}

# ============================================================
# AC4/AC5/AC6 - handle_outcome(): agent-loop.sh must count a reroute or direct fix (needs-team-lead
# cleared, issue left open) as a SUCCESS, not a failed attempt, and must keep the existing
# needs-human note-presence safety net for an escalation. A session that does neither (crashed,
# gave up silently, needs-team-lead still present) must still be treated as an ordinary failure,
# same as every other role's "did nothing" case. These exercise bin/agent-loop.sh's own logic, not
# agents/team-lead.md's prose - the prose can say the right thing while the loop still miscounts it.
# ============================================================

test_ac4_reroute_counts_as_success_not_a_failed_attempt() {
  run_loop "$TMP/issues_ac1.json" reroute
  if grep -qE 'append-notes.*not completed|label add issue-A needs-human' "$W/bdlog"; then
    fail "ac4: reroute (needs-team-lead cleared, issue left open) was miscounted as a failed attempt: $(grep issue-A "$W/bdlog")"
    return
  fi
  if grep -q 'circuit breaker' "$W/data/control/alerts.log" 2>/dev/null; then
    fail "ac4: circuit breaker tripped after a single successful reroute"
    return
  fi
  grep -q 'issue-A triaged (needs-team-lead cleared)' "$W/out" \
    && pass "ac4: reroute (label/stage changed, needs-team-lead cleared) counted as a successful triage" \
    || fail "ac4: no 'triaged (needs-team-lead cleared)' log line. out:$(cat "$W/out")"
}

test_ac5_direct_fix_counts_as_success_not_a_failed_attempt() {
  # AC5: role:/stage: were already correct - only needs-team-lead is cleared, nothing else on the
  # issue changes. Distinct from AC4's reroute fixture (which also swaps stage:) so this pins
  # handle_outcome()'s branch independently of any role:/stage: change.
  run_loop "$TMP/issues_ac1.json" fix
  if grep -qE 'append-notes.*not completed|label add issue-A needs-human' "$W/bdlog"; then
    fail "ac5: direct fix (needs-team-lead cleared, role:/stage: untouched) was miscounted as a failed attempt: $(grep issue-A "$W/bdlog")"
    return
  fi
  [ "$RC" -eq 0 ] || { fail "ac5: loop exited $RC instead of idling/being stopped normally"; return; }
  grep -q 'issue-A triaged (needs-team-lead cleared)' "$W/out" \
    && pass "ac5: direct fix (needs-team-lead cleared, role:/stage: unchanged) counted as a successful triage" \
    || fail "ac5: no 'triaged (needs-team-lead cleared)' log line. out:$(cat "$W/out")"
}

test_ac6_escalation_still_checked_for_a_note_and_counts_as_success() {
  run_loop "$TMP/issues_ac1.json" escalate
  if grep -q 'WITHOUT an explanation' "$W/data/control/alerts.log" 2>/dev/null; then
    fail "ac6: escalation with a note was flagged as having no explanation - note-presence check broken"
    return
  fi
  grep -q 'flagged needs-human by the agent' "$W/data/control/alerts.log" 2>/dev/null \
    && pass "ac6: escalation (needs-human + note, needs-team-lead cleared) recognised and counted as success" \
    || fail "ac6: no 'flagged needs-human by the agent' alert. alerts:$(cat "$W/data/control/alerts.log" 2>/dev/null) out:$(cat "$W/out")"
}

test_ac4_neither_rerouted_nor_escalated_is_an_ordinary_failure() {
  run_loop "$TMP/issues_ac1.json" none
  grep -q 'not completed' "$W/data/control/alerts.log" 2>/dev/null \
    && pass "ac4: a session that left needs-team-lead in place is treated as an ordinary failed attempt" \
    || fail "ac4: expected a 'not completed' failure alert. alerts:$(cat "$W/data/control/alerts.log" 2>/dev/null) out:$(cat "$W/out")"
}

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
