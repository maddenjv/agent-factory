#!/usr/bin/env bash
# Tests for agent-factory-7yn3: team-lead can take over an escalated issue still assigned to the
# escalating role. The `bd` stub mimics real bd's flag validation (--force and --if-assignee are
# mutually exclusive), which agent-factory-9awd/rcjb's permissive stubs missed.
# Run directly: bash tests/agent-factory-7yn3_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FNS="$TMP/fns.sh"
sed -n '/^log()/,/^sync_dir()/{/^sync_dir()/d; p}' bin/agent-loop.sh > "$FNS"
cat bin/bdjson.sh >> "$FNS"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/bd" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list|ready) cat "$FIXTURE";;
  show) jq -c --arg id "$2" '.[] | select(.id == $id)' "$FIXTURE";;
  update)
    if [ -n "${BD_FAIL:-}" ]; then echo "boom" >&2; exit 1; fi
    id=$2; shift 2; force=0; ifa=""; assignee=""; args="$*"
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) force=1;; --if-assignee) ifa=$2; shift;; --assignee) assignee=$2; shift;;
      esac; shift
    done
    if [ "$force" = 1 ] && [ -n "$ifa" ]; then
      echo "Error: if any flags in the group [force if-assignee] are set none of the others can be; [force if-assignee] were all set" >&2; exit 1
    fi
    cur=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .assignee // ""' "$FIXTURE")
    if [ -n "$ifa" ] && [ "$ifa" != "$cur" ]; then exit 13; fi
    echo "update $id $args" >> "$BDLOG"
    if [ -n "$assignee" ]; then
      jq --arg id "$id" --arg a "$assignee" 'map(if .id == $id then .assignee = $a else . end)' "$FIXTURE" > "$FIXTURE.n" && mv "$FIXTURE.n" "$FIXTURE"
    fi;;
esac
exit 0
STUB
chmod +x "$TMP/bin/bd"

issue() {  # issue ID ASSIGNEE LABELS_CSV
  jq -n --arg id "$1" --arg a "$2" --arg l "$3" \
    '{id:$id, status:"in_progress", assignee:$a, labels:($l|split(",")), lease_expires_at:"2000-01-01T00:00:00Z"}'
}

FIXTURE="$TMP/fixture.json"; BDLOG="$TMP/bd.log"
export FIXTURE BDLOG
run() {
  jq -s . > "$FIXTURE"; : > "$BDLOG"
  PATH="$TMP/bin:$PATH" AGENT_ID=team-lead ROLE="${AS_ROLE:-team-lead}" LOGDIR="$TMP" CONTROL="$TMP" STATE="$TMP" \
    bash -c 'source "$1"; shift; eval "$1"' _ "$FNS" "$1" 2>"$TMP/err"
}

test_takeover_all_build_roles() {
  local r out
  for r in qa engineer po architect reviewer; do
    out=$(issue ar5n "$r" "needs-team-lead,role:$r,stage:verify,story:agent-factory-lv8s" \
      | run 'next_issue; claim ar5n; echo "rc=$?"; jq -r ".[0].assignee" "$FIXTURE"')
    [ "$(sed -n 1p <<<"$out")" = ar5n ] || { fail "takeover($r): next_issue did not return the issue: $out"; return; }
    grep -q '^rc=0$' <<<"$out" || { fail "takeover($r): claim failed: $out"; return; }
    [ "$(tail -1 <<<"$out")" = team-lead ] || { fail "takeover($r): assignee not team-lead: $out"; return; }
    grep -q -- '--force' "$BDLOG" && ! grep -q -- '--if-assignee' "$BDLOG" \
      || { fail "takeover($r): wrong update argv: $(cat "$BDLOG")"; return; }
  done
  pass "takeover: team-lead claims stale escalator claim (expired lease, extra labels) for every build role"
}

test_takeover_future_lease() {
  local out
  out=$(jq -n '{id:"x1",status:"in_progress",assignee:"qa",labels:["needs-team-lead","role:qa"],lease_expires_at:"2999-01-01T00:00:00Z"}' \
    | run 'claim x1; echo "rc=$?"')
  grep -q '^rc=0$' <<<"$out" && grep -q -- '--force' "$BDLOG" \
    && pass "takeover: live lease does not block" || fail "takeover: live lease blocked: $out"
}

test_other_agents_not_taken() {
  local out
  out=$(issue a1 alice "needs-team-lead,role:qa" | run 'next_issue; claim a1; echo "rc=$?"')
  { grep -q '^rc=1$' <<<"$out" && [ ! -s "$BDLOG" ] && [ "$(sed -n 1p <<<"$out")" = rc=1 ]; } \
    || { fail "alice's issue was selected/taken: $out"; return; }
  out=$(issue a2 engineer "needs-team-lead,role:qa" | run 'claim a2; echo "rc=$?"')
  { grep -q '^rc=1$' <<<"$out" && [ ! -s "$BDLOG" ]; } || { fail "mismatched role taken: $out"; return; }
  out=$(issue a3 qa "needs-team-lead,role:qa" | AS_ROLE=qa run 'claim a3; echo "rc=$?"')
  { grep -q '^rc=1$' <<<"$out" && [ ! -s "$BDLOG" ]; } || { fail "non-team-lead role used takeover: $out"; return; }
  pass "takeover: live other agents, mismatched role, and non-team-lead roles are left alone"
}

test_failed_claim_logged_and_skipped() {
  local out
  out=$( { issue f1 qa "needs-team-lead,role:qa"; issue f2 po "needs-team-lead,role:po"; } \
    | BD_FAIL=1 run 'claim f1; echo "rc=$?"; echo "err=$(cat "$CLAIM_ERR")"; handle_claim_failure f1;
      echo "next=$(next_issue)"; CLAIM_SKIP_SECS=0; echo "after=$(next_issue)"')
  grep -q '^rc=1$' <<<"$out" && grep -q '^err=boom' <<<"$out" || { fail "failed claim: rc/err wrong: $out"; return; }
  grep -q '^next=f2$' <<<"$out" || { fail "failed claim: next_issue did not skip f1: $out"; return; }
  grep -q '^after=f1$' <<<"$out" || { fail "failed claim: f1 not retried after skip expiry: $out"; return; }
  grep -q 'could not claim f1: boom' "$TMP/loop.log" || { fail "failed claim: reason not logged"; return; }
  pass "failed claim: reason logged, issue skipped, then retried after the skip window"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "--- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
