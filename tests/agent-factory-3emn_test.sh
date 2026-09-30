#!/usr/bin/env bash
# Acceptance tests for agent-factory-3emn: "Tolerate the bd v2.0 --json envelope".
# One or more functions per acceptance criterion in docs/stories/agent-factory-3emn.md (test_acN_...).
# Written from the story ONLY (not docs/design/agent-factory-3emn.md).
#
# Method: every script is run against a stub `bd` backed by fixture JSON that emits one of three
# shapes, chosen per run:
#   bare   - today's output (arrays; show returns a 1-element array, create returns an object)
#   env    - BD_JSON_ENVELOPE=1: list/ready/show wrapped as {"data": [...]}, create as {"data": {...}}
#   envobj - BD_JSON_ENVELOPE=1: show/create wrapped as {"data": {...}} / {"data": [{...}]} (the
#            other plausible envelope payload shape; scripts must not depend on which one bd uses)
# Each scenario is asserted (a) against a concrete expectation in bare mode (AC1: unchanged) and
# (b) identical to bare in env / envobj mode (AC2-AC6). Failure paths cover AC7.
#
# Run directly: bash tests/agent-factory-3emn_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stubs"
MODES="bare env envobj"

# ---- stub bd -------------------------------------------------------------------------------
# State under $W: issues.json (bd list), ready.json (bd ready), fail (if present: every bd call
# fails), db/<id> (smoke-test's tiny stateful store). BDMODE selects the output shape.
cat > "$T/stubs/bd" <<'STUB'
#!/usr/bin/env bash
echo "bd $*" >> "$W/bdlog"
json=0; label=""; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = "--json" ] && json=1
  [ "${args[$i]}" = "--label" ] && label="${args[$((i + 1))]}"
done
if [ -f "$W/fail" ]; then
  [ "$BDMODE" != bare ] && echo '{"error":"boom","code":1}'
  echo "bd: boom" >&2
  exit 1
fi
emit() {  # emit KIND: stdin is the bare-shape JSON
  if [ "$json" = 0 ]; then cat; return; fi
  case "$BDMODE:$1" in
    bare:*) cat ;;
    env:list|env:show|envobj:list) jq -c '{data: .}' ;;
    env:create) jq -c '{data: (if type=="array" then .[0] else . end)}' ;;
    envobj:show) jq -c '{data: (if type=="array" then .[0] else . end)}' ;;
    envobj:create) jq -c '{data: [(if type=="array" then .[0] else . end)]}' ;;
  esac
}
filter() { if [ -n "$label" ]; then jq -c --arg l "$label" '[.[] | select((.labels // []) | index($l))]'; else cat; fi; }
case "$1" in
  list)  filter < "$W/issues.json" | emit list ;;
  ready) filter < "$W/ready.json" | emit list ;;
  show)
    if [ -d "$W/db" ]; then
      [ -f "$W/db/$2" ] || exit 1
      jq -c -n --arg id "$2" --arg s "$(cat "$W/db/$2")" '[{id:$id,status:$s}]' | emit show
    else
      jq -c --arg id "$2" '[.[] | select(.id == $id)]' "$W/issues.json" | emit show
    fi ;;
  create)
    n=$(grep -c '^bd create' "$W/bdlog")
    id="new-$n"
    [ -d "$W/db" ] && echo open > "$W/db/$id"
    jq -c -n --arg id "$id" '{id:$id}' | emit create ;;
  update)
    if [ -d "$W/db" ] && [[ " $* " == *" --claim "* ]]; then echo in_progress > "$W/db/$2"; fi ;;
  close) [ -d "$W/db" ] && echo closed > "$W/db/$2" ;;
esac
exit 0
STUB
chmod +x "$T/stubs/bd"

cat > "$T/stubs/claude" <<'STUB'
#!/usr/bin/env bash
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0}'
touch "$W/data/control/STOP"
exit 0
STUB
chmod +x "$T/stubs/claude"

ORIGIN="$T/origin"
git init -q -b main "$ORIGIN" && git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

# new_world MODE -> sets W (fresh state dir) and exports BDMODE / BD_JSON_ENVELOPE for MODE.
new_world() {
  W="$T/w.$RANDOM$RANDOM"; mkdir -p "$W/data/control" "$W/home"; : > "$W/bdlog"
  BDMODE="$1"
  if [ "$1" = bare ]; then unset BD_JSON_ENVELOPE; else BD_JSON_ENVELOPE=1; export BD_JSON_ENVELOPE; fi
  export W BDMODE
}
norm() { sed "s#$W#<W>#g; s#[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]#<DATE>#g; s#[0-9T:-]*Z#<TS>#g"; }

# same_as_bare LABEL FILE_PREFIX: asserts $T/<prefix>.env and .envobj equal .bare
same_as_bare() {
  local label="$1" p="$2" m
  for m in env envobj; do
    if diff -u "$T/$p.bare" "$T/$p.$m" > "$T/$p.$m.diff"; then
      pass "$label: BD_JSON_ENVELOPE=1 ($m shape) result identical to unset"
    else
      fail "$label: result differs under envelope ($m shape):
$(head -12 "$T/$p.$m.diff")"
    fi
  done
}

# ============================================================
# AC2 - agent-loop picks the same work under the envelope (qa via `bd ready`, team-lead via
# `bd list`); covers show_json / is_ready / claim-time role and assignee checks too.
# ============================================================
cat > "$T/issues.json" <<'JSON'
[
 {"id":"q-flag","status":"open","assignee":"","labels":["role:qa","stage:verify","needs-human"]},
 {"id":"q-other","status":"open","assignee":"someone-else","labels":["role:qa","stage:tests"]},
 {"id":"q-pick","status":"open","assignee":"","labels":["role:qa","stage:tests","story:s1"]},
 {"id":"tl-unrouted","status":"open","assignee":"","type":"feature","labels":[]},
 {"id":"e-1","status":"open","assignee":"","labels":["role:engineer","stage:implement"]}
]
JSON
cp "$T/issues.json" "$T/ready.json"

run_loop() {  # run_loop MODE ROLE -> $T/loop.<role>.<mode>
  new_world "$1"; cp "$T/issues.json" "$W/issues.json"; cp "$T/ready.json" "$W/ready.json"
  ( export HOME="$W/home" CONTAINER_HOME="$W/home"
    PATH="$T/stubs:$PATH" ROLE="$2" KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 IDLE_SLEEP=1 \
      timeout 10 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 )
  { echo "rc=$?"; norm < "$W/bdlog"; } > "$T/loop.$2.$1"
  cp "$W/bdlog" "$T/loop.$2.$1.raw"
}

test_ac1_ac2_agent_loop_picks_same_issue_for_build_role_and_team_lead() {
  local role want m
  for role in qa team-lead; do
    for m in $MODES; do run_loop "$m" "$role"; done
    want=q-pick; [ "$role" = team-lead ] && want=tl-unrouted
    if grep -qE "^bd update $want --claim" "$T/loop.$role.bare.raw"; then
      pass "ac1: $role loop (bare output) claims $want as today"
    else
      fail "ac1: $role loop (bare output) did not claim $want"
    fi
    for m in env envobj; do
      if grep -qE "^bd update $want --claim" "$T/loop.$role.$m.raw"; then
        pass "ac2: $role loop claims $want under BD_JSON_ENVELOPE=1 ($m shape)"
      else
        fail "ac2: $role loop under envelope ($m shape) did not claim $want (first bd calls: $(head -3 "$T/loop.$role.$m.raw" | tr "\n" ";"))"
      fi
    done
    same_as_bare "ac2: $role loop bd call sequence" "loop.$role"
  done
}

# ============================================================
# AC3 - single-issue reads (status/assignee/labels) resolve the same. Exercised through
# restart-story.sh (labels via bd show) and the agent-loop claim path above; here directly:
# a merge-conflict rework is recognised from labels read out of `bd show --json`.
# ============================================================
cat > "$T/rs.list.json" <<'JSON'
[
 {"id":"im","status":"open","labels":["stage:implement","story:s1"]},
 {"id":"ve","status":"open","labels":["stage:verify","story:s1"]},
 {"id":"rv","status":"open","title":"s1: T [review]","labels":["stage:review","story:s1"]},
 {"id":"rw","status":"in_progress","labels":["stage:rework","merge-conflict","story:s1"],"notes":"too diverged"}
]
JSON

run_restart() {  # run_restart MODE OUTPREFIX [fail]
  new_world "$1"; cp "$T/rs.list.json" "$W/issues.json"; cp "$T/rs.list.json" "$W/ready.json"
  [ "${3:-}" = fail ] && touch "$W/fail"
  local out rc
  out=$(PATH="$T/stubs:$PATH" bash "$KIT_DIR/bin/restart-story.sh" rw attempt-cap 2>&1); rc=$?
  { echo "rc=$rc"; echo "$out"; norm < "$W/bdlog"; } > "$T/$2.$1"
  cp "$W/bdlog" "$T/$2.$1.raw"
}

test_ac3_ac5_restart_story_reads_issue_fields_and_ids() {
  local m
  for m in $MODES; do run_restart "$m" restart; done
  if grep -q '^bd create' "$T/restart.bare.raw" && grep -q '^bd close im' "$T/restart.bare.raw" \
     && grep -q 'implement=new-1' "$T/restart.bare"; then
    pass "ac1/ac5: restart-story.sh (bare output) recognises the conflict rework, creates 3 issues, closes the old ones"
  else
    fail "ac1/ac5: restart-story.sh baseline (bare) wrong: $(cat "$T/restart.bare")"
  fi
  same_as_bare "ac3/ac5: restart-story.sh (labels from show, ids from create/list)" restart
}

# ============================================================
# AC4 - board.sh renders identically. Fixture has in-progress, ready, needs-human and a
# blocked-by-needs-human issue, plus a recent alert about a still-flagged issue.
# ============================================================
cat > "$T/board.json" <<'JSON'
[
 {"id":"ip-1","title":"working on it","status":"in_progress","assignee":"qa","labels":["role:qa"]},
 {"id":"rd-1","title":"ready thing","status":"open","labels":["role:engineer","stage:implement"]},
 {"id":"nh-1","title":"needs a human","status":"open","labels":["needs-human","role:po"]},
 {"id":"bl-1","title":"blocked thing","status":"open","labels":["role:qa"],
  "dependencies":[{"type":"blocks","depends_on_id":"nh-1"}]},
 {"id":"cl-1","title":"done","status":"closed","labels":[]}
]
JSON
jq -c '[.[] | select(.id=="rd-1")]' "$T/board.json" > "$T/board.ready.json"

run_board() {  # run_board MODE [fail]
  new_world "$1"; cp "$T/board.json" "$W/issues.json"; cp "$T/board.ready.json" "$W/ready.json"
  [ "${2:-}" = fail ] && touch "$W/fail"
  printf '%s [qa] nh-1 flagged needs-human\n' "$(date -u +%FT%TZ)" > "$W/data/control/alerts.log"
  local out
  out=$(cd "$W" && PATH="$T/stubs:$PATH" TERM=dumb DATA_DIR="$W/data" timeout 20 bash -c '
      source "$1/bin/board.sh"; render' _ "$KIT_DIR" 2>&1 | grep -v '^== ')
  printf '%s\n' "$out" > "$T/board${2:+.$2}.$1"
}

test_ac1_ac4_board_render_identical() {
  local m
  for m in $MODES; do run_board "$m"; done
  if grep -q 'ip-1' "$T/board.bare" && grep -q 'rd-1' "$T/board.bare" && grep -q 'nh-1' "$T/board.bare" \
     && grep -q 'bl-1  waiting on nh-1' "$T/board.bare" && ! grep -q 'cl-1' "$T/board.bare"; then
    pass "ac1/ac4: board.sh (bare output) shows in-progress, ready, needs-human and blocked sections as today"
  else
    fail "ac1/ac4: board.sh baseline (bare) unexpected: $(cat "$T/board.bare")"
  fi
  if grep -q 'flagged needs-human' "$T/board.bare"; then
    pass "ac1/ac4: board.sh (bare) keeps the still-flagged alert (needs-human read via bd show)"
  else
    fail "ac1/ac4: board.sh (bare) lost the still-flagged needs-human alert: $(cat "$T/board.bare")"
  fi
  same_as_bare "ac4: board.sh render" board
}

# ============================================================
# AC5 - new-story.sh / feature.sh read the created issue id.
# ============================================================
run_new_story() {  # run_new_story MODE
  new_world "$1"; : > "$W/issues.json"; echo '[]' > "$W/issues.json"; echo '[]' > "$W/ready.json"
  local out rc
  out=$(PATH="$T/stubs:$PATH" bash "$KIT_DIR/bin/new-story.sh" s9 "A title" 2>&1); rc=$?
  { echo "rc=$rc"; echo "$out"; norm < "$W/bdlog"; } > "$T/newstory.$1"
  cp "$W/bdlog" "$T/newstory.$1.raw"
}
run_feature() {  # run_feature MODE [fail]
  new_world "$1"; echo '[]' > "$W/issues.json"; echo '[]' > "$W/ready.json"
  [ "${2:-}" = fail ] && touch "$W/fail"
  local out rc
  out=$(PATH="$T/stubs:$PATH" bash "$KIT_DIR/bin/feature.sh" "A feature" "desc" 2>&1); rc=$?
  { echo "rc=$rc"; echo "$out"; norm < "$W/bdlog"; } > "$T/feature${2:+.$2}.$1"
}

test_ac1_ac5_new_story_and_feature_read_created_ids() {
  local m
  for m in $MODES; do run_new_story "$m"; run_feature "$m"; done
  if grep -q 'design=new-1 tests=new-2 implement=new-3 verify=new-4 review=new-5' "$T/newstory.bare" \
     && grep -q '^bd dep add new-4 new-3' "$T/newstory.bare.raw"; then
    pass "ac1/ac5: new-story.sh (bare) wires the chain from created ids"
  else
    fail "ac1/ac5: new-story.sh baseline (bare) wrong: $(cat "$T/newstory.bare")"
  fi
  if [ "$(head -2 "$T/feature.bare")" = "$(printf 'rc=0\nnew-1')" ]; then
    pass "ac1/ac5: feature.sh (bare) prints the created id and nothing else"
  else
    fail "ac1/ac5: feature.sh baseline (bare) wrong: $(cat "$T/feature.bare")"
  fi
  same_as_bare "ac5: new-story.sh" newstory
  same_as_bare "ac5: feature.sh" feature
}

# ============================================================
# AC6 - smoke-test.sh passes (stateful stub store: create/claim/close/show).
# ============================================================
run_smoke() {  # run_smoke MODE
  new_world "$1"; mkdir -p "$W/db"
  local out rc
  out=$(PATH="$T/stubs:$PATH" timeout 60 bash "$KIT_DIR/bin/smoke-test.sh" 3 2>&1); rc=$?
  { echo "rc=$rc"; echo "$out"; } > "$T/smoke.$1"
}

test_ac1_ac6_smoke_test_passes() {
  local m
  for m in $MODES; do
    run_smoke "$m"
    if head -1 "$T/smoke.$m" | grep -q '^rc=0$' && grep -q 'PASS: all 3 closes persisted' "$T/smoke.$m"; then
      pass "ac6: smoke-test.sh passes (${m} output)"
    else
      fail "ac6: smoke-test.sh did not pass with ${m} output: $(cat "$T/smoke.$m")"
    fi
  done
}

# ============================================================
# AC7 - failing bd / empty results take the same path under either format.
# ============================================================
test_ac7_failing_bd_takes_same_path_in_all_formats() {
  local m
  for m in $MODES; do run_restart "$m" restartfail fail; run_feature "$m" fail; run_board "$m" fail; done
  # Baselines: what today does. restart-story: failing bd show aborts (set -e) with no writes.
  if ! head -1 "$T/restartfail.bare" | grep -q '^rc=0$' \
     && ! grep -qE '^bd (create|close|label)' "$T/restartfail.bare.raw"; then
    pass "ac7: restart-story.sh (bare) aborts non-zero on a failing bd, no writes"
  else
    fail "ac7: restart-story.sh failing-bd baseline (bare) unexpected: $(cat "$T/restartfail.bare")"
  fi
  if ! head -1 "$T/feature.fail.bare" | grep -q '^rc=0$'; then
    pass "ac7: feature.sh (bare) exits non-zero when bd create fails"
  else
    fail "ac7: feature.sh failing-bd baseline (bare) exited 0: $(cat "$T/feature.fail.bare")"
  fi
  same_as_bare "ac7: restart-story.sh with failing bd" restartfail
  same_as_bare "ac7: feature.sh with failing bd" feature.fail
  same_as_bare "ac7: board.sh with failing bd (no error envelope rendered as issues)" board.fail
  if grep -qE 'boom|error' "$T/board.fail.env" "$T/board.fail.envobj"; then
    fail "ac7: board.sh rendered the error envelope as data: $(cat "$T/board.fail.env")"
  else
    pass "ac7: board.sh does not render an error envelope as an issue row"
  fi
}

test_ac7_empty_results_take_same_path_in_all_formats() {
  local m
  for m in $MODES; do
    new_world "$m"; echo '[]' > "$W/issues.json"; echo '[]' > "$W/ready.json"
    ( export HOME="$W/home" CONTAINER_HOME="$W/home"
      PATH="$T/stubs:$PATH" ROLE=qa KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
        PREFLIGHT=0 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 IDLE_SLEEP=1 \
        timeout 4 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 )
    { grep -E '^bd (update|label|comment|close)' "$W/bdlog"; echo "claims=$(grep -c -- '--claim' "$W/bdlog")"; } | norm > "$T/empty.$m"
    cp "$W/bdlog" "$T/empty.$m.raw"
  done
  if ! grep -q -- '--claim' "$T/empty.bare.raw"; then
    pass "ac7: agent-loop with no ready work claims nothing (bare)"
  else
    fail "ac7: agent-loop claimed something with an empty tracker (bare): $(cat "$T/empty.bare.raw")"
  fi
  same_as_bare "ac7: agent-loop with empty list/ready (envelope {\"data\":[]} is empty, not one item)" empty
  # is_ready must be false for an empty envelope (an envelope object is not an issue)
  for m in env envobj; do
    if grep -q -- '--claim' "$T/empty.$m.raw"; then
      fail "ac7: agent-loop under envelope claimed an 'issue' from an empty result"
    else
      pass "ac7: agent-loop under envelope ($m) does not treat an empty envelope as data"
    fi
  done
}

# ============================================================
# AC1 (scope) - the scripts must not opt in themselves; that is out of scope for the story.
# ============================================================
test_ac1_scripts_do_not_set_the_envelope_flag() {
  local hits
  hits=$(grep -rnE 'BD_JSON_ENVELOPE *=|export +BD_JSON_ENVELOPE' bin docker-compose.yml Dockerfile .env.example 2>/dev/null)
  [ -z "$hits" ] && pass "ac1: nothing in bin/, docker-compose.yml, Dockerfile sets BD_JSON_ENVELOPE" \
    || fail "ac1: something sets BD_JSON_ENVELOPE globally (out of scope): $hits"
}

# ============================================================
# AC8 - role docs' --json examples do not assume the bare array shape.
# ============================================================
test_ac8_role_docs_do_not_assume_bare_array() {
  local f bad=""
  for f in agents/team-lead.md agents/architect.md; do
    grep -qiE 'envelope|BD_JSON_ENVELOPE|\.data\b' "$f" \
      || bad="$bad
$f documents bd --json usage but never mentions the v2.0 envelope / .data"
  done
  # No doc line may pair --json with a bare-array-only jq idiom.
  local l
  l=$(grep -nE -- '--json.*jq[^|]*\x27?\.\[' agents/*.md docs/*.md README.md 2>/dev/null \
      | grep -vE '\.data|envelope' || true)
  [ -n "$l" ] && bad="$bad
bare-array jq idiom next to --json: $l"
  [ -z "$bad" ] && pass "ac8: team-lead.md and architect.md acknowledge the envelope; no bare-array-only jq examples" \
    || fail "ac8:$bad"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
