# agent-factory-ulq: Escalation protocol - stuck roles label needs-team-lead, not needs-human

## Story
As the agent-factory system, I want po/architect/engineer/qa/reviewer (and agent-loop.sh's own
automatic attempt-cap escalation on their behalf) to label a blocked issue `needs-team-lead`
instead of `needs-human`, so that `needs-human` becomes reserved for team-lead's own escalations
and every other stuck issue reaches team-lead's triage first.

## Context
`agents/CLAUDE.project.md` currently tells all five roles: if you're blocked, unsure, or the input
is wrong or under-specified, append notes explaining what you need and label the issue
`needs-human`, then stop. `bin/agent-loop.sh` backs that convention with two mechanical paths that
apply the same label on an agent's behalf: `record_failure()`'s attempt-cap backstop (an issue
that's failed `MAX_ATTEMPTS_PER_ISSUE` times gets `needs-human` whether or not the agent asked for
it), and `handle_outcome()`'s missing-note backstop (an agent that labelled `needs-human` without
leaving notes gets a note appended pointing at the transcript). Both currently hardcode
`needs-human`.

`agent-factory-dx0` (Team-lead agent: pick up needs-team-lead issues and reroute to the right
role) adds a `team-lead` role whose job is to triage issues labelled `needs-team-lead`: diagnose
the real root cause using visibility across the whole story, reroute to the correct role/stage
when it can, and only fall back to `needs-human` - now reserved for team-lead's own use - when it
genuinely can't resolve something. `dx0`'s own story doc calls this story out by id and is
explicit that **this story depends on dx0 landing on main first**: until team-lead exists and is
running, nothing would ever pick up a `needs-team-lead` issue, so flipping the label first would
leave every stuck issue silently unpicked instead of visibly stuck for a human. That dependency is
encoded as a real `bd dep` on this story's design issue (blocked on `agent-factory-d2j`, dx0's
review/merge gate), not just noted here.

This story only touches the five roles' own escalation path and agent-loop.sh's two backstops for
them. It does not touch team-lead's own behavior (agent-factory-dx0's scope) - team-lead keeps
using `needs-human` exactly as dx0 specifies.

## Acceptance criteria

1. **Given** `agents/CLAUDE.project.md`'s "blocked, unsure, or the input is wrong or
   under-specified" guidance, **when** a po/architect/engineer/qa/reviewer agent follows it,
   **then** the instructions have it append notes explaining exactly what it needs and label the
   issue `needs-team-lead` - not `needs-human`.
2. **Given** `agents/CLAUDE.project.md`'s "Definition of done for your session" section, **when**
   it describes the labelled-for-escalation outcome for po/architect/engineer/qa/reviewer,
   **then** it names `needs-team-lead`, not `needs-human`, as that outcome's label.
3. **Given** `bin/agent-loop.sh`'s attempt-cap backstop (`record_failure`) firing after
   `MAX_ATTEMPTS_PER_ISSUE` unsuccessful attempts on an issue owned by one of the five roles,
   **when** it escalates automatically, **then** it labels the issue `needs-team-lead` - not
   `needs-human` - while still appending the same kind of explanatory note ("not completed after N
   attempt(s)...") it does today.
4. **Given** `bin/agent-loop.sh`'s missing-note backstop (in `handle_outcome`), **when** a
   po/architect/engineer/qa/reviewer agent has labelled its own issue `needs-team-lead` without
   leaving notes, **then** that backstop appends an explanatory note pointing at the transcript,
   the same way it already does for an unexplained `needs-human`.
5. **Given** the `needs-human` label on an issue, **when** any of the five roles' automated polling
   for ready work looks for issues matching its `role:` label, **then** it still never claims or
   re-claims that issue - `needs-human` keeps its existing exclusion in the ready-work query
   unchanged.
6. **Given** the `needs-team-lead` label on an issue that also carries one of the five roles'
   `role:` labels, **when** that role's automated polling for ready work looks for issues matching
   its `role:` label, **then** it does not claim or re-claim that issue - the same exclusion
   `needs-human` gets today, extended to `needs-team-lead`, so a role doesn't restart work
   team-lead is already triaging.
7. **Given** a story whose issues are currently stalled behind a `needs-team-lead` label (not yet
   escalated further to `needs-human`), **when** po's automated in-flight-story throttle decides
   whether that story counts toward the WIP limit for starting new stories, **then** it is excluded
   from the count the same way a story stalled behind `needs-human` is excluded today.
8. **Given** the team-lead role itself is blocked, unsure, or cannot determine/fix the root cause
   of a `needs-team-lead` issue it is triaging, **when** it escalates, **then** it still labels the
   issue `needs-human` exactly as `agent-factory-dx0` specifies - this story does not change
   team-lead's own escalation label or behavior.

## Out of scope
- Any change to team-lead's own diagnose/reroute/escalate behavior (`agent-factory-dx0`).
- Retroactively relabelling any `needs-human` issues that already exist in the tracker from before
  this story ships - this story only changes which label future escalations use.
- Propagating this change into project `CLAUDE.md` copies that `bin/init-project.sh` has already
  written from `agents/CLAUDE.project.md` into other, already-initialized projects - this story
  only updates the source template and this project's own copy.
- team-lead's default model tier (`agent-factory-250`, already shipped) and tmux pane placement
  (`agent-factory-uhc`).
