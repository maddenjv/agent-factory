# agent-factory-m7af: Team-lead sweeps the board for unassigned issues

## Story
As the agent-factory system, I want team-lead to also pick up open issues that carry no
`role:*` label and aren't already reserved for a human or team-lead, diagnose where they
belong, and label them into the correct role's queue (or escalate if it can't tell), so that
issues which reach the board outside the normal `feature.sh` intake path don't sit invisible
forever - no role's `bd ready --label role:<them>` will ever surface an issue with no `role:*`
label at all.

## Context
Today team-lead ([agents/team-lead.md](../../agents/team-lead.md), built in `agent-factory-dx0`)
only ever looks at issues another agent has explicitly labelled `needs-team-lead`. That covers
work that started in the normal pipeline and got stuck. It does not cover an issue that never got
a `role:*` label in the first place - e.g. someone ran `bd create` by hand instead of
`feature.sh` (which is the only path that reliably sets `role:po` - see README "Flow" step 1), or
a bug elsewhere strips a label. Because every role's own queue is `bd ready --label
role:<them>` (see `agent-loop.sh`), an issue with no `role:*` label is invisible to all five
build roles - nothing currently notices it or routes it anywhere. This story makes team-lead
that safety net, widening what it treats as its own work rather than changing what it does once
it has an issue in hand.

This story deliberately reuses the diagnose/reroute/escalate mechanics `agent-factory-dx0`
already built (`agents/team-lead.md` steps 1-4) for issues that turn out to belong to an
existing story chain (they carry a `story:<id>` label but lost their `role:`/`stage:` labels) -
it does not redefine that logic. What's new is purely: (a) team-lead's queue also includes
open issues with no `role:*` label that aren't `needs-human`/`needs-team-lead`, and (b) a default
outcome for issues with no story context at all - the ones that look like a raw, unfiled feature
or bug report - which routes them the same place `feature.sh` would have: `role:po`.

## Acceptance criteria

1. **Given** an open issue with no `role:*` label and no `needs-human` or `needs-team-lead`
   label, **when** team-lead polls for work, **then** it claims that issue as part of its own
   queue, alongside (not instead of) issues explicitly labelled `needs-team-lead`.

2. **Given** an open issue that already carries a `role:*` label, or is labelled `needs-human`
   or `needs-team-lead`, **when** team-lead polls for work via this sweep, **then** it does not
   claim, modify, or comment on that issue - only issues with no `role:*` label at all are in
   scope here; correcting an issue that has the *wrong* `role:*` label is the existing
   `needs-team-lead` flow, unchanged by this story.

3. **Given** a claimed no-`role:*`-label issue that also carries a `story:<id>` label (i.e. it
   belongs to an existing story chain but lost its routing labels), **when** team-lead
   investigates, **then** it applies the same read-broadly-then-diagnose process
   `agents/team-lead.md` already uses for `needs-team-lead` issues (issue history, the story
   doc, the design doc if any, sibling issues in the chain) to determine the correct
   `role:`/`stage:` labels, applies them, and leaves a `bd comment` explaining the diagnosis -
   exactly the existing reroute outcome, just reached via this sweep instead of an explicit
   `needs-team-lead` label.

4. **Given** a claimed no-`role:*`-label issue that carries no `story:<id>` label (nothing ties
   it to an existing story chain - it reads as a raw, unfiled feature or bug report), **when**
   team-lead triages it, **then** it labels the issue `role:po` (the same queue `feature.sh`
   would have put it in) and leaves a `bd comment` stating that it found the issue with no role
   assignment and routed it to `po` as a new, unfiled request.

5. **Given** team-lead cannot tell which case an issue falls into (e.g. it carries a
   `story:<id>` label but `docs/stories/<id>.md` doesn't exist, or the chain state is otherwise
   unclear), **when** it triages it, **then** it escalates exactly as it already does for an
   undiagnosable `needs-team-lead` issue: append a note stating exactly what it needs and why,
   label the issue `needs-human`, and stop.

6. **Given** any issue team-lead has labelled `role:po`, rerouted, or escalated under this
   sweep, **when** its `bd show`/`bd comments` history is read afterward, **then** it explains
   why the issue had no role assignment and what team-lead decided - same handoff bar as every
   other role holds itself to.

## Out of scope
- Changing what label `feature.sh` or any other issue-creation path applies - this story is a
  safety net for issues that reach the board without one, not a replacement for normal intake.
- Redefining or extending the diagnose/reroute/escalate logic for issues already labelled
  `needs-team-lead` (`agent-factory-dx0`'s existing behaviour) - this story only widens what
  counts as team-lead's work queue and adds the no-story-context default (AC4).
- Any change to team-lead's model tier (`agent-factory-250`) or tmux pane placement
  (`agent-factory-uhc`).
- Issues that have a `role:*` label but the *wrong* one (e.g. `role:qa` on work that's actually
  a design gap) - that correction path is the existing `needs-team-lead` flow, which depends on
  some other agent noticing and flagging it; this story does not add new noticing logic for
  mislabelled-but-labelled issues.
