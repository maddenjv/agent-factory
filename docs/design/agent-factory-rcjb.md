# Design: team-lead picks up every needs-team-lead issue (agent-factory-rcjb)

Story: `docs/stories/agent-factory-rcjb.md`. Touches `bin/agent-loop.sh` (`next_issue()`, `claim()`),
`docs/ARCHITECTURE.md` (one sentence), plus a new test. No change to `agents/team-lead.md`.

## Root cause

team-lead's poll in `next_issue()` (`bin/agent-loop.sh`) ANDs the label condition with
`(.assignee // "") == "" or .assignee == $me`. A build role that escalates does so from inside its
own claimed session: `bd label add <id> needs-team-lead`, then exits. `handle_outcome()` returns 0
("agent did something legitimate") and nothing clears the claim, so the issue stays
`assignee=<role>` (`AGENT_ID` defaults to `$ROLE`, e.g. `po`), usually `in_progress`. Consequences:

1. Build-role queues skip it (`needs-team-lead` exclusion) - intended.
2. team-lead's poll skips it (`assignee == "po"` is neither empty nor `team-lead`) - the bug (AC2).
3. Even if polled, `claim()` returns 1 for any other assignee ("could not claim"), so the fix has to
   touch `claim()` too, or the issue is selected every cycle and never worked (sleep 5, forever).

Other candidates from the story, ruled out: `bd list --limit 200` is fine (closed issues are hidden by
default, so the window is open+in_progress only; the board is nowhere near 200), and the
`needs-human`/status/label conditions already match AC1, AC3 and AC4 (unassigned `needs-team-lead` +
`role:*`/`stage:*`/`story:*` is already selected). Those ACs just need regression tests. Note that
`record_failure()` also leaves the assignee in place when it labels `needs-team-lead` after the
attempt cap, so the same stale claim arises there.

## Decision on the assignee rule (AC5)

Change it, narrowly. For the `needs-team-lead` branch only, an issue is selectable when its assignee is
empty, is team-lead itself, or is **a build-role identity** - i.e. matches
`^(po|architect|engineer|qa|reviewer)([-_.].*)?$` (the suffix tolerates a non-default `AGENT_ID`
such as `engineer-2`). Rationale: the `needs-team-lead` label is the escalating role's statement
that it has stopped; no other build role's queue will touch a `needs-team-lead` issue, so any
build-role assignee is by construction the escalator's stale claim. Any other assignee (a human
name, or anything not a build-role identity) is still skipped - the "another live agent" case of
AC5 is unchanged. The `no role:*` and `needs-chain` triage paths keep the strict
`empty-or-me` rule (out of scope; their claimants are not stale escalators).

Implement with a jq `def`, keeping the selection in one pipeline:

```jq
def stale_escalator: (.assignee // "") | test("^(po|architect|engineer|qa|reviewer)([-_.].*)?$");
...
| select( (((.labels // []) | index("needs-team-lead"))
           and (((.assignee // "") == "") or (.assignee == $me) or stale_escalator))
         or ( ((((.labels // []) | any(startswith("role:"))) | not)
               or ((.labels // []) | index("needs-chain")))
              and (((.assignee // "") == "") or (.assignee == $me)) ) )
```

`needs-human` exclusion and `status != closed` stay as the first two selects, unchanged (AC4).

## claim() takeover

`claim()` gets a team-lead-only branch, used when the current assignee is a build-role identity
(same regex, done in bash with `[[ =~ ]]`) **and** the issue carries `needs-team-lead`:

```bash
bd update "$id" --if-assignee "$who" --assignee "$AGENT_ID" --status in_progress --force
```

`--if-assignee` makes it a compare-and-swap (exit 13 on mismatch => `claim` returns 1, same as a lost
race today); `--force` is required because bd refuses to overwrite another actor's live
`in_progress` claim. Everything else in `claim()` is unchanged (unassigned => `--claim`; already
ours => resume; other => return 1). The engineer must verify the exact flag combination against the
installed `bd` in a scratch repo (`--force` + `--if-assignee` + `--status`); if bd rejects the
combination, fall back to `bd unclaim`-style release then `--claim` - but do not weaken the
`needs-team-lead` + build-role-assignee precondition. (I could not exercise this against a scratch
bd during design; that check is the engineer's first step.)

Only role `team-lead` may use this branch (guard on `$ROLE = team-lead`); build roles never see
`needs-team-lead` issues so are unaffected.

## AC mapping

| AC | How satisfied |
|----|---------------|
| 1  | Already true for unassigned issues; locked in by test. |
| 2  | New `stale_escalator` clause in `next_issue()` + `claim()` takeover. |
| 3  | Already true; locked in by test (stage/story labels irrelevant to the filter). |
| 4  | `needs-human` select untouched; test. |
| 5  | Assignee outside empty/me/build-role identities still skipped; test with assignee e.g. `alice`. Rule change is exactly the build-role clause above. |
| 6  | After triage team-lead clears `needs-team-lead` and sets `role:<x>`; the role's `bd ready --label role:<x>` queue (unchanged) picks it up provided the assignee is empty or the role's own. Team-lead's reroute per `agents/team-lead.md` must therefore leave the assignee as either empty or the target role. If team-lead's prompt does not already clear/replace the stale assignee on reroute, the engineer files a discovered-from issue for `agents/team-lead.md` (out of scope here) - and the test for AC6 covers the case where assignee was cleared. Note `claim()` by team-lead means the assignee after triage is `team-lead`, which the target role's queue would skip (`assignee == me` fails): so **after picking up, team-lead must release the claim when it reroutes**. See next section. |
| 7  | Tests below; the AC2 test fails on current code. |

## AC6 detail: assignee after triage

Because team-lead now takes the claim, an issue it reroutes (clears `needs-team-lead`, sets
`role:<x>`) would be assigned to `team-lead` and hidden from role `<x>`'s queue. Handle this in
`handle_outcome()` (the loop's post-session hook, already where the "triaged (needs-team-lead
cleared)" log line lives), not in the prompt: in the branch
`[ "$ROLE" = team-lead ] && ! has_label "$id" needs-team-lead`, if the issue is still open/in_progress
and assigned to `$AGENT_ID` and carries a `role:*` label, run
`bd update "$id" --assignee "" --status open` before logging. (Closed issues return earlier; issues
that lost `needs-team-lead` without a `role:*` label are the no-role path and are left alone - its
existing behaviour.) Guard with `--if-assignee "$AGENT_ID"`.

## Test strategy (QA)

New `tests/agent-factory-rcjb_test.sh`, in the style of `tests/agent-factory-vfu3_test.sh`: extract
`log()..sync_dir()` from `bin/agent-loop.sh` into a sourced file, stub `bd` on `PATH`, drive
`next_issue` with `ROLE=team-lead AGENT_ID=team-lead`. The stub must answer `bd list ... --json`
(the vfu3 stub only handles `ready`) from a fixture file, and for `claim()`/handle_outcome tests
record the `bd update` argv it receives to a log file for assertion.

Cover:
- AC1: unassigned `needs-team-lead,role:po` => selected.
- AC2: `needs-team-lead,role:po`, `assignee=po`, status `in_progress` (and `open`) => selected; also
  `assignee=engineer-2`. **Must fail on current code.**
- AC3: `needs-team-lead,role:qa,stage:verify,story:x` => selected.
- AC4: `needs-team-lead,needs-human` (unassigned and assigned to a role) => not selected.
- AC5: `needs-team-lead` assigned to `alice` => not selected; role-less issue assigned to `po`
  => still not selected (strict path unchanged); role-less unassigned => selected (unchanged);
  closed => not selected.
- claim(): with assignee `po` + `needs-team-lead`, team-lead's `claim` issues the
  `--if-assignee po --assignee team-lead ... --force` update and returns 0; with assignee `alice`
  it returns 1 and issues no update; a non-team-lead role never uses the takeover.
- AC6: handle_outcome as team-lead on an issue now assigned to team-lead, labels
  `role:po,...` without `needs-team-lead` => a release update (`--assignee ""`, `--status open`) is
  issued; then `next_issue` for `ROLE=po` with the fixture reflecting the released state (bd ready
  output, unassigned, `role:po`) returns it.
- Ordering sanity: with two matching issues the first in `bd list` order is returned (no crash on
  missing `.assignee` field - bd omits it when unset).

Existing tests that must keep passing: `vfu3`, `x8wj`, `m7af`, `dx0`, `ulq`, `250` (they source or grep
`agent-loop.sh`); run the whole `tests/` suite per ARCHITECTURE.md's test command.

## Docs

`docs/ARCHITECTURE.md`, team-lead paragraph: add one sentence - `needs-team-lead` issues are picked up
even when still claimed by the escalating build role (its stale claim is taken over), while other
assignees are respected; team-lead releases the claim when it reroutes to a role.

## Single engineer task

Small enough for one implement issue; no extra issues created.
