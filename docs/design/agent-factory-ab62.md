# Design: agent-factory-ab62 - team-lead releases its claim after routing

## Approach
Docs-only change to `agents/team-lead.md`. `bin/agent-loop.sh` claims every issue before the
team-lead session (`claim()`, sets assignee + in_progress), so any issue team-lead hands on to
another role's queue stays claimed and is invisible to that role's `bd ready`. Add one explicit,
reusable rule and reference it from each triage path. No script changes (routing/triage rules and
other roles' claim handling are out of scope).

## Change to `agents/team-lead.md`
1. Add a short section **"Release your claim when you hand an issue on"** after the numbered
   steps 1-5 (before "Size a new story's chain"). Content:
   - `agent-loop.sh` claims the issue before your session, so it is assigned to you and in progress.
   - After routing an issue to another role's queue you MUST run `bd unclaim <id>` (this clears
     the assignee and returns status to open) so the next role's `bd ready --label role:<them>`
     returns it. Run it as the **last** bd action on the issue, after labels and `bd comment`.
   - Applies to: reroute/fix-directly outcomes of step 3 (AC1, AC2); the no-`role:*` sweep
     outcomes - both the story-labelled reroute and the "route to po" branch (AC1).
   - Does NOT apply when you keep the issue: closing it (e.g. `needs-chain` issue after building
     the chain), or escalating to `needs-human` (AC4). Those keep their normal handling.
2. Step 3: append to the "Either way" bullet: "then `bd unclaim <id>` (see 'Release your claim...')".
3. Sweep section, no-`story:` branch: after `bd comment`, add `bd unclaim <your-issue>`.
4. "Size a new story's chain" step 4 (AC3): keep "close your issue" (closed issue is not left
   claimed). Add: if you did not close it, or you claimed any other issue while building the
   chain, `bd unclaim` it before finishing. In the too-ambiguous branch (`needs-human`), note
   explicitly that no unclaim is required (AC4).
5. Step 4 escalate: add "(no `bd unclaim` - you are keeping the issue for the human)".

Wording must include the literal string `bd unclaim` (AC5) and state the rule applies only when
handing to another role's queue (AC4).

## Error cases
`bd unclaim` on an issue not claimed by you or already unassigned: harmless; prose says to ignore
a "not claimed" result rather than treat it as failure. If an issue is closed, do not unclaim.

## Acceptance mapping
AC1/AC2: new section + step 3 edit. AC3: chain-sizing edit. AC4: explicit exclusions in section
and step 4/ambiguous branch. AC5: the section itself, discoverable by heading.

## Test strategy
Prose checks in `tests/agent-factory-ab62_test.sh`, same style as `tests/agent-factory-wnju_test.sh`
/ `dx0_test.sh` (grep on `agents/team-lead.md`): file mentions `bd unclaim <id>` with "after
routing"; step 3 and the sweep no-story branch each reference unclaim; chain section covers
unclaim/claimed; text states unclaim is not required for closed / `needs-human` issues. Re-run
existing `wnju` and `dx0` tests as regressions (don't remove phrases they grep for). No behavioural
test needed: `agent-loop.sh` is unchanged.
