# agent-factory-ulq: Escalation protocol - stuck roles label needs-team-lead, not needs-human - design

## Context
Today `agents/CLAUDE.project.md` tells all five build roles (`po`, `architect`, `engineer`, `qa`,
`reviewer`) to label a stuck issue `needs-human`, and `bin/agent-loop.sh` backs that with two
mechanical backstops that apply the same label on an agent's behalf: `record_failure()`'s
attempt-cap escalation and `handle_outcome()`'s missing-note check. `agent-factory-dx0` (merged to
`main`, gate `agent-factory-d2j`, closed) adds a `team-lead` role whose queue *is* the
`needs-team-lead` label; team-lead falls back to `needs-human` only when it can't resolve
something itself (`agents/team-lead.md`, already on `main`). This story flips the five roles' own
label from `needs-human` to `needs-team-lead`, reserving `needs-human` for team-lead's own
escalations, without touching team-lead's behavior at all (AC8).

**Branch note for the engineer:** `story/agent-factory-ulq` was cut from `main` *before*
`agent-factory-dx0` merged, so `bin/agent-loop.sh` on this branch today has neither dx0's
`team-lead` branch in `next_issue()` nor its branch in `handle_outcome()` - this design is written
against that current (pre-dx0) content, matching what QA's tests extract (`sed -n '55,254p'
bin/agent-loop.sh`, tests/agent-factory-ulq_test.sh:57-58). Merging `origin/main` into
`story/agent-factory-ulq` will conflict with this work in exactly `next_issue()` and
`handle_outcome()` (dx0 and this story both edit those two functions). That merge is expected and
is the reviewer's/engineer's standard merge-conflict rework flow (`agents/reviewer.md`,
`agents/engineer.md`), not something to solve here - but the two designs are written to compose
cleanly once combined (see the inline notes on each function below), so the conflict resolution is
purely textual, never a logic decision.

## Approach
Change exactly three kinds of place, all mechanical text/label swaps:
1. `agents/CLAUDE.project.md` - the shared "blocked/unsure" instruction and its "Definition of
   done" summary (AC1, AC2).
2. `bin/agent-loop.sh` - `next_issue()` (AC5, AC6), `handle_outcome()` (AC4), `record_failure()`
   (AC3, AC8), `in_flight()` (AC7).
3. Every role prompt (`agents/architect.md`, `agents/po.md`, `agents/qa.md`, `agents/reviewer.md`,
   `agents/engineer.md`) that independently restates the same "I'm stuck, label X" instruction in
   its own role-specific wording. These aren't covered by an acceptance test (QA's ac1/ac2 check
   only `CLAUDE.project.md`, per its own comment: "ac1/ac2 are content checks on
   agents/CLAUDE.project.md (the source template)") but they're the same escalation path the story
   describes, just duplicated per role - leaving them saying `needs-human` would have an architect
   or qa session read a *more specific* instruction than `CLAUDE.project.md`'s and could easily
   follow the stale one. Fixing them is required for the feature to actually work, not just for
   doc hygiene, so it's in scope despite not being test-covered.
Also touches one line of `docs/ARCHITECTURE.md` (my own upkeep responsibility per CLAUDE.md's
Files section) for accuracy. `README.md` has the same kind of stale mentions but isn't owned by
any role's explicit file list; filed as a separate low-priority follow-up rather than fixed here
(see "Out of scope").

### 1. `agents/CLAUDE.project.md`

Line 16, the forward-reference from the `bd comment` bullet (no acceptance test touches this line;
fixed so the forward reference still points at the right label):
```diff
-  progress/handoff note; it's separate from the `--append-notes` note used below for `needs-human`.
+  progress/handoff note; it's separate from the `--append-notes` note used below for `needs-team-lead`.
```

Lines 19-23, the "blocked/unsure" bullet (AC1) - replace in full:
```diff
-- If you are blocked, unsure, or the input is wrong or under-specified: **before** labelling, run
-  `bd update <your-issue> --append-notes "<exactly what you need from a human, and why>"` - specific
-  enough that a human reading only `bd show <your-issue>` (no other context) knows what to answer -
-  then `bd label add <your-issue> needs-human`, and stop. A human will respond. Guessing is worse
-  than stopping. A `needs-human` issue with no note on it is not a valid way to end your session.
+- If you are blocked, unsure, or the input is wrong or under-specified: **before** labelling, run
+  `bd update <your-issue> --append-notes "<exactly what you need done or decided, and why>"` -
+  specific enough that team-lead (or a human, if team-lead escalates further) can act on `bd show
+  <your-issue>` alone - then `bd label add <your-issue> needs-team-lead`, and stop. Team-lead will
+  triage it: reroute you back to work, fix something mechanical, or escalate to a human itself.
+  Guessing is worse than stopping. A `needs-team-lead` issue with no note on it is not a valid way
+  to end your session.
```
(Verified this keeps `bd label add <your-issue> needs-team-lead` and the `--append-notes` phrase
each on one physical line, and drops every `needs-human` mention - what
`tests/agent-factory-ulq_test.sh`'s `test_ac1_*` greps for.)

Lines 43-47, "Definition of done" (AC2) - swap the one label:
```diff
 ## Definition of done for your session
 Either (a) your issue is closed with a `bd comment` handoff note, or (b) it is labelled
-`needs-human` with a `--append-notes` note explaining exactly what's needed (see Tracker, above),
-or (c) you filed rework issues that block it and set it back to open (only qa and reviewer do
-this). Anything else counts as a failed session.
+`needs-team-lead` with a `--append-notes` note explaining exactly what's needed (see Tracker,
+above), or (c) you filed rework issues that block it and set it back to open (only qa and reviewer
+do this). Anything else counts as a failed session.
```

### 2. `bin/agent-loop.sh`

**`next_issue()` (currently lines 69-75) - AC5, AC6.** Add one more exclusion, same shape as the
existing one:
```diff
 next_issue() {
   bd ready --label "role:$ROLE" --limit 50 --json 2>>"$LOGDIR/bd-err.log" | jq -r --arg me "$AGENT_ID" '
     [ .[]?
       | select(((.labels // []) | index("needs-human")) | not)
+      | select(((.labels // []) | index("needs-team-lead")) | not)
       | select(((.assignee // "") == "") or (.assignee == $me)) ]
     | .[0].id // empty' 2>/dev/null
 }
```
AC5 (needs-human still excluded) is the untouched line; AC6 (needs-team-lead newly excluded) is
the new line. `tests/agent-factory-ulq_test.sh`'s `test_ac5_*`/`test_ac6_*` call this unconditional
function directly with `ROLE=qa` - no role branching needed here.
*Composing with dx0*: dx0 added an early `if [ "$ROLE" = "team-lead" ]; then ...; return; fi`
branch above this code, whose own filter deliberately excludes only `needs-human` (team-lead's
queue *is* `needs-team-lead`, so it must not exclude it). This story's new line only ever executes
for the five build roles reaching the bottom of the function, so no role-conditional is needed
here even after that merge - the two branches don't interact.

**`in_flight()` (currently lines 96-107) - AC7.** Widen the "stalled" label check from
`needs-human` alone to either label; rename `$nh` to `$stalled_lbl` since it's no longer only
about `needs-human`:
```diff
-in_flight() {  # stories whose review issue is not yet closed, minus those stalled on a needs-human issue
+in_flight() {  # stories whose review issue is not yet closed, minus those stalled on a needs-human/needs-team-lead issue
   bd list --json 2>/dev/null | jq '
     [ .[]? | select(.status != "closed") ] as $open
-    | ($open | map({key: .id, value: ((.labels // []) | index("needs-human") != null)}) | from_entries) as $nh
+    | ($open | map({key: .id, value: ((.labels // []) | (index("needs-human") != null) or (index("needs-team-lead") != null))}) | from_entries) as $stalled_lbl
     | ( [ $open[]
-          | select(($nh[.id]) or ([ (.dependencies // [])[] | select(.type == "blocks") | $nh[.depends_on_id] ] | any))
+          | select(($stalled_lbl[.id]) or ([ (.dependencies // [])[] | select(.type == "blocks") | $stalled_lbl[.depends_on_id] ] | any))
           | (.labels // [])[] | select(startswith("story:")) ] | unique ) as $stalled
     | [ $open[]
         | select((.labels // []) | index("role:reviewer"))
         | select(([ (.labels // [])[] | select(startswith("story:")) ] | any(. as $s | $stalled | index($s))) | not)
       ] | length' 2>/dev/null
 }
```
`wip_ok()` right below is untouched (still just gates `po` on `in_flight() < WIP_LIMIT`).
`tests/agent-factory-ulq_test.sh`'s `test_ac7_*` extracts `in_flight()`+`wip_ok()` together via
`sed -n '/^in_flight()/,/^wip_ok()/p'`, so both function signatures (start/end lines) must stay
exactly as they are today - only the jq body inside `in_flight()` changes, matching the diff above.

**`handle_outcome()` (currently lines 214-237) - AC4.** Add a new branch, same note-check shape as
the existing `needs-human` branch, inserted right after it and before the "parked behind new
blockers" check:
```diff
   if has_label "$id" needs-human; then
-    # CLAUDE.project.md tells the agent to --append-notes what it needs BEFORE labelling
+    # The agent's own role instructions (CLAUDE.project.md for the five build roles;
+    # agents/team-lead.md for team-lead) say to --append-notes what it needs BEFORE labelling
     # needs-human - but that's an instruction to an LLM, not a guarantee. Back it up mechanically:
     # if it labelled needs-human without a note (issue_field's "// empty" also catches a JSON
     # null, which is what an unset field reads as), `bd show` would otherwise be a dead end for
     # a human trying to figure out what's actually needed.
     if [ -z "$(issue_field "$id" notes)" ]; then
       bd update "$id" --append-notes "agent-loop: $AGENT_ID labelled this needs-human but left no note explaining what it needs - see the session transcript. Transcript: $LOGDIR/$(date +%F).$id.jsonl" >/dev/null 2>&1
       alert "$id flagged needs-human WITHOUT an explanation from the agent - see the transcript"
     else
       alert "$id flagged needs-human by the agent"
     fi
     return 0
   fi
+  if [ "$ROLE" != "team-lead" ] && has_label "$id" needs-team-lead; then
+    # Same backstop as needs-human above, for the five build roles' own escalation
+    # (agent-factory-ulq). Excluded for ROLE=team-lead: team-lead's own assigned issue always
+    # already carries needs-team-lead when a session starts (that's how it finds its queue), so
+    # an unconditional check here would treat "session ended without clearing the label" (a
+    # failed triage) as a legitimate outcome. team-lead's own success/failure signal is instead
+    # whether it *cleared* the label (agent-factory-dx0's handle_outcome branch, which runs after
+    # this one and checks `! has_label "$id" needs-team-lead`).
+    if [ -z "$(issue_field "$id" notes)" ]; then
+      bd update "$id" --append-notes "agent-loop: $AGENT_ID labelled this needs-team-lead but left no note explaining what it needs - see the session transcript. Transcript: $LOGDIR/$(date +%F).$id.jsonl" >/dev/null 2>&1
+      alert "$id flagged needs-team-lead WITHOUT an explanation from the agent - see the transcript"
+    else
+      alert "$id flagged needs-team-lead by the agent"
+    fi
+    return 0
+  fi
   if [ "$st" = "open" ] && ! is_ready "$id"; then log "$id parked behind new blockers (rework/handoff)"; return 0; fi
   return 1
 }
```
`tests/agent-factory-ulq_test.sh`'s `test_ac4_*` calls this with `ROLE=qa`, so the `[ "$ROLE" !=
"team-lead" ]` guard is true and the branch fires; `test_ac8_*` calls the *existing* `needs-human`
branch with `ROLE=team-lead` (unchanged, still unconditional on role) and doesn't exercise this new
branch at all, so this guard is untested by name but required for correctness once combined with
dx0's own `handle_outcome` branch (see the code comment above).
*Left alone, deliberately*: the very first check in this function,
`is_conflict_rework "$id" && { has_label "$id" conflict-unresolvable || has_label "$id"
needs-human; }`, is a third, separate backstop (auto-restarting a story stuck in merge-conflict
rework) - not one of "the two backstops" this story is scoped to. `record_failure()`'s own
`if is_conflict_rework "$id"; then restart_story "$id" attempt-cap; fi` (unchanged, see below)
already fires regardless of *which* label was just applied, so this path stays covered without
touching it. Not extending it to `needs-team-lead` is a deliberate scope call, not an oversight.

**`record_failure()` (currently lines 239-254) - AC3, AC8.** The label the attempt-cap backstop
applies now depends on role - `needs-team-lead` for the five build roles, `needs-human` unchanged
for `team-lead`:
```diff
 record_failure() {
-  local id=$1 f="$STATE/attempts.$1" n
+  local id=$1 f="$STATE/attempts.$1" n esc_label
   n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"
   bd update "$id" --status open >/dev/null 2>&1
   if [ "$n" -ge "$MAX_ATTEMPTS_PER_ISSUE" ]; then
+    # team-lead keeps needs-human (agent-factory-dx0, unchanged by this story, AC8); the five
+    # build roles switch to needs-team-lead (AC3).
+    esc_label="needs-team-lead"; [ "$ROLE" = "team-lead" ] && esc_label="needs-human"
     bd update "$id" --append-notes "agent-loop: not completed after $n attempt(s) by $AGENT_ID (session ended without closing or explaining why). Transcript: $LOGDIR/$(date +%F).$id.jsonl" >/dev/null 2>&1
-    bd label add "$id" needs-human >/dev/null 2>&1
-    alert "$id not completed after $n attempts; labelled needs-human"
+    bd label add "$id" "$esc_label" >/dev/null 2>&1
+    alert "$id not completed after $n attempts; labelled $esc_label"
     if is_conflict_rework "$id"; then restart_story "$id" attempt-cap; fi
   else
     log "$id not completed (attempt $n/$MAX_ATTEMPTS_PER_ISSUE); released for retry"
   fi
 }
```
The `--append-notes` text ("not completed after N attempt(s)...") is untouched - it's what
`test_ac3_*` greps for - only the label that gets applied changes. `is_conflict_rework`'s restart
trigger right below is untouched and role-agnostic, so it keeps firing regardless of which label
was just set (see the "left alone, deliberately" note above).

### 3. Role prompts (`agents/*.md`)

Each of these restates the same "I'm stuck" pattern from `agents/CLAUDE.project.md` in its own
role-specific trigger condition. Swap `needs-human` -> `needs-team-lead` in the *escalation*
instances; for the two "do NOT use needs-human, use conflict-unresolvable instead" guardrails
(`engineer.md`, `qa.md`'s merge-conflict rework steps), add `needs-team-lead` to what's being
steered away from too, since that's now the label an agent would otherwise reach for.

**`agents/architect.md`** (lines 18-20):
```diff
-3. If the story is under-specified, contradictory or much larger than it looked: `bd update <your-issue>
-   --append-notes "<your specific questions>"` then label your issue `needs-human`, instead of designing
-   around the gap. Skipping the note leaves a human with nothing to act on - do not label needs-human without one.
+3. If the story is under-specified, contradictory or much larger than it looked: `bd update <your-issue>
+   --append-notes "<your specific questions>"` then label your issue `needs-team-lead`, instead of designing
+   around the gap. Skipping the note leaves team-lead (or, if it escalates further, a human) with nothing to
+   act on - do not label needs-team-lead without one.
```

**`agents/po.md`** (lines 9-11):
```diff
-3. If the request is ambiguous in a way that changes what gets built: `bd update <your-issue> --append-notes
-   "<your specific questions>"` then label your issue `needs-human`, and stop - a needs-human label with no
-   note on it leaves a human with nothing to act on.
+3. If the request is ambiguous in a way that changes what gets built: `bd update <your-issue> --append-notes
+   "<your specific questions>"` then label your issue `needs-team-lead`, and stop - a needs-team-lead label
+   with no note on it leaves team-lead with nothing to act on.
```

**`agents/qa.md`**, four spots:
- Lines 29-32 (regression Exception bullet):
  ```diff
     - Exception: if the older script fails because this story deliberately changes that earlier story's behaviour
       (compare against this story's acceptance criteria), never edit or delete the old test. Say so explicitly in the
       bug description; if unclear whether the change is intended, `bd update <your-issue> --append-notes "<why>"`
  -    and label it `needs-human`.
  +    and label it `needs-team-lead`.
  ```
- Lines 33-35 (quota/usage-limit test bullet):
  ```diff
     - If the story touches quota/usage-limit handling (limit/reset code in `bin/agent-loop.sh`), the usage-limit test
       from agent-factory-stg (`tests/agent-factory-stg_test.sh`) must be among the scripts run; if it is absent that
  -    is a defect (or `needs-human`), and if it fails, file a regression naming the usage-limit wait-for-reset behaviour.
  +    is a defect (or `needs-team-lead`), and if it fails, file a regression naming the usage-limit wait-for-reset behaviour.
  ```
- Lines 42-44 (2+ rework rounds):
  ```diff
  4. If this story already has 2 or more `stage:rework` issues (`bd list` and filter by the `story:` label; ignore `merge-conflict` ones), do not
  -   file more: `bd update <your-issue> --append-notes "<summary of the recurring problem>"` then label your
  -   issue `needs-human` - a needs-human label with no note on it leaves a human with nothing to act on.
  +   file more: `bd update <your-issue> --append-notes "<summary of the recurring problem>"` then label your
  +   issue `needs-team-lead` - a needs-team-lead label with no note on it leaves team-lead with nothing to act on.
  ```
- Lines 48-51 (rework merge-conflict guardrail):
  ```diff
  1. Check out `story/<story-id>` and pull. If the issue has label `merge-conflict`, run `git fetch origin main && git merge origin/main`,
     resolve the test-file conflicts, re-run the full suite, push, `bd comment`, close. If it cannot be resolved:
  -   `bd update <your-issue> --append-notes "<why>"` (mandatory), `bd label add <your-issue> conflict-unresolvable`, stop (not `needs-human`; `agent-loop.sh` restarts the story). Otherwise fix the tests directly
  +   `bd update <your-issue> --append-notes "<why>"` (mandatory), `bd label add <your-issue> conflict-unresolvable`, stop (not `needs-team-lead` or `needs-human`; `agent-loop.sh` restarts the story). Otherwise fix the tests directly
     there (both tracks are already merged).
  ```

**`agents/reviewer.md`**, two spots:
- Line 18:
  ```diff
  -If main moved and `git merge --no-ff story/<story-id>` reports conflicts, route it to rework (never `needs-human`):
  +If main moved and `git merge --no-ff story/<story-id>` reports conflicts, route it to rework (never `needs-team-lead` or `needs-human`):
  ```
- Lines 43-45 (2+ rework rounds):
  ```diff
  -If the story already has 2 or more `stage:rework` issues (not counting `merge-conflict` ones): `bd update <your-issue> --append-notes "<why it
  -keeps failing review>"` then label your issue `needs-human`, instead of filing more - a needs-human label
  -with no note on it leaves a human with nothing to act on.
  +If the story already has 2 or more `stage:rework` issues (not counting `merge-conflict` ones): `bd update <your-issue> --append-notes "<why it
  +keeps failing review>"` then label your issue `needs-team-lead`, instead of filing more - a needs-team-lead
  +label with no note on it leaves team-lead with nothing to act on.
  ```

**`agents/engineer.md`**, three spots:
- Lines 12-15 (test-is-wrong escalation):
  ```diff
  3. Do NOT edit or delete QA's acceptance tests to make them pass. If you believe a test is wrong,
  -   `bd update <your-issue> --append-notes "<why you think it's wrong>"`, label your issue `needs-human`, and
  -   stop - a needs-human label with no note on it leaves a human with nothing to act on. You may add your own
  +   `bd update <your-issue> --append-notes "<why you think it's wrong>"`, label your issue `needs-team-lead`, and
  +   stop - a needs-team-lead label with no note on it leaves team-lead with nothing to act on. You may add your own
     unit tests alongside.
  ```
- Line 30 (merge-conflict guardrail):
  ```diff
  -  `bd label add <your-issue> conflict-unresolvable` and stop. Do NOT label it `needs-human` or close it;
  +  `bd label add <your-issue> conflict-unresolvable` and stop. Do NOT label it `needs-team-lead` or
  +  `needs-human`, and do not close it;
     `agent-loop.sh` restarts the story.
  ```
- Lines 35-37 (finish, suite never went green):
  ```diff
  Finish: everything committed and pushed, full suite green, `bd comment` summarising what changed, close it.
  If you cannot get the suite green after a genuine effort, `bd update <your-issue> --append-notes "<what you
  -tried>"` then label it `needs-human`.
  +tried>"` then label it `needs-team-lead`.
  ```

### 4. `docs/ARCHITECTURE.md` (lines 51-53)
```diff
 - Errors inside `agent-loop.sh` are handled by the loop itself (attempt caps, circuit breaker,
-  `needs-human` escalation with a note) rather than by scripts crashing silently - see README
-  "Guardrails built in".
+  `needs-team-lead` escalation with a note for the five build roles, `needs-human` for team-lead's
+  own escalations) rather than by scripts crashing silently - see README "Guardrails built in".
```

## Acceptance criteria mapping
1. `agents/CLAUDE.project.md`'s blocked/unsure bullet labels `needs-team-lead`, never `needs-human`
   - §1 diff above.
2. Its "Definition of done" section names `needs-team-lead` - §1 diff above.
3. `record_failure()`'s attempt-cap backstop labels `needs-team-lead` (with the unchanged "not
   completed after N attempt(s)..." note) for all five build roles - §2 `record_failure()` diff.
4. `handle_outcome()`'s missing-note backstop fires for an unexplained `needs-team-lead` exactly as
   it does for `needs-human` - §2 `handle_outcome()` diff, new branch.
5. `needs-human` stays excluded from `next_issue()`'s ready-work query, unchanged - §2
   `next_issue()` diff (existing line untouched).
6. `needs-team-lead` is newly excluded from `next_issue()`'s ready-work query, same shape - §2
   `next_issue()` diff (new line).
7. A story stalled behind `needs-team-lead` (directly or via a blocking dependency) is excluded
   from `in_flight()`'s WIP count, same as `needs-human` today - §2 `in_flight()` diff.
8. team-lead's own escalation (both `record_failure()` and `handle_outcome()`) still uses
   `needs-human`, completely unchanged - §2 `record_failure()`'s `esc_label` branch and
   `handle_outcome()`'s untouched `needs-human` branch; the new `needs-team-lead` branch is
   explicitly guarded off for `ROLE=team-lead`.

## Test strategy
`tests/agent-factory-ulq_test.sh` already exists (QA wrote it against the story before this design)
and exercises every AC above 1:1 - `test_ac1_blocked_bullet_labels_needs_team_lead`,
`test_ac2_definition_of_done_names_needs_team_lead` (content checks on `CLAUDE.project.md`),
`test_ac3_attempt_cap_labels_needs_team_lead_for_the_five_roles`,
`test_ac4_missing_note_backstop_fires_for_needs_team_lead`,
`test_ac8_team_lead_escalation_still_uses_needs_human` (extract and run `record_failure()`/
`handle_outcome()` against a stub `bd`), `test_ac5_needs_human_still_excluded_from_ready_work`,
`test_ac6_needs_team_lead_excluded_from_ready_work` (extract and run `next_issue()`),
`test_ac7_story_stalled_on_needs_team_lead_not_counted` (extract and run `in_flight()`/`wip_ok()`).
No new tests are needed for this design; the engineer's job is to make
`bash tests/agent-factory-ulq_test.sh` (and the full existing suite, unaffected) pass, plus
`shellcheck bin/agent-loop.sh` clean. Additionally:
- Manually diff each role file against the blocks in §3 to confirm no other `needs-human` mention
  was missed and no unrelated line was touched: `grep -n needs-human agents/*.md` should, after
  this story, only ever appear as "don't use needs-human (only needs-team-lead)" guardrail text
  (`engineer.md`, `qa.md`'s merge-conflict steps, `reviewer.md`'s merge-conflict step), never as an
  instruction to actually apply the label, in any of the five build-role files.
- Re-run the full suite (`find tests -type f \( -name '*_test.sh' -o -path 'tests/acceptance/*.sh'
  \) | sort`, per `docs/ARCHITECTURE.md`'s test strategy) to confirm nothing else regressed.

## Out of scope
- Everything the story itself excludes: team-lead's own diagnose/reroute/escalate behavior
  (`agent-factory-dx0`), retroactively relabelling existing `needs-human` issues, propagating this
  change into already-initialized projects' `CLAUDE.md` copies (`bin/init-project.sh` isn't
  touched), team-lead's model tier and tmux placement.
- `bin/restart-story.sh`'s own `needs-human` labelling (a second-restart-refused circuit breaker) -
  a third, separate backstop, not one of "the two backstops" this story names, and not a role's own
  "I'm stuck" escalation.
- `bin/board.sh`, `bin/approve.sh`, `bin/new-story.sh`, `bin/init-project.sh` - these operate on
  `needs-human` as an operational label/dashboard concept (e.g. `HUMAN_APPROVE_STORIES` story
  gating, the board's human-review-by-exception list) that remains valid and unchanged: it's simply
  now populated only by team-lead instead of by all five roles plus the two backstops.
- `handle_outcome()`'s `is_conflict_rework` top-of-function check - deliberately left checking only
  `conflict-unresolvable`/`needs-human`, not extended to `needs-team-lead` (see the inline note in
  §2). `record_failure()`'s own restart trigger already covers the attempt-cap path regardless of
  label.
- `README.md` has the same kind of stale `needs-human` mentions (`Guardrails built in`,
  "Review-by-exception", the "2 rework rounds" line) but isn't owned by any role's file list in
  `CLAUDE.md`'s Files section, so it isn't fixed as part of this design. Filed as a follow-up:
  `agent-factory-ulq` design issue files a `discovered-from`-linked task for it (see `bd comment`
  on this issue).
