# Design: agent-factory-dx0 - team-lead triages `needs-team-lead` issues

## Context
Today the five roles share one polling shape (`bin/agent-loop.sh`): find a `role:<me>` issue that
`bd ready` says is unblocked, claim it, run one Claude session, and either close it, park it behind
a new blocker, or label it `needs-human`. `team-lead` doesn't fit that shape - it has no `role:`
queue of its own; its queue is the `needs-team-lead` label on *other* roles' issues, and those
issues are frequently exactly the ones `bd ready` would hide (blocked on a bad/missing
dependency is one of the two examples the story gives). This design adds team-lead as a variant
code path inside the existing loop rather than a parallel mechanism, so it inherits the attempt
cap, circuit breaker, budget cap, STOP handling, and host-config sync for free.

## Approach

### 1. `bin/agent-loop.sh`: hyphenated `ROLE` breaks model selection
`model_var="MODEL_${ROLE^^}"` followed by `MODEL="${!model_var:-}"` is fatal for `ROLE=team-lead`:
`${ROLE^^}` produces `TEAM-LEAD`, and `MODEL_TEAM-LEAD` is not a legal bash identifier, so the
indirect expansion aborts the script before the main loop ever starts (verified: `bash -c
'x="A-B"; echo "${!x}"'` -> `bash: A-B: invalid variable name`, exit 1, no `set -e` needed to kill
it). Fix by sanitizing before building the name:
```bash
model_key="${ROLE^^}"; model_key="${model_key//-/_}"
model_var="MODEL_${model_key}"
MODEL="${!model_var:-}"
```
`MODEL_TEAM_LEAD` is the resulting env var name - unset by default (same as every other role
today), matching current behaviour. Actually wiring a non-default model tier for team-lead is
`agent-factory-250`; this change only stops the role from crashing on startup, which every other
part of this story depends on.

Also extend the `ROLE` usage message (`po|architect|qa|engineer|reviewer` -> `...|team-lead`) -
cosmetic, but it's the first thing anyone reads when this env var is wrong.

### 2. `bin/agent-loop.sh`: `next_issue()` - team-lead finds work by label, not `role:`
Add a role-conditional branch. Deliberately `bd list`, not `bd ready`: `bd ready` excludes
blocked/in_progress issues by design, but a stuck issue can be exactly a "blocked on the wrong
thing" case (the story's own example: "an implementation blocked on a missing test") - the thing
team-lead exists to look at. Excluding it from team-lead's own queue would defeat the story.
```bash
next_issue() {
  if [ "$ROLE" = "team-lead" ]; then
    bd list --label needs-team-lead --limit 50 --json 2>>"$LOGDIR/bd-err.log" | jq -r --arg me "$AGENT_ID" '
      [ .[]?
        | select(.status != "closed")
        | select(((.labels // []) | index("needs-human")) | not)
        | select(((.assignee // "") == "") or (.assignee == $me)) ]
      | .[0].id // empty' 2>/dev/null
    return
  fi
  bd ready --label "role:$ROLE" --limit 50 --json 2>>"$LOGDIR/bd-err.log" | jq -r --arg me "$AGENT_ID" '
    [ .[]?
      | select(((.labels // []) | index("needs-human")) | not)
      | select(((.assignee // "") == "") or (.assignee == $me)) ]
    | .[0].id // empty' 2>/dev/null
}
```
This satisfies AC1 (finds work via `needs-team-lead`, whatever other labels it carries) and AC2
(the `needs-human` exclusion is identical in shape to the existing one - team-lead never even sees
those issues as candidates, so it can't claim or modify them). `claim()`, `release_stale()`, the
attempt-cap state file, the circuit breaker and `wip_ok()` (a no-op for any role but `po`) are all
already keyed on issue id / role name generically and need no change.

### 3. `bin/agent-loop.sh`: `handle_outcome()` - team-lead's normal "done" doesn't fit the existing cases
The other four success cases are: issue closed; issue now `needs-human` (with the existing
note-presence check - this already works unmodified for team-lead's own AC6 escalations); issue
`open` but no longer `bd ready` (parked behind a new blocker). Team-lead's AC4/AC5 outcome is none
of these: it doesn't close someone else's stage issue (that stage's role still has to do the
actual work), and after a correct reroute the issue is very often `open` **and** ready again for
the new role - which currently falls through to `else return 1`, i.e. agent-loop.sh would count a
*successful* triage as a failed attempt and creep it toward the circuit breaker. Add one more
branch, checked after the existing `needs-human` branch (so that check's note-presence
verification still guards team-lead's own escalations) and before the final `return 1`:
```bash
  if [ "$ROLE" = "team-lead" ] && ! has_label "$id" needs-team-lead; then
    log "$id triaged (needs-team-lead cleared)"; return 0
  fi
```
Net behaviour per outcome:
- Reroute/fix (AC4/AC5): label removed, issue left open (ready or freshly blocked) -> this new
  branch (or, if freshly blocked, the pre-existing "parked behind new blockers" branch) -> success.
- Escalate (AC6): `needs-human` added -> existing `needs-human` branch fires first -> success,
  note-presence still checked.
- Session ends without doing either (crash, gave up silently): label still present -> falls to
  `return 1` -> ordinary retry/attempt-cap handling, same safety net every other role gets.

### 4. `agents/team-lead.md` (new)
Prompt content (full text, follows the imperative numbered-step convention of `agents/*.md`):
```markdown
# Role: Team Lead

Your job is triage, not implementation: diagnose why a piece of work is stuck and either correct
its routing or hand it to a human - you never write story/design/code/test content yourself.
Unlike the other five roles, you have no `role:team-lead` queue of your own; you're given (as
"Your assigned issue" below) an issue that belongs to some *other* role's stage, already labelled
`needs-team-lead`, keeping whatever `role:`/`stage:` labels it also carries.

1. Read broadly before deciding anything - this is the whole point of the role:
   - `bd show <your-issue>` (labels, status, dependencies, notes) and `bd comments <your-issue>`
     (full comment thread) - reconstruct what every prior agent on this issue did and why.
   - Its `story:<story-id>` label names the story. Read `docs/stories/<story-id>.md` in full.
   - Read `docs/design/<story-id>.md` if it exists; if it doesn't and this issue is past the
     design stage, that absence is itself a candidate diagnosis.
   - `bd list --label story:<story-id> --all --json` for every issue in the story's chain,
     including closed ones; `bd show`/`bd comments` the ones that look relevant to see what each
     stage actually closed with, and any rework issues already filed against this story.
   - The story's branches (`story/<story-id>`, and `-design`/`-tests` where they exist): `git log`,
     `git diff` against `origin/main` - see what actually landed, not just what the issue thread claims.

2. Diagnose the root cause. Typical patterns (not exhaustive):
   - Misrouted: the current `role:`/`stage:` isn't where the real problem is - e.g. a QA verify
     failure that's actually a design gap, or an implementation blocked because its dependency on
     the tests issue is missing or wrong.
   - Mechanically stuck: role/stage is already correct; something else is wrong - stale `status`,
     a missing/incorrect dependency, an issue that should be `bd ready` and isn't.
   - Not something relabelling fixes: the story or design itself is wrong/contradictory, or you
     can't tell what's wrong. Don't guess - see step 4.

3. Act on the diagnosis (covers AC4 and AC5):
   - **Reroute**: change the `role:`/`stage:` labels (`bd update <id> --remove-label role:X
     --add-label role:Y --remove-label stage:A --add-label stage:B`) and/or dependencies (`bd dep
     add` / `bd dep remove`) and/or `--status` so the correct role's own `bd ready --label
     role:<them>` picks it up next. Use the same `discovered-from`/`blocks` conventions the
     reviewer uses for "send this back a stage" (see `agents/reviewer.md`) when that's the shape
     of the fix.
   - **Fix directly**: role/stage was already right - correct the stale status, dependency, etc.
     without touching role/stage.
   - Either way: `bd update <id> --remove-label needs-team-lead`, then `bd comment <id> "<the root
     cause you found, and exactly what you changed>"`. Do not close the issue - it still belongs
     to whichever role/stage it now carries; closing it is that role's job, not yours.

4. **Escalate** (AC6) if you can't determine the root cause, or can determine it but can't resolve
   it by rerouting/relabelling/re-dependency-ing (e.g. the story or design is itself wrong - that's
   a human call): `bd update <id> --append-notes "<exactly what you need from a human, and
   why - what you checked, what you ruled out>"`, then `bd update <id> --remove-label
   needs-team-lead --add-label needs-human`, and stop. A `needs-human` label with no note is not a
   valid way to end your session. Per this story, you are now the only role that ever applies
   `needs-human` to an issue.

5. When step 1 leads you to a sibling issue in the story chain that's already labelled
   `needs-human`: read it for context, never claim, modify, or comment on it - it's reserved for a
   human, exactly as you found it.

Every issue you touch must read, afterwards, so its root cause and your decision are
understandable from `bd show`/`bd comments` alone with no other context - the same handoff bar
every other role holds itself to.
```
This satisfies AC3 (reads issue history, story doc, design doc, sibling issues before deciding)
and AC7 (explicit "handoff bar" framing + always `bd comment`s the diagnosis, mirroring
CLAUDE.md's own definition-of-done language).

### 5. Nothing else changes
- `docker-compose.yml`'s `agent` service is already role-generic (`ROLE` env var, per-role Claude
  config volume keyed on `${ROLE:-shell}`) - team-lead needs no new service definition, image
  change, or compose edit.
- `bin/start.sh`'s hardcoded `ROLES=(po architect qa engineer reviewer)` tmux layout is untouched -
  wiring team-lead into the default pane layout is `agent-factory-uhc`, explicitly out of scope.
  Until then, team-lead is run the same way `bin/start.sh` itself launches any role, just typed by
  hand from the `ops` window:
  ```
  ROLE=team-lead docker compose -f "$KIT_DIR/docker-compose.yml" run --rm --name factory-team-lead agent
  ```
  This is also exactly how the story's "must still be independently verifiable by hand-labelling
  an issue `needs-team-lead`" requirement gets exercised manually.
- `agent-loop.sh`'s existing `is_conflict_rework`/`restart_story` branch (merge-conflict rework
  gone bad) is not role-gated, so it already covers team-lead for free if that's ever the
  diagnosis - no new code needed there.
- `bin/board.sh`'s "by role"/`needs-human` views are not touched - a `needs-team-lead` view for
  the board is a visibility nice-to-have, not an acceptance criterion; leave it for a follow-up
  issue if someone wants it (file with `discovered-from`, don't build it here).
- No `role:team-lead` label is ever created or used anywhere - team-lead is found by
  `needs-team-lead` alone, per AC1.

### 6. `docs/ARCHITECTURE.md` and `README.md`
- ARCHITECTURE.md "Stack" paragraph: note team-lead as a sixth role that `agent-loop.sh` can run
  (`ROLE=team-lead`), found via the `needs-team-lead` label rather than a `role:` label, run
  manually (not part of `bin/start.sh`'s panes) until `agent-factory-uhc`.
- README.md "Day to day" table: add a row for hand-labelling an issue and running team-lead
  manually (the command from point 5 above), next to the existing "Unstick an issue" row.

## Acceptance criteria mapping
1. `next_issue()`'s team-lead branch queries `needs-team-lead` directly, not `role:team-lead`.
2. Same branch excludes `needs-human` issues from ever being returned as a candidate at all.
3. `agents/team-lead.md` step 1 mandates reading the issue's full history, the story doc, the
   design doc (if present), and the sibling issues in `story:<id>` before step 2's diagnosis.
4. `agents/team-lead.md` step 3 "Reroute"; `handle_outcome()`'s new branch stops agent-loop.sh
   from miscounting the result as a failure.
5. `agents/team-lead.md` step 3 "Fix directly"; same `handle_outcome()` branch.
6. `agents/team-lead.md` step 4; the pre-existing `needs-human` branch in `handle_outcome()`
   (unchanged) still verifies a note was actually left, same safety net as every other role.
7. `agents/team-lead.md`'s closing line + mandatory `bd comment` on every path (reroute, fix,
   escalate) in steps 3-4.

## Test strategy (QA)
This is the same `bin/agent-loop.sh` the `agent-factory-stg` acceptance test already exercises
end-to-end against stub `claude`/`bd`/`sleep` on `PATH` and a scratch git origin
(`tests/agent-factory-stg_test.sh`) - reuse that pattern rather than inventing a new harness:
- **`next_issue()` / polling (AC1, AC2)**: stub `bd list` to return a mix of issues (some
  `needs-team-lead` + various `role:`/`stage:` labels, one also carrying `needs-human`, one
  `status:closed`, one already assigned to a different agent id) and stub `bd ready` to return
  something different; run the loop with `ROLE=team-lead` and assert (via the `bdlog` stub-call
  log, as `agent-factory-stg`'s test does) that it calls `bd list --label needs-team-lead ...`
  (not `bd ready --label role:team-lead`), claims only the eligible one, and never claims or calls
  `bd update`/`bd comment` against the `needs-human` one.
- **Startup crash fix (prerequisite for everything else)**: run `agent-loop.sh` with `ROLE=team-lead`
  and a stub `claude` that just needs to be reached; before the fix this exits nonzero immediately
  with "invalid variable name" on stderr and never calls `bd` at all - assert it now reaches the
  main loop (stub `bd` gets called).
- **`handle_outcome()` (AC4, AC5, AC6)**: three stub-`bd` scenarios keyed on which `bd update`
  calls the fake team-lead session under test issues:
  1. reroute/fix: session removes `needs-team-lead`, leaves the issue `open`/ready and NOT
     closed -> assert loop treats it as success (`fails` stays 0, no `record_failure`, i.e. no
     `--append-notes`/`needs-human` added afterward).
  2. escalate: session adds `needs-human` (with a note) and removes `needs-team-lead` -> assert
     existing success path, and that the existing "no note" mechanical check does NOT fire.
  3. neither (simulated stuck/crashed session, label still present, issue still open) -> assert
     this is treated as a failure (attempt recorded / retried), matching every other role's
     "did nothing" case.
- **Prompt content (AC3, AC7)**: not shell-testable; verify by reading `agents/team-lead.md`
  against AC3's four required inputs and AC7's "bd comment before finishing" requirement on every
  path - a manual/inspection check, noted as such in the verify comment.
- **Manual/integration smoke** (recommended, not required for verify to pass): with a real Beads
  DB, hand-label a real (or scratch) issue `needs-team-lead` and run the docker command from
  design point 5 for real, confirming it claims, investigates, and resolves the label one way or
  another - closest thing this kit has to an end-to-end test for a new role (see
  `docs/ARCHITECTURE.md`'s "Test strategy" section on why there's no framework beyond this).
- `shellcheck bin/agent-loop.sh` on the diff.

## Out of scope
As in the story: switching the other five roles' escalation label to `needs-team-lead`
(`agent-factory-ulq`), team-lead's default model (`agent-factory-250`), team-lead's tmux pane
placement (`agent-factory-uhc`), and any change to how po/architect/engineer/qa/reviewer behave
once handed a rerouted issue. Also out of scope, not requested by any acceptance criterion: a
`needs-team-lead` view in `bin/board.sh`; changing `in_flight()`'s WIP-throttle logic (it only
special-cases `needs-human` today - once `agent-factory-ulq` lands and the *other* roles start
producing `needs-team-lead` instead, that throttle may need the same exemption, but nothing
produces a `needs-team-lead` issue automatically yet, so there's nothing for it to interact with
in this story).
