#!/usr/bin/env bash
# Acceptance tests for agent-factory-zwn7: WIP_LIMIT yields the PO's throttle when it would
# otherwise leave a downstream role (architect/engineer/qa/reviewer) idle.
# One function per acceptance criterion in docs/stories/agent-factory-zwn7.md (test_acN_...).
# in_flight()/wip_ok() (and any helpers added alongside them) are extracted from the "throttles"
# section of bin/agent-loop.sh and run against a stub `bd` whose `list --json` output is a fixture.
# Run directly: bash tests/agent-factory-zwn7_test.sh
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
[ "$1" = list ] && cat "$FIXTURE"
exit 0
STUB
chmod +x "$TMP/bin/bd"

# Extract every function in the throttles section (whatever it ends up containing) rather than
# naming just in_flight/wip_ok by line pattern, so this survives the section growing a helper.
sed -n '/^# ---------- throttles ----------/,/^# ---------- usage limits ----------/p' bin/agent-loop.sh > "$TMP/fns.sh"

# issue <id> <story> <role> <status> [labels,extra] [dep-ids blocking it, comma-sep]
issue() {
  local id=$1 story=$2 role=$3 status=$4 extra=${5:-} deps=${6:-}
  jq -n --arg id "$id" --arg st "$story" --arg role "$role" --arg status "$status" \
        --arg extra "$extra" --arg deps "$deps" '
    {id:$id, status:$status,
     labels:(["story:"+$st,"role:"+$role] + ($extra|split(",")|map(select(.!="")))),
     dependencies:($deps|split(",")|map(select(.!=""))|map({issue_id:$id,depends_on_id:.,type:"blocks"}))}'
}
# A bare open issue with no role label - used as an unmet dependency to make another issue blocked.
blocker() { jq -n --arg id "$1" --arg st "$2" '{id:$id, status:"open", labels:["story:"+$st], dependencies:[]}'; }
# A minimal in-flight story: just its (still open) reviewer issue, as in agent-factory-8wq's tests -
# enough to count toward in_flight() without needing every stage present.
inflight_story() { issue "$1-rev" "$1" reviewer open "${2:-}"; }

# run <ROLE> <WIP_LIMIT> (issues on stdin as JSON objects) -> prints "<in_flight> <wip_ok:0|1>"
run() {
  jq -s . > "$TMP/fixture.json"
  FIXTURE="$TMP/fixture.json" PATH="$TMP/bin:$PATH" ROLE=${1:-po} WIP_LIMIT=${2:-2} bash -c '
    source "$1"; n=$(in_flight); if wip_ok; then ok=1; else ok=0; fi; echo "$n $ok"' _ "$TMP/fns.sh"
}

test_ac1_idle_role_lets_po_start_at_limit() {
  # 2 in-flight stories at WIP_LIMIT=2; engineer, qa and reviewer all have busy work, but no
  # architect issue exists anywhere - architect is idle, so the PO should be let through.
  local out; out=$( { inflight_story a; inflight_story b
    issue c-impl c engineer open
    issue d-ver d qa open; } | run po 2)
  [ "$out" = "2 1" ] || { fail "ac1: no architect work at all: got '$out', expected '2 1'"; return; }
  # A role with an issue that exists but is blocked (not ready) and not claimed is still idle -
  # an unready open issue must not count as "has work".
  out=$( { inflight_story a; inflight_story b
    issue c-impl c engineer open
    issue d-ver d qa open
    blocker e-precursor e
    issue e-design e architect open "" e-precursor; } | run po 2)
  [ "$out" = "2 1" ] && pass "ac1: idle/blocked-only role lets PO start despite being at WIP_LIMIT" \
    || fail "ac1 (blocked issue doesn't count as busy): got '$out', expected '2 1'"
}

test_ac2_every_role_busy_holds_po_back() {
  # Same WIP_LIMIT=2 in-flight count, but now every downstream role has ready-or-in-progress work.
  local out; out=$( { inflight_story a; inflight_story b
    issue c-impl c engineer open
    issue d-ver d qa open
    issue e-design e architect open; } | run po 2)
  [ "$out" = "2 0" ] || { fail "ac2 (open architect issue): got '$out', expected '2 0'"; return; }
  # An in-progress (claimed) issue counts as "has work" too, exactly like a ready one.
  out=$( { inflight_story a; inflight_story b
    issue c-impl c engineer in_progress
    issue d-ver d qa open
    issue e-design e architect in_progress; } | run po 2)
  [ "$out" = "2 0" ] && pass "ac2: all four roles busy (ready or in-progress) holds the PO back, as today" \
    || fail "ac2 (in_progress issue): got '$out', expected '2 0'"
}

test_ac3_po_unblocks_once_a_role_runs_out_of_work() {
  local out; out=$( { inflight_story a; inflight_story b
    issue c-impl c engineer open
    issue d-ver d qa open
    issue e-design e architect open; } | run po 2)
  [ "$out" = "2 0" ] || { fail "ac3: precondition (all busy) got '$out', expected '2 0'"; return; }
  # Architect's only issue closes (its work ran out); next WIP check should let the PO through.
  out=$( { inflight_story a; inflight_story b
    issue c-impl c engineer open
    issue d-ver d qa open
    issue e-design e architect closed; } | run po 2)
  [ "$out" = "2 1" ] && pass "ac3: PO's next check allows a new story once a role goes idle" \
    || fail "ac3: got '$out', expected '2 1'"
}

test_ac4_needs_human_stalled_role_issue_excluded_from_both() {
  # architect's only issue is on a story stalled behind needs-human; it must not count as
  # in-flight (agent-factory-8wq, unchanged) nor as "architect has work" (new for this story).
  local out; out=$( { inflight_story a; inflight_story b
    issue c-impl c engineer open
    issue d-ver d qa open
    issue e-design e architect open needs-human; } | run po 2)
  [ "$out" = "2 1" ] && pass "ac4: needs-human-stalled issue excluded from in-flight count and role-busy check" \
    || fail "ac4: got '$out', expected '2 1'"
  # Same, but the role's issue is merely downstream of (depends on) the flagged one.
  out=$( { inflight_story a; inflight_story b
    issue c-impl c engineer open
    issue d-ver d qa open
    issue e-flag e architect open needs-team-lead
    issue e-design e architect open "" e-flag; } | run po 2)
  [ "$out" = "2 1" ] && pass "ac4: architect issue blocked behind a needs-team-lead issue also excluded" \
    || fail "ac4 (dependency case): got '$out', expected '2 1'"
}

test_ac5_limit_still_holds_when_everyone_busy_and_others_stalled() {
  local out; out=$( { inflight_story a; inflight_story b
    issue c-impl c engineer open
    issue d-ver d qa open
    issue e-design e architect open
    inflight_story f needs-human
    inflight_story g needs-team-lead; } | run po 2)
  [ "$out" = "2 0" ] && pass "ac5: WIP_LIMIT still holds the PO back when every role has work" \
    || fail "ac5: got '$out', expected '2 0'"
}

test_ac6_docs_state_limit_yields_to_keep_roles_busy() {
  local f
  for f in README.md .env.example; do
    grep -i 'WIP_LIMIT' "$f" | grep -qiE 'idle|yield' \
      || { fail "ac6: $f WIP_LIMIT description doesn't mention yielding/idle roles"; return; }
  done
  pass "ac6: README.md and .env.example document that the limit yields to keep roles busy"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
