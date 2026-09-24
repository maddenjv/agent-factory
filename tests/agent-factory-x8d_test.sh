#!/usr/bin/env bash
# Unit tests for agent-factory-x8d (engineer): bin/restart-story.sh against a stubbed `bd`, plus wiring greps.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$REPO_ROOT"
PASS=0; FAIL=0
ok() { if eval "$2"; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"
cat > "$T/bin/bd" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1" in
  show) cat "$STUB_SHOW" ;;
  list) cat "$STUB_LIST" ;;
  create) n=$(cat "$STUB_LOG" | grep -c '^create'); echo "{\"id\":\"new-$n\"}" ;;
esac
STUB
chmod +x "$T/bin/bd"
export PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_SHOW="$T/show" STUB_LIST="$T/list"

echo '[{"id":"rw","labels":["stage:rework","merge-conflict","story:s1"],"notes":"too diverged"}]' > "$T/show"
echo '[{"id":"im","status":"closed","labels":["stage:implement","story:s1"]},
{"id":"ve","status":"open","labels":["stage:verify","story:s1"]},
{"id":"rv","status":"open","title":"s1: T [review]","labels":["stage:review","story:s1"]},
{"id":"rw","status":"in_progress","labels":["stage:rework","merge-conflict","story:s1"]},
{"id":"de","status":"closed","labels":["stage:design","story:s1"]}]' > "$T/list"

: > "$T/log"; out=$(bin/restart-story.sh rw attempt-cap 2>&1); rc=$?
ok "happy path exits 0" '[ $rc -eq 0 ]'
ok "creates 3 restarted issues, none design/tests" '[ "$(grep -c "^create.*restarted" $T/log)" = 3 ] && ! grep -q "^create.*stage:\(design\|tests\)" $T/log'
ok "closes open old issues only (ve rv rw)" '[ "$(grep -c "^close" $T/log)" = 3 ] && ! grep -q "^close im" $T/log && grep -q "^close rw.*restarted" $T/log'
ok "implement description mentions origin/main and force-with-lease" 'grep -q "origin/main" $T/log && grep -q -- "--force-with-lease" $T/log'
ok "comment names reason" 'grep -q "^comment new-1 .*attempt-cap" $T/log'

echo '[{"id":"x","status":"open","labels":["stage:review","restarted","story:s1"]},
{"id":"rw","status":"open","labels":["stage:rework","merge-conflict","story:s1"]}]' > "$T/list"
: > "$T/log"; bin/restart-story.sh rw unresolvable >/dev/null 2>&1
ok "second failure: nothing created, review+rework needs-human" '! grep -q "^create\|^close" $T/log && grep -q "^label add x needs-human" $T/log && grep -q "^label add rw needs-human" $T/log'

echo '[{"id":"rw","labels":["stage:rework","story:s1"]}]' > "$T/show"
: > "$T/log"; bin/restart-story.sh rw unresolvable >/dev/null 2>&1; rc=$?
ok "non-conflict rework: no-op" '[ $rc -eq 0 ] && ! grep -q "^create\|^close" $T/log'

ok "agent-loop wiring" 'grep -q "restart_story \"\$id\" unresolvable" bin/agent-loop.sh && grep -q "restart_story \"\$id\" attempt-cap" bin/agent-loop.sh'
ok "prompts mention conflict-unresolvable" 'grep -q conflict-unresolvable agents/engineer.md && grep -q conflict-unresolvable agents/qa.md && grep -q restarted agents/engineer.md'
echo "$PASS passed, $FAIL failed"; [ $FAIL -eq 0 ]
