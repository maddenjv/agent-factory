# agent-factory-m7af: Team-lead sweeps the board for unassigned issues - design

## Context
`agent-factory-dx0` gave team-lead one queue: issues another role explicitly labelled
`needs-team-lead`. That only ever covers work that started in the normal pipeline and got stuck.
An issue that never got a `role:*` label in the first place - someone ran `bd create` by hand
instead of `feature.sh` (the only path that reliably sets `role:po` - README "Flow" step 1), or a
bug elsewhere stripped a label - is invisible to every role's own `bd ready --label role:<them>`
(`bin/agent-loop.sh`'s `next_issue()` for the five build roles) and to team-lead's own
`needs-team-lead` query. Nothing currently notices it.

This story widens what `agent-loop.sh` treats as team-lead's queue (`next_issue()`) and what
`agents/team-lead.md` tells it to do with what it finds there. It deliberately reuses
`agent-factory-dx0`'s diagnose/reroute/escalate mechanics for issues that turn out to belong to an
existing story chain - it does not redefine that logic (out of scope, per the story). What's new:
(a) the queue also includes open issues with no `role:*` label that aren't
`needs-human`/`needs-team-lead`, and (b) a default outcome for issues with no story context at
all - route them to `role:po`, same as `feature.sh` would have.

## Approach

### 1. `bin/agent-loop.sh`: `next_issue()` - widen the team-lead branch
Today:
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
  ...
```
`--label needs-team-lead` does the "which issues are candidates" filtering server-side, which is
exactly what has to change: candidates are now *either* `needs-team-lead`-labelled *or* carrying
no `role:*` label. `bd list` has no "lacks any label matching a prefix" filter (`--label`/
`--label-any`/`--label-pattern`/`--label-regex` are all positive-match only - confirmed via
`bd list --help`), so, same as `in_flight()` already does a few lines down for its own
multi-condition label logic, fetch the (unfiltered) open board once and do the union in `jq`:
```bash
next_issue() {
  if [ "$ROLE" = "team-lead" ]; then
    bd list --limit 200 --json 2>>"$LOGDIR/bd-err.log" | jq -r --arg me "$AGENT_ID" '
      [ .[]?
        | select(.status != "closed")
        | select(((.labels // []) | index("needs-human")) | not)
        | select(((.assignee // "") == "") or (.assignee == $me))
        | select( ((.labels // []) | index("needs-team-lead"))
                  or (((.labels // []) | any(startswith("role:"))) | not) ) ]
      | .[0].id // empty' 2>/dev/null
    return
  fi
  ...
```
Two changes from today, both inside the same `jq` pipeline so `claim()`, `release_stale()`, the
attempt-cap state file, the circuit breaker and `wip_ok()` (all keyed on issue id / role name
generically) need no change:
- `bd list --label needs-team-lead` -> `bd list` (no label filter): fetches every open issue
  (`--limit 200`, matching `is_ready()`'s own full-board query a few lines up - the default 50
  undercounts once the board has more than 50 open issues across every role, which this sweep, by
  definition, now has to look across).
- The final `select`: an issue is a candidate if it carries `needs-team-lead` (today's condition,
  unchanged in shape) **or** carries no label starting with `role:` (the new sweep condition,
  AC1). The existing `needs-human` exclusion and assignee filter apply to both equally (AC1's "and
  no `needs-human` or `needs-team-lead` label" - the second half of that clause is automatically
  true for a sweep candidate, since a `needs-team-lead`-labelled issue would already match via the
  *first* half of the `select`'s `or` and never needs the second half to fire; nothing bypasses
  the `needs-human` exclusion either way).

This satisfies AC1 (sweep candidates are claimed alongside, not instead of, `needs-team-lead`
ones) and AC2 (an issue carrying any `role:*` label, and not `needs-team-lead`, matches neither
branch of the `or` and is never a candidate; `needs-human` issues are excluded up front exactly as
today - team-lead never sees them as a candidate at all, so it can't claim, modify, or comment on
them, same guarantee `agent-factory-dx0` already gives).

No change to `handle_outcome()`: its team-lead branch already fires on *any* issue that no longer
carries `needs-team-lead` -
```bash
  if [ "$ROLE" = "team-lead" ] && ! has_label "$id" needs-team-lead; then
    log "$id triaged (needs-team-lead cleared)"; return 0
  fi
```
- and a sweep-found issue never carried that label to begin with, so this already reads as
"triaged" the moment team-lead adds `role:po` or a `role:`/`stage:` reroute, without the label
ever needing to be removed. Verified by re-reading `agent-factory-dx0`'s design and
`bin/agent-loop.sh` together: nothing in `handle_outcome()`, `record_failure()`, or the escalation
backstop loop keys off *which* label was present before, only whether `needs-team-lead`/
`needs-human` is present *now* - both new outcomes (AC3's reroute, AC4's route-to-`role:po`) fall
through to that same branch as a success; AC5's escalation falls into the existing `needs-human`
branch, note-presence check included, exactly as it does today for a `needs-team-lead`-sourced
escalation.

### 2. `agents/team-lead.md` - two entry points, one new outcome
Minimal-diff approach: keep the existing numbered steps 1-5 verbatim (content, not just meaning -
`agent-factory-dx0`'s own tests, still in the regression suite, grep this file for specific
phrases inside them; see "Test strategy" below), update the intro paragraph to describe both entry
points, and append a new section after step 5, the same shape `agent-factory-vfu3` used to add
`agents/reviewer.md`'s "Storyless fix review" section onto an unrelated, unchanged existing flow.

Intro paragraph, replacing only the last sentence:
```markdown
Your job is triage, not implementation: diagnose why a piece of work is stuck, or where an
unrouted issue belongs, and either correct its routing or hand it to a human - you never write
story/design/code/test content yourself. Unlike the other five roles, you have no
`role:team-lead` queue of your own; you're given (as "Your assigned issue" below) one of two
kinds of issue, both surfaced by `agent-loop.sh`'s team-lead poll: an issue that belongs to some
*other* role's stage, already labelled `needs-team-lead`, keeping whatever `role:`/`stage:`
labels it also carries; or an issue with no `role:*` label at all (and not `needs-human`), found
by sweeping the board for work that never got routed anywhere. `bd show <your-issue>` first: if
it carries `needs-team-lead`, follow steps 1-5 below unchanged; if it carries no `role:*` label,
skip to "Sweep: issues with no `role:*` label" at the end of this file instead.
```
Steps 1-5 (investigate, diagnose, reroute/fix, escalate, don't touch a sibling `needs-human`
issue): **unchanged**, byte-for-byte.

New section, appended after step 5 and before the file's closing paragraph:
```markdown
## Sweep: issues with no `role:*` label

This is the same `agent-loop.sh` team-lead poll as above, widened to also surface open issues
that carry no `role:*` label and aren't `needs-human` or `needs-team-lead` - work that reached the
board outside the normal `feature.sh` intake path (someone ran `bd create` by hand, or a bug
elsewhere stripped a label) and so is invisible to every role's own `bd ready --label
role:<them>`. Check `bd show <your-issue>` for a `story:<id>` label:

- **Carries a `story:<id>` label** - it belongs to an existing story chain that lost its routing
  labels. Diagnose and act exactly per steps 1-5 above (same read-broadly investigation, same
  reroute/fix/escalate outcomes), with two differences: there is no `needs-team-lead` label on
  this issue, so skip that part of step 3's "Either way" (nothing to remove); and step 4's
  "undiagnosable" also covers `docs/stories/<id>.md` not existing at all for the labelled story
  id, or the chain otherwise not making sense - escalate exactly as step 4 says.
- **Carries no `story:<id>` label** - nothing ties it to an existing story chain; it reads as a
  raw, unfiled feature or bug report. Route it the same place `feature.sh` would have:
  `bd label add <your-issue> role:po`, then `bd comment <your-issue> "<state that you found this
  issue with no role assignment and routed it to po as a new, unfiled request>"`. Stop there - do
  not investigate further, reroute to any other role, or touch any other label; `po` triages it
  from here like any request that came in through the normal intake path.
```
The file's existing closing paragraph ("Every issue you touch must read, afterwards, ... the same
handoff bar every other role holds itself to.") already generalises to both entry points with no
edit needed - it doesn't name a specific outcome, so it covers `role:po` routing for free.

This satisfies AC3 (story-chain sweep hits reuse steps 1-5's investigation and outcomes exactly),
AC4 (no-story-context default: `role:po` + explanatory `bd comment`, both explicitly named), AC5
(escalation reuses step 4 verbatim, plus the explicit "story doc doesn't exist" undiagnosable
case), and AC6 (closing paragraph's standalone-readability bar, plus every one of the three sweep
outcomes above ends in a `bd comment`).

### 3. `docs/ARCHITECTURE.md` and `README.md` - kept current, already done in this commit
Same as `agent-factory-dx0`'s own design session (`README.md`/`docs/ARCHITECTURE.md` committed
directly alongside that design doc, not left as an instruction for the engineer) and
`agent-factory-vfu3`'s (`docs/ARCHITECTURE.md` "done directly, in this commit"): these are the
architect's own file per `CLAUDE.md`'s Files section, and the edit is small enough to make now
rather than describe for someone else to apply later.

`docs/ARCHITECTURE.md`'s team-lead paragraph now reads:
```markdown
A sixth role, `team-lead`, triages two kinds of work: issues explicitly labelled
`needs-team-lead` (a stuck piece of work another role flagged), and - since `agent-factory-m7af` -
open issues that carry no `role:*` label at all and aren't `needs-human`/`needs-team-lead`, i.e.
work that reached the board outside the normal `feature.sh` intake path. `agent-loop.sh` finds
both directly via `bd list` (not a `role:team-lead` label the other five use, and not `bd ready`,
since the whole point is investigating issues that may be blocked or otherwise not ready). It
reroutes stuck work to the correct role/stage, fixes it directly, routes a no-story-context issue
to `role:po`, or escalates to `needs-human` - see `agents/team-lead.md`. It isn't part of
`bin/start.sh`'s tmux layout yet (`agent-factory-uhc`) or given a non-default model tier yet
(`agent-factory-250`); until those land, run it by hand:
`ROLE=team-lead docker compose -f "$KIT_DIR/docker-compose.yml" run --rm --name factory-team-lead agent`.
```

`README.md`'s "Day to day" table row "Ask team-lead to triage a stuck issue" now has an added
clause noting the sweep runs automatically, no hand-labelling needed for that half of the job:
```
| Ask team-lead to triage a stuck issue | `bd label add <id> needs-team-lead`, then `ROLE=team-lead docker compose -f "$KIT_DIR/docker-compose.yml" run --rm --name factory-team-lead agent` from the `ops` window (not in the default `agents` pane layout yet - see `docs/ARCHITECTURE.md`). It also picks up issues with no `role:*` label on its own, no hand-labelling needed. |
```

The engineer's diff is `bin/agent-loop.sh` and `agents/team-lead.md` only (sections 1-2 above).

## Error cases
- **Race: another role labels the issue while it's already claimed.** `claim()` is atomic on
  assignee (unchanged); once team-lead holds the issue, nobody else's `bd ready --label
  role:<them>` can see it anyway (still no `role:*` label until team-lead adds one), so this can
  only be a human hand-editing labels concurrently - out of scope, same as every other role's
  general "don't fight a human's concurrent edit" assumption.
- **`--limit 200` still isn't enough.** Same latent cap `is_ready()` already accepts elsewhere in
  this file; not introduced by this story. If the open board ever exceeds it, the fix is a shared
  one (raise the limit or paginate `bd list` generally), not specific to team-lead - not fixed
  here.
- **A sweep issue has a `story:<id>` label pointing at a story that exists but whose chain is
  otherwise mid-flight in a way that's genuinely ambiguous** (e.g. two issues in the chain both
  look like the "current" stage): covered by step 4's escalation, reused as-is - team-lead
  appends a note naming exactly what's ambiguous and labels `needs-human`, per AC5.
- **An issue with no `role:*` label also happens to already carry `role:po` at the moment
  team-lead's sweep branch routes it there** - can't happen: the sweep candidate `select` requires
  *no* label starting with `role:`, and `bd label add ... role:po` is the only label team-lead
  adds in that branch, so this is a one-time, idempotent transition.

## Acceptance criteria mapping
1. `next_issue()`'s widened `select`: sweep candidates (no `role:*` label, not
   `needs-human`/`needs-team-lead`) are unioned with, not swapped in for, `needs-team-lead`
   candidates.
2. Same `select`: any issue carrying a `role:*` label (and not `needs-team-lead`), or
   `needs-human`, or already `needs-team-lead` (handled by the pre-existing branch, unchanged)
   never matches - team-lead never claims, modifies, or comments on it via this sweep.
3. `agents/team-lead.md`'s new "Sweep" section, `story:<id>` branch: reuses steps 1-5's
   investigate/diagnose/reroute-or-fix/`bd comment` process exactly.
4. Same section, no-`story:<id>` branch: `role:po` + explanatory `bd comment`, named explicitly.
5. Same section's `story:<id>` branch, "undiagnosable" clause (missing story doc, unclear chain)
   plus reused step 4: append-notes, `needs-human`, stop.
6. Every sweep outcome (reroute, route-to-`role:po`, escalate) ends in a `bd comment`/note, and
   the file's existing closing paragraph holds all of it to the same standalone-readable bar.

## Test strategy (QA)
Same harness `agent-factory-dx0`'s own test (`tests/agent-factory-dx0_test.sh`, still in the
regression suite and expected to keep passing unmodified - see below) already established for
this exact code path - reuse it, don't invent a new one:
- **`next_issue()` polling (AC1, AC2)**: run the real `bin/agent-loop.sh` with `ROLE=team-lead`
  against a stub `bd list` (no `--label` filter this time - the stub needs to return the full
  fixture array when called with none, same as `tests/agent-factory-dx0_test.sh`'s existing stub
  already does) and a stub `claude`, same scratch-git-origin harness as
  `tests/agent-factory-dx0_test.sh`/`tests/agent-factory-stg_test.sh`. Fixture needs, at minimum:
  one issue with no `role:*` label and no other disqualifying label (must be claimed), one with a
  `role:*` label and no `needs-team-lead` (must never be claimed), one with no `role:*` label but
  `needs-human` (must never be claimed), one with no `role:*` label but `needs-team-lead` (must be
  claimed - already covered in shape by the existing `needs-team-lead` fixtures, confirms the
  union didn't regress the original case), one `needs-team-lead` + unrelated `role:`/`stage:`
  (must still be claimed, pins AC1's "alongside, not instead of").
- **`agents/team-lead.md` content (AC3-AC6)**: prose checks, same style as
  `tests/agent-factory-dx0_test.sh`'s `test_ac3`-`test_ac7` - assert the new "Sweep" section
  exists and mentions `story:<id>`, `role:po`, `bd comment`, `needs-human`/`--append-notes` in the
  right branches. Not independently shell-testable, same limitation the original story already
  documented.
- **Regression**: `bash tests/agent-factory-dx0_test.sh` must still report `failed=0` - verified
  during this design session by applying the exact `bin/agent-loop.sh`/`agents/team-lead.md` text
  above to local (uncommitted, reverted) copies and running it: all of `test_ac1`-`test_ac7`
  passed, including the AC3/AC7 prose checks against the appended (not rewritten) file. The
  engineer should not need to touch that test file.
- `shellcheck bin/agent-loop.sh` on the diff.

## Out of scope
As the story states: redefining `needs-team-lead`'s existing diagnose/reroute/escalate logic
(`agent-factory-dx0`, reused verbatim here, not touched); correcting an issue that has the
*wrong* `role:*` label (still the existing `needs-team-lead` flow, unchanged, and still depends on
some other agent noticing); team-lead's model tier (`agent-factory-250`) and tmux pane placement
(`agent-factory-uhc`); any change to how po/architect/engineer/qa/reviewer behave once handed a
rerouted or newly-`role:po`-labelled issue - that's each role's own normal queue from here.
