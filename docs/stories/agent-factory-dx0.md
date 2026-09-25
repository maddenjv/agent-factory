# agent-factory-dx0: Team-lead agent triages stuck work

## Story
As the agent-factory system, I want a `team-lead` role that picks up issues labelled
`needs-team-lead`, diagnoses why the work is actually stuck using visibility across the whole
story (not just one role's slice of it), and either reroutes the issue to the correct role/stage
or escalates to a human when it genuinely can't, so that misrouted work (e.g. a failing test that
is really a design gap, or an implementation blocked on a missing test) gets corrected
automatically instead of defaulting straight to a human every time.

## Context
Today the only escalation path a stuck agent has is labelling its issue `needs-human` - even when
the real problem is simply that the issue is stuck with the wrong role or stage, something a
better-informed triage step could fix without a human. This story adds that triage mechanism: a
runnable `team-lead` role and its diagnose/reroute/escalate behaviour.

Two things this story deliberately does NOT include, even though they're related and mentioned in
the parent feature request:
- Changing what label `po`/`architect`/`engineer`/`qa`/`reviewer` apply when *they* get stuck
  (currently `needs-human`) - that switch to `needs-team-lead` is `agent-factory-ulq`, and it
  explicitly depends on this story landing first. Until `ulq` ships, nothing in the normal flow
  produces a `needs-team-lead` issue for team-lead to pick up; the mechanism built here must still
  be independently verifiable by hand-labelling an issue `needs-team-lead`.
- team-lead's default model tier (`agent-factory-250`) and its tmux pane placement
  (`agent-factory-uhc`) - both explicitly depend on this story existing first and are separate
  stories.

Unlike the other five roles, which only ever look at their own issue and the artifacts for their
own stage, team-lead's whole job requires reading across the story: the issue's full history, the
story doc, the design doc (if any), and the sibling issues in the same `story:<id>` chain - that's
what "visibility into the whole solution" (from the parent request) means here, and it's what lets
team-lead tell a design gap from an implementation bug from a test bug.

## Acceptance criteria

1. **Given** an issue labelled `needs-team-lead` (whatever `role:`/`stage:` labels it also
   carries), **when** the team-lead role's agent loop polls for work, **then** it claims that
   issue - team-lead finds work via the `needs-team-lead` label itself, not via a `role:team-lead`
   label the way the other five roles find work via their own `role:` label.
2. **Given** an issue already labelled `needs-human`, **when** team-lead polls for work, **then**
   it does not claim or modify that issue - `needs-human` issues are reserved for a human to
   answer, and going forward team-lead is the only role that ever applies the `needs-human` label
   (it is not applied as a way to skip an issue team-lead hasn't investigated).
3. **Given** a claimed `needs-team-lead` issue, **when** team-lead investigates, **then** it reads
   the issue's full comment/notes history, `docs/stories/<story-id>.md`, `docs/design/<story-id>.md`
   (if present), and the other issues in the same `story:<id>` chain, before making a routing
   decision.
4. **Given** team-lead determines the work is at the wrong role/stage (e.g. a QA failure actually
   caused by a design gap, or an implementation blocked on a missing test), **when** it reroutes,
   **then** it updates the issue's `role:`/`stage:` labels and/or dependencies/status so the
   correct role can pick it up next, leaves a `bd comment` explaining the diagnosis and exactly
   what it changed, and the issue is no longer labelled `needs-team-lead`.
5. **Given** team-lead determines the role/stage was already correct and the blocker is something
   else it can fix directly (e.g. a stale status, a wrong dependency), **when** it fixes that,
   **then** it leaves a `bd comment` explaining what was wrong and what it changed, and the issue
   is no longer labelled `needs-team-lead`.
6. **Given** team-lead cannot determine the root cause, or cannot resolve it by rerouting,
   **when** it gives up, **then** it appends notes to the issue stating exactly what it needs from
   a human and why, labels the issue `needs-human`, and stops.
7. **Given** any issue team-lead has rerouted, fixed, or escalated, **when** its `bd show` history
   is read afterwards with no other context, **then** the comment/notes thread makes the root
   cause and the decision understandable - the same handoff bar every other role holds itself to.

## Out of scope
- Switching the other five roles' own escalation label from `needs-human` to `needs-team-lead`
  (`agent-factory-ulq`).
- team-lead's default model (`agent-factory-250`).
- team-lead's tmux pane placement (`agent-factory-uhc`).
- Any change to how po/architect/engineer/qa/reviewer behave once handed a rerouted issue - they
  pick it up exactly as they would any other issue matching their `role:`/`stage:` labels.
