#!/usr/bin/env bash
# Acceptance tests for agent-factory-8wq: stalled (needs-human) stories don't count toward WIP_LIMIT.
# One function per acceptance criterion in docs/stories/agent-factory-8wq.md (test_acN_...).
# in_flight()/wip_ok() are extracted from bin/agent-loop.sh and run against a stub `bd` whose
# `list --json` output is a fixture file. Run directly: bash tests/agent-factory-8wq_test.sh
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

# Extract the throttle functions (from the in_flight definition through wip_ok's line).
sed -n '/^in_flight()/,/^wip_ok()/p' bin/agent-loop.sh > "$TMP/fns.sh"

# issue <id> <story> <role> <status> [labels,extra] [dep-ids blocking it, comma-sep]
issue() {
  local id=$1 story=$2 role=$3 status=$4 extra=${5:-} deps=${6:-}
  jq -n --arg id "$id" --arg st "$story" --arg role "$role" --arg status "$status" \
        --arg extra "$extra" --arg deps "$deps" '
    {id:$id, status:$status,
     labels:(["story:"+$st,"role:"+$role] + ($extra|split(",")|map(select(.!="")))),
     dependencies:($deps|split(",")|map(select(.!=""))|map({issue_id:$id,depends_on_id:.,type:"blocks"}))}'
}
# Full normal chain for a story in progress: impl open, verify blocked on impl, review blocked on verify.
chain() { # chain <story> [extra labels on implement issue]
  local s=$1
  issue "$s-impl" "$s" engineer open "${2:-}"
  issue "$s-ver" "$s" qa open "" "$s-impl"
  issue "$s-rev" "$s" reviewer open "" "$s-ver"
}

# count <ROLE> <WIP_LIMIT>  (issues on stdin as JSON objects) -> prints "<in_flight> <wip_ok:0|1>"
run() {
  jq -s . > "$TMP/fixture.json"
  FIXTURE="$TMP/fixture.json" PATH="$TMP/bin:$PATH" ROLE=${1:-po} WIP_LIMIT=${2:-2} bash -c '
    source "$1"; n=$(in_flight); if wip_ok; then ok=1; else ok=0; fi; echo "$n $ok"' _ "$TMP/fns.sh"
}

test_ac1_one_stalled_of_two_counts_one_and_po_may_start() {
  local out; out=$( { chain a; chain b needs-human; } | run po 2)
  [ "$out" = "1 1" ] && pass "ac1: stalled story excluded; count 1, PO allowed" || fail "ac1: got '$out', expected '1 1'"
}

test_ac2_story_blocked_behind_needs_human_not_counted() {
  # needs-human issue is in the design chain; implement/verify/review wait on it via deps.
  local out; out=$( { chain a
    issue b-impl b engineer open "needs-human"
    issue b-ver b qa open "" b-impl
    issue b-rev b reviewer open "" b-ver; } | run po 2)
  [ "$out" = "1 1" ] || { fail "ac2 (nh on head): got '$out', expected '1 1'"; return; }
  # needs-human on a *different* story's issue that this story's issue depends on is not required;
  # here the flagged issue is a non-reviewer issue and only downstream issues are merely blocked.
  out=$( { issue c-impl c engineer open needs-human
           issue c-rev c reviewer open "" c-impl; } | run po 1)
  [ "$out" = "0 1" ] && pass "ac2: story with issues blocked behind needs-human not counted" || fail "ac2 (direct dep): got '$out', expected '0 1'"
}

test_ac3_normal_and_dependency_blocked_story_still_counts() {
  local out; out=$( { chain a; chain b; } | run po 5)
  [ "$out" = "2 1" ] || { fail "ac3: two healthy chains got '$out', expected '2 1'"; return; }
  # A story whose only open issue is the review (earlier stages closed) still counts.
  out=$( issue d-rev d reviewer open | run po 5)
  [ "$out" = "1 1" ] || { fail "ac3: review-only story got '$out', expected '1 1'"; return; }
  # Closed needs-human issue must not stall the story.
  out=$( { issue e-impl e engineer closed needs-human; issue e-rev e reviewer open "" e-impl; } | run po 5)
  [ "$out" = "1 1" ] && pass "ac3: healthy / merely-blocked / closed-needs-human stories counted" || fail "ac3: closed needs-human got '$out', expected '1 1'"
}

test_ac4_released_story_counts_again() {
  local out
  out=$( { chain a; chain b needs-human; } | run po 2); [ "$out" = "1 1" ] || { fail "ac4: precondition got '$out'"; return; }
  out=$( { chain a; chain b; } | run po 2)
  [ "$out" = "2 0" ] && pass "ac4: after needs-human removed the story counts and PO is held" || fail "ac4: got '$out', expected '2 0'"
}

test_ac5_limit_still_holds_with_stalled_others() {
  local out; out=$( { chain a; chain b; chain c needs-human; chain d needs-human; } | run po 2)
  [ "$out" = "2 0" ] || { fail "ac5: got '$out', expected '2 0'"; return; }
  out=$( { chain a; chain b; chain c needs-human; } | run engineer 2)
  [ "${out#* }" = "1" ] && pass "ac5: limit unchanged for PO; non-PO roles unaffected" || fail "ac5: non-PO role got '$out'"
}

test_ac6_docs_state_stalled_not_counted() {
  local f
  for f in README.md .env.example; do
    grep -i 'WIP_LIMIT' "$f" | grep -qi 'needs-human' \
      || { fail "ac6: $f WIP_LIMIT line doesn't mention needs-human not being counted"; return; }
  done
  grep -i 'WIP_LIMIT' README.md .env.example | grep -qiE 'not counted|don.t count|excluded|not count' \
    && pass "ac6: README.md and .env.example document the exclusion" || fail "ac6: no 'not counted' wording"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
