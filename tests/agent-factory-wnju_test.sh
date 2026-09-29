#!/usr/bin/env bash
# Acceptance tests for agent-factory-wnju: feature.sh-created issues go to team-lead's sweep
# first, not straight to role:po. One function per acceptance criterion in
# docs/stories/agent-factory-wnju.md (test_acN_...).
#
# AC1 (feature.sh applies no role:* label) is a code-level check: stub `bd`, run bin/feature.sh,
# inspect the `bd create` invocation it made.
#
# AC2 (a feature.sh-created issue is swept by team-lead exactly like any other no-role:*-label
# issue, with no remaining special case) has two parts: a behavioural check that runs the real
# bin/agent-loop.sh with ROLE=team-lead against a stub `bd`/`claude` - same harness style as
# tests/agent-factory-m7af_test.sh, which this story's sweep-widening behaviour was originally
# pinned by - and a prose check on agents/team-lead.md confirming no language remains that frames
# feature.sh issues as exempt from (or already triaged before reaching) the sweep.
#
# AC3/AC4 (sweep-found issue with/without a story:<id> label routes to diagnose-and-reroute vs.
# role:po) are prose checks on agents/team-lead.md - this story reuses agent-factory-m7af's
# existing diagnose logic rather than changing it, so these confirm that logic still reads as
# applying uniformly, not that it was rewritten.
#
# AC5 (README.md's Flow step 1 and docs/ARCHITECTURE.md's sweep description describe feature.sh
# issues going to team-lead first, not directly to role:po) are prose checks on those two docs.
#
# Written derived only from docs/stories/agent-factory-wnju.md's acceptance criteria - not from
# docs/design/agent-factory-wnju.md (this story has no design stage; see the story's issue notes).
#
# Run directly: bash tests/agent-factory-wnju_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# ============================================================
# AC1 - bin/feature.sh creates an issue with no role:* label (not role:po, not any other role:*).
# ============================================================

test_ac1_feature_sh_creates_issue_with_no_role_star_label() {
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/stubs"

  # Stub bd: logs the exact args feature.sh invoked it with, then answers `bd create --json`
  # the way the real CLI would (a JSON object with an id), so feature.sh's `jq` pipe succeeds.
  cat > "$tmp/stubs/bd" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "$BDLOG"
if [ "$1" = create ]; then
  echo '{"id":"issue-new"}'
fi
exit 0
STUB
  chmod +x "$tmp/stubs/bd"

  BDLOG="$tmp/bdlog"; : > "$BDLOG"
  local out
  out=$(PATH="$tmp/stubs:$PATH" BDLOG="$BDLOG" bash "$KIT_DIR/bin/feature.sh" "a title" "a description" 2>&1)

  if ! grep -q '^create ' "$BDLOG"; then
    fail "ac1: feature.sh never called 'bd create'. output: $out log: $(cat "$BDLOG")"
    return
  fi
  if grep -qE '(^| )-l ?[^ ]*role:' "$BDLOG"; then
    fail "ac1: feature.sh's bd create call still applies a role:* label: $(cat "$BDLOG")"
    return
  fi
  pass "ac1: bin/feature.sh's bd create call carries no role:* label"
}

# ============================================================
# AC2 - team-lead's sweep picks up a feature.sh-created issue (no role:* label, not
# needs-human/needs-team-lead) exactly like any other such issue; no special case remains for it
# in behavior or in agents/team-lead.md.
# ============================================================

TMP2="$(mktemp -d)"; trap 'rm -rf "$TMP2"' EXIT
mkdir -p "$TMP2/stubs"

# issue-FS: what bin/feature.sh now produces - type feature, no role:* label, not
# needs-human/needs-team-lead. issue-G: an ordinary role:*-labelled issue, must never be claimed
# by this sweep (control, mirrors tests/agent-factory-m7af_test.sh's AC2).
cat > "$TMP2/issues.json" <<'JSON'
[
  {"id":"issue-FS","status":"open","assignee":"","type":"feature","labels":[]},
  {"id":"issue-G","status":"open","assignee":"","type":"task","labels":["role:qa","stage:verify"]}
]
JSON

cat > "$TMP2/stubs/bd" <<'STUB'
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
chmod +x "$TMP2/stubs/bd"

cat > "$TMP2/stubs/claude" <<'STUB'
#!/usr/bin/env bash
echo x >> "$W/claude_runs"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0}'
touch "$W/data/control/STOP"
exit 0
STUB
chmod +x "$TMP2/stubs/claude"

ORIGIN2="$TMP2/origin"
git init -q -b main "$ORIGIN2" && git -C "$ORIGIN2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

run_loop2() {
  W="$TMP2/run.$RANDOM"; mkdir -p "$W/data/control" "$W/home"; : > "$W/bdlog"; : > "$W/claude_runs"
  cp "$TMP2/issues.json" "$W/issues.json"
  RC=0
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home"
    PATH="$TMP2/stubs:$PATH" ROLE=team-lead KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN2" \
      PREFLIGHT=0 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 IDLE_SLEEP=1 \
      timeout 30 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
}
claimed2() { grep -qE "bd update $1 --claim" "$W/bdlog"; }
modified2() { grep -qE "^bd (update|label|comment) $1\b" "$W/bdlog"; }

test_ac2_sweep_claims_a_feature_sh_created_issue_like_any_other_unrouted_issue() {
  run_loop2
  claimed2 issue-FS \
    && pass "ac2: sweep claimed issue-FS (a feature.sh-shaped issue: no role:* label, type feature) exactly like any other unrouted issue" \
    || fail "ac2: sweep never claimed issue-FS - a feature.sh-created issue is not being picked up. bdlog:$(cat "$W/bdlog") out:$(cat "$W/out")"
  if modified2 issue-G; then
    fail "ac2: sweep touched issue-G, which carries a role:* label and must never be claimed by this sweep: $(grep issue-G "$W/bdlog")"
  else
    pass "ac2: ordinary role:*-labelled issue-G was left untouched by the sweep"
  fi
}

test_ac2_no_special_case_remains_in_team_lead_docs_for_feature_sh_issues() {
  local tl="agents/team-lead.md"
  [ -f "$tl" ] || { fail "ac2: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$tl")
  # The old framing said this sweep only covers work that reached the board "outside the normal
  # feature.sh intake path" - i.e. feature.sh issues were implicitly exempt. That phrasing must
  # be gone now that feature.sh issues are explicitly in scope.
  if echo "$c" | grep -qiE 'outside the normal `?feature\.sh`? intake path'; then
    fail "ac2: agents/team-lead.md still frames the sweep as covering work 'outside the normal feature.sh intake path' - this implies feature.sh issues are exempt, which this story removes"
    return
  fi
  echo "$c" | grep -qiE '`?feature\.sh`?' \
    || { fail "ac2: agents/team-lead.md's sweep section makes no mention of feature.sh-created issues being in scope"; return; }
  pass "ac2: agents/team-lead.md no longer frames feature.sh issues as exempt from the sweep, and explicitly mentions them as in scope"
}

# ============================================================
# AC3 - a sweep-found issue with no story:<id> label (the common case, e.g. a feature.sh issue)
# gets labelled role:po with a bd comment explaining the routing.
# ============================================================

test_ac3_sweep_found_issue_with_no_story_label_routes_to_role_po_with_comment() {
  local tl="agents/team-lead.md"
  [ -f "$tl" ] || { fail "ac3: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$tl")
  echo "$c" | grep -qE 'role:po' \
    || { fail "ac3: no instruction to label a no-story-context sweep issue role:po"; return; }
  echo "$c" | grep -qiE 'no story:<story-id>|no story context|unfiled|raw (feature|bug) report' \
    || { fail "ac3: no guidance for the case where a sweep-found issue carries no story:<story-id> label"; return; }
  echo "$c" | grep -qE 'bd comment' \
    || { fail "ac3: no instruction to leave a bd comment stating the issue was routed to po as a new request"; return; }
  pass "ac3: prompt directs a no-story-context sweep issue (e.g. from feature.sh) to role:po with an explanatory bd comment"
}

# ============================================================
# AC4 - a sweep-found issue that does carry a story:<id> label goes through the existing
# diagnose-and-reroute process, not a default to role:po.
# ============================================================

test_ac4_sweep_found_issue_with_story_label_uses_diagnose_and_reroute_not_default_po() {
  local tl="agents/team-lead.md"
  [ -f "$tl" ] || { fail "ac4: agents/team-lead.md does not exist"; return; }
  local c; c=$(cat "$tl")
  echo "$c" | grep -qE 'story:<story-id>' \
    || { fail "ac4: no instruction to check a sweep-found issue for a story:<story-id> label"; return; }
  echo "$c" | grep -qiE 'same (way|process|steps|mechanics)|steps? 1-?4|as (you|it) (already|would)' \
    || { fail "ac4: no instruction to reuse the existing investigate/diagnose process for a sweep-found story issue, rather than defaulting it to role:po"; return; }
  pass "ac4: prompt routes a sweep-found issue carrying a story:<story-id> label through the existing diagnose-and-reroute process, not a role:po default"
}

# ============================================================
# AC5 - README.md's Flow step 1, and docs/ARCHITECTURE.md's description of team-lead's sweep,
# describe feature.sh issues going to team-lead first (not directly to role:po), matching actual
# behavior.
# ============================================================

test_ac5_readme_flow_step1_describes_feature_sh_going_to_team_lead_first() {
  local f="README.md"
  [ -f "$f" ] || { fail "ac5: README.md does not exist"; return; }
  # Grab the "1. You: `feature.sh ...`" Flow step specifically, not the whole file, so this
  # doesn't accidentally pass on unrelated team-lead/role:po mentions elsewhere in the doc.
  local step1
  step1=$(awk '/^## Flow/{f=1} f && /^1\./{print; exit}' "$f")
  [ -n "$step1" ] || { fail "ac5: could not find Flow step 1 in README.md"; return; }
  # Read the step 1 line plus its continuation lines (indented, no leading "N.")
  local block
  block=$(awk '/^## Flow/{f=1; next} f && /^1\./{p=1} f && p && /^[0-9]+\./ && !/^1\./{exit} f && p{print}' "$f")
  if echo "$block" | grep -qiE 'creates an issue labell?ed `?role:po`?'; then
    fail "ac5: README.md's Flow step 1 still says feature.sh creates an issue labelled role:po directly: $block"
    return
  fi
  echo "$block" | grep -qiE 'team-lead' \
    || { fail "ac5: README.md's Flow step 1 makes no mention of team-lead triaging the feature.sh issue: $block"; return; }
  pass "ac5: README.md's Flow step 1 describes feature.sh issues going to team-lead first, not directly to role:po"
}

test_ac5_architecture_sweep_description_covers_feature_sh_and_notes_m7af_framing_obsolete() {
  local f="docs/ARCHITECTURE.md"
  [ -f "$f" ] || { fail "ac5: docs/ARCHITECTURE.md does not exist"; return; }
  local c; c=$(cat "$f")
  if echo "$c" | grep -qiE 'outside the normal `?feature\.sh`? intake path'; then
    fail "ac5: docs/ARCHITECTURE.md still describes the no-role-label sweep as covering work 'outside the normal feature.sh intake path' - the exact framing this story makes obsolete"
    return
  fi
  echo "$c" | grep -qiE '`?feature\.sh`?' \
    || { fail "ac5: docs/ARCHITECTURE.md's team-lead description makes no mention of feature.sh"; return; }
  echo "$c" | grep -qE 'agent-factory-wnju' \
    || { fail "ac5: docs/ARCHITECTURE.md does not reference agent-factory-wnju as the story that widened the sweep to include feature.sh issues"; return; }
  pass "ac5: docs/ARCHITECTURE.md describes feature.sh issues as part of team-lead's sweep and notes the prior agent-factory-m7af framing is now obsolete"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
