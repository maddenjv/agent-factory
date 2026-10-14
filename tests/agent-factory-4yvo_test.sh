#!/usr/bin/env bash
# Acceptance tests for agent-factory-4yvo: catch merge conflicts with main before a story reaches
# review. One function per acceptance criterion in docs/stories/agent-factory-4yvo.md (test_acN_...).
#
# Written from the story's acceptance criteria only - not from docs/design/agent-factory-4yvo.md.
# The story leaves "how and where detection runs" to the architect, so these tests are black-box
# about the mechanism: they run the real bin/agent-loop.sh with ROLE=reviewer against
#   - a real bare git origin holding main, story/<id> and fix/<id> branches (clean, behind-but-clean
#     and genuinely conflicting ones),
#   - a stateful stub `bd` (issues, labels, blocking deps, create/close/update) kept in a JSON file,
#   - a stub `claude` that just records it was started.
# and observe only outcomes: did the reviewer get to claim the review issue, which `bd create` calls
# were made (labels / description), and did anything on origin or in the clones change.
#
# The stub `bd ready` hides issues that have an open *blocking* dependency (a `bd dep add A B` without
# `--type discovered-from`), as the real one does, so "the reviewer does not get the review issue until
# the conflict has been resolved" is observable whichever way the implementation holds the issue back
# (dependency, or not exposing it). Hold-back via a label the reviewer's queue doesn't know is not
# observable here and would need these tests adjusting.
#
# Run directly: bash tests/agent-factory-4yvo_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"
GIT="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"

# ---------------- stub bd (state: $W/issues.json) ----------------
cat > "$TMP/stubs/bd" <<'STUB'
#!/usr/bin/env bash
echo "bd $*" >> "$W/bdlog"
S="$W/issues.json"
upd() { local t; t=$(mktemp); jq -c "$@" "$S" > "$t" && mv "$t" "$S"; }
lblarg() { local a=("$@"); for ((i=0;i<${#a[@]};i++)); do [ "${a[$i]}" = "--label" ] && { echo "${a[$((i+1))]}"; return; }; done; }
case "$1" in
  ready)
    jq -c --arg l "$(lblarg "$@")" '. as $all | [.[] | select(.status == "open")
        | select(($l == "") or ((.labels // []) | index($l)))
        | select((.blockers // []) | all(. as $b | ($all | map(select(.id == $b and .status != "closed")) | length) == 0))]' "$S" ;;
  list)
    jq -c --arg l "$(lblarg "$@")" '[.[] | select(($l == "") or ((.labels // []) | index($l)))]' "$S" ;;
  blocked)
    jq -c '. as $all | [.[] | select(.status != "closed")
        | select((.blockers // []) | any(. as $b | ($all | map(select(.id == $b and .status != "closed")) | length) > 0))]' "$S" ;;
  show) jq -c --arg id "$2" '[.[] | select(.id == $id)]' "$S" ;;
  create)
    shift; title=""; labels=""; desc=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -l|--labels|--label) labels="$2"; shift 2 ;;
        -d|--description) desc="$2"; shift 2 ;;
        -t|-p|--type|--priority|--parent|--deps|--assignee) shift 2 ;;
        -*) shift ;;
        *) [ -z "$title" ] && title="$1"; shift ;;
      esac
    done
    n=$(jq 'length' "$S"); id="new-$((n + 1))"
    upd --arg id "$id" --arg t "$title" --arg l "$labels" --arg d "$desc" \
      '. + [{id:$id,title:$t,status:"open",assignee:"",labels:($l|split(",")|map(select(length>0))),description:$d,blockers:[]}]'
    echo "{\"id\":\"$id\"}" ;;
  dep)
    if [ "$2" = add ]; then
      case "$*" in *discovered-from*|*related*|*parent-child*) ;; *) upd --arg a "$3" --arg b "$4" 'map(if .id==$a then .blockers=((.blockers//[])+[$b]) else . end)' ;; esac
    fi ;;
  update)
    id="$2"; shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --claim) upd --arg id "$id" 'map(if .id==$id then .status="in_progress" else . end)'; shift ;;
        --assignee) upd --arg id "$id" --arg v "$2" 'map(if .id==$id then .assignee=$v else . end)'; shift 2 ;;
        --status) upd --arg id "$id" --arg v "$2" 'map(if .id==$id then .status=$v else . end)'; shift 2 ;;
        --append-notes|--notes) upd --arg id "$id" --arg v "$2" 'map(if .id==$id then .notes=((.notes//"")+$v) else . end)'; shift 2 ;;
        *) shift ;;
      esac
    done ;;
  label)
    if [ "$2" = add ]; then upd --arg id "$3" --arg l "$4" 'map(if .id==$id then .labels=((.labels//[])+[$l]) else . end)'; fi ;;
  close) upd --arg id "$2" 'map(if .id==$id then .status="closed" else . end)' ;;
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

# ---------------- git fixture ----------------
# origin (bare) with main = {src/app.sh, tests/app_test.sh, README}. Branches:
#   story/s-code   edits src/app.sh        ; main later edits same line  -> conflict (non-test)
#   story/s-test   edits tests/app_test.sh ; main later edits same line  -> conflict (test only)
#   story/s-mixed  edits both              ; main edits both             -> conflict (mixed)
#   story/s-clean  adds new.txt            ; main later edits README     -> behind but merges cleanly
#   fix/fx-code, fix/fx-clean              : storyless equivalents
ORIGIN="$TMP/origin.git"
SEED="$TMP/seed"
$GIT init -q --bare "$ORIGIN"
$GIT clone -q "$ORIGIN" "$SEED" 2>/dev/null
(
  cd "$SEED" || exit 1
  mkdir -p src tests
  printf 'line1\nvalue=base\nline3\n' > src/app.sh
  printf 't1\nexpect=base\nt3\n' > tests/app_test.sh
  printf 'readme base\n' > README
  $GIT add -A; $GIT commit -q -m "init"; $GIT push -q origin main
  mk() { # mk BRANCH FILE SEDSCRIPT MSG  (branch off the init commit)
    $GIT checkout -q -b "$1" main; sed -i "$3" "$2"; $GIT commit -q -am "$4"; $GIT push -q origin "$1"; $GIT checkout -q main
  }
  mk story/s-code  src/app.sh        's/value=base/value=story/'   "story-side-commit-code"
  mk story/s-test  tests/app_test.sh 's/expect=base/expect=story/' "story-side-commit-test"
  mk fix/fx-code   src/app.sh        's/value=base/value=fixside/' "fix-side-commit-code"
  $GIT checkout -q -b story/s-mixed main
  sed -i 's/value=base/value=story/' src/app.sh; sed -i 's/expect=base/expect=story/' tests/app_test.sh
  $GIT commit -q -am "story-side-commit-mixed"; $GIT push -q origin story/s-mixed; $GIT checkout -q main
  $GIT checkout -q -b story/s-clean main; echo new > new.txt; $GIT add new.txt; $GIT commit -q -m "story-side-commit-clean"
  $GIT push -q origin story/s-clean; $GIT checkout -q main
  $GIT checkout -q -b fix/fx-clean main; echo newfix > newfix.txt; $GIT add newfix.txt; $GIT commit -q -m "fix-side-commit-clean"
  $GIT push -q origin fix/fx-clean; $GIT checkout -q main
  # main moves on: conflicting edits to the same lines + an unrelated README change
  sed -i 's/value=base/value=main/' src/app.sh; sed -i 's/expect=base/expect=main/' tests/app_test.sh
  echo "readme main change" >> README
  $GIT commit -q -am "main-side-commit"; $GIT push -q origin main
) >/dev/null 2>&1
heads() { git --git-dir="$ORIGIN" for-each-ref --format='%(refname) %(objectname)'; }

# ---------------- run harness ----------------
new_world() {
  W="$TMP/w.$RANDOM$RANDOM"; mkdir -p "$W/data/control" "$W/home"; : > "$W/bdlog"; : > "$W/claude_runs"
  echo "$1" > "$W/issues.json"
}
# run_loop SECS: one reviewer loop pass in $W; a STOP file is dropped after SECS so an idle run ends.
run_loop() {
  local secs="${1:-7}"
  rm -f "$W/data/control/STOP"; : > "$W/claude_runs"
  ( sleep "$secs"; touch "$W/data/control/STOP" ) & local sp=$!
  RC=0
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home"
    PATH="$TMP/stubs:$PATH" ROLE=reviewer KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 IDLE_SLEEP=1 \
      timeout 40 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
  kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
}
review_issue() { # review_issue ID TITLE LABELS_JSON_ARRAY
  jq -nc --arg id "$1" --arg t "$2" --argjson l "$3" '{id:$id,title:$t,status:"open",assignee:"",labels:$l,blockers:[]}'
}
claimed()  { grep -qE "^bd update $1 --claim" "$W/bdlog"; }
# conflict-rework issues the check filed (created during the run), as JSON lines
rework_issues() { jq -c '.[] | select(.id | startswith("new-")) | select((.labels // []) | index("merge-conflict"))' "$W/issues.json"; }
rework_count() { rework_issues | wc -l | tr -d ' '; }
story_labels() { echo "[\"role:reviewer\",\"stage:review\",\"story:$1\"]"; }
world_for_story() { new_world "[$(review_issue "rv-$1" "Review $1" "$(story_labels "$1")")]"; }

# One run per scenario, cached so each criterion's tests share it.
declare -A DONE
scenario() { # scenario NAME (story id suffix, fx-* for fix branches, nobranch for a missing branch)
  local n=$1; [ -n "${DONE[$n]:-}" ] && { W="${DONE[$n]}"; return; }
  case "$n" in
    fx-*) new_world "[$(review_issue "rv-$n" "Merge fix/$n to main: tweak" '["role:reviewer","stage:review"]')]" ;;
    nobranch) new_world "[$(review_issue rv-nb "Review of a story whose branch is missing" "$(story_labels nobranch)")]" ;;
    *) world_for_story "$n" ;;
  esac
  heads > "$W/heads.before"
  run_loop 7
  heads > "$W/heads.after"
  DONE[$n]="$W"
}
dump() { echo "bdlog:$(tr '\n' ';' < "$W/bdlog" | head -c 1200) out:$(tail -n 5 "$W/out" | tr '\n' ';')"; }

# ============================================================
# AC1 - conflicting story: reviewer does not get the review issue; a stage:rework + merge-conflict
#       issue labelled story:<id> is filed.
# ============================================================
test_ac1_conflicting_story_review_not_claimed() {
  scenario s-code
  if claimed rv-s-code || [ -s "$W/claude_runs" ]; then fail "ac1: reviewer got the review issue of a story that conflicts with origin/main. $(dump)"; return; fi
  pass "ac1: review issue of a conflicting story is not handed to the reviewer"
}
test_ac1_conflicting_story_files_merge_conflict_rework() {
  scenario s-code
  local r; r=$(rework_issues | head -1)
  [ -n "$r" ] || { fail "ac1: no merge-conflict rework issue was filed. $(dump)"; return; }
  echo "$r" | jq -e '(.labels|index("stage:rework")) and (.labels|index("story:s-code")) and (.labels|index("merge-conflict"))' >/dev/null \
    || { fail "ac1: rework issue lacks stage:rework / story:s-code / merge-conflict labels: $r"; return; }
  pass "ac1: stage:rework, merge-conflict, story:<id> issue filed"
}

# ============================================================
# AC2 - routing (qa iff every conflicting file is a test file, else engineer) and description.
# ============================================================
test_ac2_code_conflict_routed_to_engineer() {
  scenario s-code
  local r; r=$(rework_issues | head -1)
  [ -n "$r" ] && echo "$r" | jq -e '(.labels | index("role:engineer")) and ((.labels | index("role:qa")) | not)' >/dev/null 2>&1 \
    && pass "ac2: non-test conflict -> role:engineer" \
    || fail "ac2: non-test conflict not routed to role:engineer: ${r:-<no rework issue filed>}"
}
test_ac2_test_only_conflict_routed_to_qa() {
  scenario s-test
  local r; r=$(rework_issues | head -1)
  [ -n "$r" ] && echo "$r" | jq -e '(.labels | index("role:qa")) and ((.labels | index("role:engineer")) | not)' >/dev/null 2>&1 \
    && pass "ac2: test-only conflict -> role:qa" \
    || fail "ac2: test-only conflict not routed to role:qa: ${r:-<no rework issue filed>}"
}
test_ac2_mixed_conflict_routed_to_engineer() {
  scenario s-mixed
  local r; r=$(rework_issues | head -1)
  [ -n "$r" ] && echo "$r" | jq -e '(.labels | index("role:engineer")) and ((.labels | index("role:qa")) | not)' >/dev/null 2>&1 \
    && pass "ac2: mixed conflict -> role:engineer" \
    || fail "ac2: mixed conflict not routed to role:engineer: ${r:-<no rework issue filed>}"
}
test_ac2_description_names_files_and_commits_on_each_side() {
  scenario s-code
  local d; d=$(rework_issues | head -1 | jq -r '.description // ""')
  [ -n "$d" ] || { fail "ac2: no rework issue/description to inspect"; return; }
  echo "$d" | grep -q 'src/app.sh' || { fail "ac2: description does not name the conflicting file src/app.sh: $d"; return; }
  local story_sha main_sha
  story_sha=$(git --git-dir="$ORIGIN" rev-parse --short=7 refs/heads/story/s-code)
  main_sha=$(git --git-dir="$ORIGIN" rev-parse --short=7 refs/heads/main)
  { echo "$d" | grep -q 'story-side-commit-code' || echo "$d" | grep -q "$story_sha"; } \
    || { fail "ac2: description does not name the story-side commit (subject or sha $story_sha): $d"; return; }
  { echo "$d" | grep -q 'main-side-commit' || echo "$d" | grep -q "$main_sha"; } \
    || { fail "ac2: description does not name the main-side commit (subject or sha $main_sha): $d"; return; }
  pass "ac2: description names the conflicting file and the commits on both sides"
}

# ============================================================
# AC3 - after resolution + rework closed, the review issue is available again, and re-checked:
#       main moving again to a new conflict repeats AC1-2.
# ============================================================
# clone origin $ORIGIN, check out BRANCH, run the remaining args as a script in the clone, push BRANCH
in_clone() { local b=$1; shift; local d="$TMP/c.$RANDOM"
  $GIT clone -q "$ORIGIN" "$d" 2>/dev/null; ( cd "$d" && $GIT checkout -q "$b" && eval "$@" ) >/dev/null 2>&1; rm -rf "$d"; }
close_in_state() { local t; t=$(mktemp); jq -c --arg id "$1" 'map(if .id==$id then .status="closed" else . end)' "$W/issues.json" > "$t" && mv "$t" "$W/issues.json"; }

test_ac3_resolved_conflict_makes_review_available_again() {
  local saved="$ORIGIN" o2="$TMP/origin-ac3a.git"
  git clone -q --bare "$ORIGIN" "$o2" 2>/dev/null; ORIGIN="$o2"
  world_for_story s-code
  run_loop 6
  if [ "$(rework_count)" -lt 1 ] || claimed rv-s-code; then ORIGIN="$saved"; fail "ac3: precondition (conflict detected, review held back) not met. $(dump)"; return; fi
  local rw; rw=$(rework_issues | head -1 | jq -r .id)
  # engineer resolves: merge main into the story branch keeping the story side, push
  in_clone story/s-code "$GIT merge -q -X ours origin/main -m 'resolve: merge main' && $GIT push -q origin story/s-code"
  close_in_state "$rw"
  run_loop 7
  ORIGIN="$saved"
  claimed rv-s-code && pass "ac3: after the conflict was resolved and the rework closed, the review issue is claimable again" \
    || fail "ac3: review issue still not available after resolution + rework closed. $(dump)"
}
test_ac3_main_moving_again_repeats_detection() {
  local saved="$ORIGIN" o3="$TMP/origin-ac3b.git"
  git clone -q --bare "$ORIGIN" "$o3" 2>/dev/null; ORIGIN="$o3"
  # round 1: story/s-clean merges cleanly -> claimed
  world_for_story s-clean
  run_loop 6
  if ! claimed rv-s-clean; then ORIGIN="$saved"; fail "ac3: precondition failed - clean story's review was not claimed. $(dump)"; return; fi
  # main moves again, conflicting with the story's new.txt; the review issue is re-opened for another pass
  in_clone main "echo 'main version' > new.txt && $GIT add new.txt && $GIT commit -q -m main-adds-new-txt && $GIT push -q origin main"
  jq -c 'map(if .id=="rv-s-clean" then .status="open" | .assignee="" | .labels|=map(select(.!="needs-team-lead")) else . end)' "$W/issues.json" > "$W/i.tmp" && mv "$W/i.tmp" "$W/issues.json"
  : > "$W/bdlog"
  run_loop 7
  ORIGIN="$saved"
  if claimed rv-s-clean; then fail "ac3: after main moved to a new conflict the review issue was still handed to the reviewer (no re-check). $(dump)"; return; fi
  [ "$(rework_count)" -ge 1 ] && pass "ac3: a new conflict from main moving again is detected on re-check" \
    || fail "ac3: no rework issue filed for the new conflict. $(dump)"
}

# ============================================================
# AC4 - behind but merges cleanly: no rework issue, review proceeds.
# ============================================================
test_ac4_behind_but_clean_proceeds_without_rework() {
  scenario s-clean
  if git --git-dir="$ORIGIN" merge-base --is-ancestor refs/heads/main refs/heads/story/s-clean 2>/dev/null; then
    fail "ac4: fixture error - story/s-clean is not behind main"; return
  fi
  [ "$(rework_count)" -eq 0 ] || { fail "ac4: a rework issue was filed for a branch that merges cleanly: $(rework_issues)"; return; }
  grep -q '^bd create' "$W/bdlog" && { fail "ac4: bd create called for a clean story. $(dump)"; return; }
  claimed rv-s-clean || { fail "ac4: review issue of a merely-behind, cleanly mergeable story was not claimed. $(dump)"; return; }
  pass "ac4: behind-but-clean story: no rework, review claimed"
}

# ============================================================
# AC5 - detection never modifies origin or leaves a merge in progress.
# ============================================================
no_leftover_merge() { # prints the offending path, if any
  local m c; m=$(find "$W" -name MERGE_HEAD 2>/dev/null | head -1); [ -n "$m" ] && { echo "MERGE_HEAD at $m"; return; }
  for c in $(find "$W" -type d -name .git -prune 2>/dev/null); do
    [ -z "$(git -C "$(dirname "$c")" ls-files -u 2>/dev/null)" ] || { echo "unmerged paths in $(dirname "$c")"; return; }
  done
}
test_ac5_clean_branch_origin_unchanged_no_merge_in_progress() {
  scenario s-clean
  [ "$(cat "$W/heads.before")" = "$(cat "$W/heads.after")" ] \
    || { fail "ac5: origin refs changed while checking a clean branch: $(diff "$W/heads.before" "$W/heads.after")"; return; }
  local x; x=$(no_leftover_merge); [ -z "$x" ] || { fail "ac5: $x"; return; }
  pass "ac5: origin untouched and no merge in progress after checking a clean branch"
}
test_ac5_conflicting_branch_origin_unchanged_no_merge_in_progress() {
  scenario s-code
  [ "$(cat "$W/heads.before")" = "$(cat "$W/heads.after")" ] \
    || { fail "ac5: origin refs changed while checking a conflicting branch: $(diff "$W/heads.before" "$W/heads.after")"; return; }
  local x; x=$(no_leftover_merge); [ -z "$x" ] || { fail "ac5: $x"; return; }
  pass "ac5: origin untouched and no merge/unmerged paths left after checking a conflicting branch"
}

# ============================================================
# AC6 - no duplicate rework issue while one is still open.
# ============================================================
test_ac6_no_duplicate_rework_across_polls_and_runs() {
  world_for_story s-test
  run_loop 8           # several polling cycles inside one run
  run_loop 4           # and a second, later run against the same still-open rework
  local n; n=$(rework_count)
  [ "$n" -eq 1 ] && pass "ac6: exactly one merge-conflict rework issue after repeated checks" \
    || fail "ac6: expected exactly 1 merge-conflict rework issue after repeated checks, got $n. $(dump)"
}

# ============================================================
# AC7 - fix/<issue-id> merge-request issues get the same treatment.
# ============================================================
test_ac7_conflicting_fix_branch_held_back_and_rework_filed() {
  scenario fx-code
  if claimed rv-fx-code; then fail "ac7: reviewer got the merge-request issue of a conflicting fix/ branch. $(dump)"; return; fi
  local r; r=$(rework_issues | head -1)
  [ -n "$r" ] || { fail "ac7: no merge-conflict rework issue filed for conflicting fix/fx-code. $(dump)"; return; }
  echo "$r" | jq -e '(.labels|index("stage:rework")) and (.labels|index("merge-conflict")) and (.labels|index("role:engineer"))' >/dev/null \
    || { fail "ac7: rework labels wrong (want stage:rework, merge-conflict, role:engineer): $r"; return; }
  echo "$r" | jq -r '.description // ""' | grep -q 'src/app.sh' \
    || { fail "ac7: description does not name conflicting file src/app.sh: $r"; return; }
  pass "ac7: conflicting fix/ branch: review held back, engineer merge-conflict rework filed naming the file"
}
test_ac7_clean_fix_branch_proceeds() {
  scenario fx-clean
  [ "$(rework_count)" -eq 0 ] && claimed rv-fx-clean \
    && pass "ac7: clean fix/ branch proceeds to review without rework" \
    || fail "ac7: clean fix/ branch was held back or got rework. $(dump)"
}

# ============================================================
# AC8 - check cannot run (branch missing on origin): logged, review not blocked.
# ============================================================
test_ac8_missing_branch_logged_and_review_not_blocked() {
  scenario nobranch
  claimed rv-nb || { fail "ac8: review issue blocked because the check could not run (story/nobranch absent on origin). $(dump)"; return; }
  [ "$(rework_count)" -eq 0 ] || { fail "ac8: conflict rework filed for a branch that does not exist: $(rework_issues)"; return; }
  # the failure must be logged: a log line other than the START line (which carries only the title) mentions the branch
  if cat "$W/data/logs/reviewer/loop.log" "$W/data/control/alerts.log" 2>/dev/null | grep -v ' START ' | grep -q 'nobranch'; then
    pass "ac8: failure of the check is logged and the review issue is not blocked"
  else
    fail "ac8: no log line records that the conflict check could not run for story/nobranch. log:$(tail -n 8 "$W/data/logs/reviewer/loop.log" 2>/dev/null | tr '\n' ';')"
  fi
}

# ============================================================
# AC9 - the reviewer's own merge-time conflict flow is unchanged.
# ============================================================
test_ac9_reviewer_merge_time_conflict_flow_unchanged() {
  local f=agents/reviewer.md
  grep -q 'git merge --no-ff story/<story-id>' "$f" \
    && grep -q 'git diff --name-only --diff-filter=U' "$f" \
    && grep -q 'git merge --abort' "$f" \
    && grep -q 'bd create "Merge conflict: bring story/<story-id> up to date with origin/main"' "$f" \
    && grep -q 'stage:rework,story:<story-id>,merge-conflict' "$f" \
    && grep -qi 'All non-test -> `role:engineer`' "$f" \
    && grep -q 'bd dep add <your-issue> <new>' "$f" \
    && pass "ac9: reviewer.md still contains the merge-time conflict -> rework flow" \
    || fail "ac9: reviewer.md's merge-time conflict flow was altered or removed"
}

# ---------------- run all ----------------
for t in $(declare -F | awk '{print $3}' | grep '^test_ac' | sort); do "$t"; done
echo "---"; echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]
