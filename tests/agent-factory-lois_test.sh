#!/usr/bin/env bash
# Regression for agent-factory-lois: next_issue() must not read dependencies[].status (bd list
# does not emit it); open blockers come from `bd blocked --json`, failing closed when it errors.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_ROOT"
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
  list) cat "$FIXTURE";;
  ready) echo '[]';;
  blocked) [ -z "${FAIL_BLOCKED:-}" ] || { echo "boom" >&2; exit 1; }; echo "${BLOCKED:-[]}";;
esac
exit 0
STUB
chmod +x "$TMP/bin/bd"
# real-shaped issue: one blocks-dependency, no status field on it
fixture() { jq -n --arg id "$1" '[{id:$id,status:"in_progress",assignee:"team-lead",labels:["role:qa"],
  dependencies:[{issue_id:$id,depends_on_id:"x-1",type:"blocks"}]}]'; }
run() { local w="$TMP/l.$RANDOM"; mkdir -p "$w"; fixture k1 > "$w/f.json"
  FIXTURE="$w/f.json" PATH="$TMP/bin:$PATH" AGENT_ID=qa ROLE=qa LOGDIR="$w" bash -c 'source "$1"; next_issue' _ "$FNS"; }

got=$(run); [ "$got" = k1 ] && pass "closed-blocker dependency (not in bd blocked) is selected" || fail "expected k1, got '$got'"
got=$(BLOCKED='[{"id":"k1"}]' run); [ -z "$got" ] && pass "issue listed by bd blocked is skipped" || fail "blocked k1 selected: '$got'"
got=$(FAIL_BLOCKED=1 run); [ -z "$got" ] && pass "bd blocked failure fails closed" || fail "selected on bd blocked failure: '$got'"
echo "$PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
