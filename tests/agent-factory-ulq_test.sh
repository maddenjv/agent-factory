#!/usr/bin/env bash
# Acceptance tests for agent-factory-ulq: escalation protocol switches the five roles' own
# "blocked/unsure/attempt-cap" label from needs-human to needs-team-lead, reserving needs-human
# for team-lead's own escalations (agent-factory-dx0, not yet landed).
# One function per acceptance criterion in docs/stories/agent-factory-ulq.md (test_acN_...).
#
# Written BEFORE the design/implementation exist: agents/CLAUDE.project.md and bin/agent-loop.sh
# still hardcode needs-human everywhere today, so ac1-ac4, ac6, ac7 and the team-lead half of ac8
# are expected to FAIL until that lands - that is failing for the right reason (the behaviour
# doesn't exist yet), not a broken test. ac5 and the non-team-lead half of ac8 exercise behaviour
# that must NOT change and should already pass.
#
# ac1/ac2 are content checks on agents/CLAUDE.project.md (the source template). ac3-ac8 extract
# the real functions from bin/agent-loop.sh (source "$FNS") and run them against a stub `bd`, the
# same technique tests/agent-factory-8wq_test.sh and tests/agent-factory-stg_test.sh use.
#
# Run directly: bash tests/agent-factory-ulq_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# ---------------------------------------------------------------------------
# ac1 / ac2: content checks on agents/CLAUDE.project.md
# ---------------------------------------------------------------------------

# The "blocked, unsure, or the input is wrong or under-specified" bullet under ## Tracker, up to
# (not including) the next section header.
blocked_bullet() { awk '/^## Git/{exit} /blocked, unsure/{on=1} on{print}' agents/CLAUDE.project.md; }
dod_section()    { awk '/^## Definition of done/{on=1} on{print}' agents/CLAUDE.project.md; }

test_ac1_blocked_bullet_labels_needs_team_lead() {
  local s; s=$(blocked_bullet)
  [ -n "$s" ] || { fail "ac1: could not find the blocked/unsure bullet in agents/CLAUDE.project.md"; return; }
  echo "$s" | grep -qiE 'append-notes' || { fail "ac1: bullet lost the --append-notes-before-labelling instruction"; return; }
  echo "$s" | grep -q 'needs-team-lead' || { fail "ac1: bullet does not mention needs-team-lead"; return; }
  echo "$s" | grep -qE 'label add <your-issue> needs-team-lead' \
    || { fail "ac1: the label command does not target needs-team-lead"; return; }
  echo "$s" | grep -qE 'label add <your-issue> needs-human' \
    && { fail "ac1: the label command still targets needs-human"; return; }
  pass "ac1: blocked/unsure bullet labels needs-team-lead, not needs-human"
}

test_ac2_definition_of_done_names_needs_team_lead() {
  local s; s=$(dod_section)
  [ -n "$s" ] || { fail "ac2: could not find ## Definition of done section"; return; }
  echo "$s" | grep -q 'needs-team-lead' || { fail "ac2: Definition of done does not name needs-team-lead"; return; }
  echo "$s" | grep -q 'needs-human' \
    && { fail "ac2: Definition of done still names needs-human as the escalation outcome"; return; }
  pass "ac2: Definition of done names needs-team-lead as the escalation-outcome label"
}

# ---------------------------------------------------------------------------
# ac3, ac4, ac8: record_failure()/handle_outcome() behaviour, extracted from bin/agent-loop.sh
# ---------------------------------------------------------------------------

# Anchored to function-name boundaries (not absolute line numbers) so this stays correct however
# many lines unrelated merges insert or remove above it. Covers log(), alert(),
# show_json/issue_field/has_label/is_ready, next_issue(), claim(), release_stale(),
# in_flight()/wip_ok(), is_conflict_rework()/restart_story(), handle_outcome() and record_failure()
# - everything from log() up to (not including) sync_dir(). No top-level execution in this range,
# so sourcing it is side-effect-free.
FNS="$TMP/fns.sh"
sed -n '/^log()/,/^sync_dir()/{/^sync_dir()/d; p}' bin/agent-loop.sh > "$FNS"

# run_record_failure ROLE ID MAX_ATTEMPTS -> BDLOG path; calls record_failure MAX_ATTEMPTS times.
run_record_failure() {
  local role=$1 id=$2 max=$3
  local w; w="$TMP/rf.$RANDOM"; mkdir -p "$w/state" "$w/logs"
  local bdlog="$w/bdlog"; : > "$bdlog"
  ( export BDLOG="$bdlog" PATH="$TMP/bin:$PATH" AGENT_ID="$role" ROLE="$role" \
           CONTROL="$w" LOGDIR="$w/logs" STATE="$w/state" MAX_ATTEMPTS_PER_ISSUE="$max" \
           KIT_DIR="$REPO_ROOT" NOTIFY_URL=""
    source "$FNS"
    for _ in $(seq 1 "$max"); do record_failure "$id"; done ) >/dev/null 2>&1
  echo "$bdlog"
}

# run_handle_outcome ROLE ID SHOW_JSON -> "RC BDLOG_PATH"; RC is handle_outcome's exit code.
run_handle_outcome() {
  local role=$1 id=$2 show_json=$3
  local w; w="$TMP/ho.$RANDOM"; mkdir -p "$w/state" "$w/logs"
  local bdlog="$w/bdlog"; : > "$bdlog"
  echo "$show_json" > "$w/show.json"
  local rc=0
  ( export BDLOG="$bdlog" SHOWFILE="$w/show.json" PATH="$TMP/bin:$PATH" AGENT_ID="$role" ROLE="$role" \
           CONTROL="$w" LOGDIR="$w/logs" STATE="$w/state" KIT_DIR="$REPO_ROOT" NOTIFY_URL=""
    source "$FNS"
    handle_outcome "$id" ) >/dev/null 2>&1
  rc=$?
  echo "$rc $bdlog"
}

cat > "$TMP/bin/bd" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$BDLOG"
case "$1" in
  show) cat "$SHOWFILE" 2>/dev/null ;;
  ready) echo '[]' ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/bd"

test_ac3_attempt_cap_labels_needs_team_lead_for_the_five_roles() {
  local role log
  for role in po architect engineer qa reviewer; do
    log=$(run_record_failure "$role" "iss-$role" 2)
    grep -qE 'label add iss-'"$role"' needs-team-lead' "$log" \
      || { fail "ac3($role): attempt-cap backstop did not label needs-team-lead"; return; }
    grep -qE 'label add iss-'"$role"' needs-human' "$log" \
      && { fail "ac3($role): attempt-cap backstop still labels needs-human"; return; }
    grep -qE -- '--append-notes .*not completed after 2 attempt' "$log" \
      || { fail "ac3($role): attempt-cap note text ('not completed after N attempt(s)...') is missing"; return; }
  done
  pass "ac3: attempt-cap backstop labels needs-team-lead (with the usual note) for all five roles"
}

test_ac4_missing_note_backstop_fires_for_needs_team_lead() {
  local show out rc log
  show='[{"id":"t-1","status":"open","assignee":"qa","labels":["role:qa","needs-team-lead"],"notes":""}]'
  out=$(run_handle_outcome qa t-1 "$show"); rc=${out%% *}; log=${out#* }
  [ "$rc" = 0 ] || { fail "ac4: handle_outcome did not treat needs-team-lead as a legitimate outcome (rc=$rc)"; return; }
  grep -qE -- '--append-notes' "$log" || { fail "ac4: no note appended for an unexplained needs-team-lead"; return; }
  grep -qiE 'transcript' "$log" || { fail "ac4: appended note does not point at the transcript"; return; }

  # A needs-team-lead issue WITH notes must not get a redundant note appended.
  show='[{"id":"t-2","status":"open","assignee":"qa","labels":["role:qa","needs-team-lead"],"notes":"already explained"}]'
  out=$(run_handle_outcome qa t-2 "$show"); log=${out#* }
  grep -qE -- '--append-notes' "$log" && { fail "ac4: note appended even though one already existed"; return; }
  pass "ac4: missing-note backstop fires for needs-team-lead exactly as it does for needs-human"
}

test_ac8_team_lead_escalation_still_uses_needs_human() {
  local log show out rc
  log=$(run_record_failure team-lead iss-tl 2)
  grep -qE 'label add iss-tl needs-human' "$log" \
    || { fail "ac8: team-lead's attempt-cap backstop no longer labels needs-human"; return; }
  grep -qE 'label add iss-tl needs-team-lead' "$log" \
    && { fail "ac8: team-lead's attempt-cap backstop was switched to needs-team-lead"; return; }

  show='[{"id":"t-3","status":"open","assignee":"team-lead","labels":["role:team-lead","needs-human"],"notes":""}]'
  out=$(run_handle_outcome team-lead t-3 "$show"); rc=${out%% *}
  [ "$rc" = 0 ] || { fail "ac8: handle_outcome no longer treats team-lead's own needs-human as legitimate"; return; }
  pass "ac8: team-lead's own escalation is untouched - still needs-human, both backstops"
}

# ---------------------------------------------------------------------------
# ac5, ac6: next_issue() ready-work exclusion
# ---------------------------------------------------------------------------

# issue ID LABELS_CSV ASSIGNEE
issue() {
  local id=$1 labels=$2 assignee=${3:-}
  jq -n --arg id "$id" --arg assignee "$assignee" --arg labels "$labels" \
    '{id:$id, assignee:$assignee, labels:($labels|split(","))}'
}

run_next_issue() {  # run_next_issue ROLE < fixture-issues (one JSON object per line)
  local role=$1 fixture w; fixture="$TMP/ni.$RANDOM.json"; w="$TMP/ni-log.$RANDOM"; mkdir -p "$w"
  jq -s . > "$fixture"
  FIXTURE_READY="$fixture" PATH="$TMP/bin-ni:$PATH" AGENT_ID="$role" ROLE="$role" LOGDIR="$w" bash -c '
    source "$1"; next_issue' _ "$FNS"
}

mkdir -p "$TMP/bin-ni"
cat > "$TMP/bin-ni/bd" <<'STUB'
#!/usr/bin/env bash
[ "$1" = ready ] && cat "$FIXTURE_READY"
exit 0
STUB
chmod +x "$TMP/bin-ni/bd"

test_ac5_needs_human_still_excluded_from_ready_work() {
  local got
  got=$( { issue a1 "role:qa,needs-human"; issue a2 "role:qa"; } | run_next_issue qa)
  [ "$got" = a2 ] && pass "ac5: needs-human-labelled issue still never claimed (unchanged)" \
    || fail "ac5: got '$got', expected 'a2' (needs-human issue a1 must stay excluded)"
}

test_ac6_needs_team_lead_excluded_from_ready_work() {
  local got
  got=$( { issue a1 "role:qa,needs-team-lead"; issue a2 "role:qa"; } | run_next_issue qa)
  [ "$got" = a2 ] && pass "ac6: needs-team-lead-labelled issue is never claimed or re-claimed" \
    || fail "ac6: got '$got', expected 'a2' (needs-team-lead issue a1 must be excluded, same as needs-human)"
}

# ---------------------------------------------------------------------------
# ac7: in_flight()/wip_ok() throttle excludes stories stalled on needs-team-lead
# ---------------------------------------------------------------------------

FLOWFNS="$TMP/flowfns.sh"
sed -n '/^in_flight()/,/^wip_ok()/p' bin/agent-loop.sh > "$FLOWFNS"

mkdir -p "$TMP/bin-flow"
cat > "$TMP/bin-flow/bd" <<'STUB'
#!/usr/bin/env bash
[ "$1" = list ] && cat "$FIXTURE_LIST"
exit 0
STUB
chmod +x "$TMP/bin-flow/bd"

# flow_issue ID STORY ROLE STATUS [EXTRA_LABELS_CSV] [DEP_IDS_CSV]
flow_issue() {
  local id=$1 story=$2 role=$3 status=$4 extra=${5:-} deps=${6:-}
  jq -n --arg id "$id" --arg st "$story" --arg role "$role" --arg status "$status" \
        --arg extra "$extra" --arg deps "$deps" '
    {id:$id, status:$status,
     labels:(["story:"+$st,"role:"+$role] + ($extra|split(",")|map(select(.!="")))),
     dependencies:($deps|split(",")|map(select(.!=""))|map({issue_id:$id,depends_on_id:.,type:"blocks"}))}'
}
flow_chain() {  # a healthy in-progress story: implement open, verify/review blocked behind it
  local s=$1
  flow_issue "$s-impl" "$s" engineer open "${2:-}"
  flow_issue "$s-ver" "$s" qa open "" "$s-impl"
  flow_issue "$s-rev" "$s" reviewer open "" "$s-ver"
}
run_flow() {  # run_flow ROLE WIP_LIMIT < fixture-issues -> "<in_flight> <wip_ok:0|1>"
  local role=${1:-po} limit=${2:-2} fixture; fixture="$TMP/flow.$RANDOM.json"
  jq -s . > "$fixture"
  FIXTURE_LIST="$fixture" PATH="$TMP/bin-flow:$PATH" ROLE="$role" WIP_LIMIT="$limit" bash -c '
    source "$1"; n=$(in_flight); if wip_ok; then ok=1; else ok=0; fi; echo "$n $ok"' _ "$FLOWFNS"
}

test_ac7_story_stalled_on_needs_team_lead_not_counted() {
  local out
  out=$( { flow_chain a; flow_chain b needs-team-lead; } | run_flow po 2)
  [ "$out" = "1 1" ] || { fail "ac7(direct): got '$out', expected '1 1' (story b stalled on needs-team-lead excluded)"; return; }
  # needs-team-lead further down the chain (not on the head issue) also stalls the whole story.
  out=$( { flow_issue c-impl c engineer open needs-team-lead
           flow_issue c-ver c qa open "" c-impl
           flow_issue c-rev c reviewer open "" c-ver; } | run_flow po 1)
  [ "$out" = "0 1" ] || { fail "ac7(chain): got '$out', expected '0 1'"; return; }
  pass "ac7: story stalled behind needs-team-lead excluded from WIP count, same as needs-human"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
