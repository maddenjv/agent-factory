# agent-factory-rcjb: team-lead picks up every needs-team-lead issue, whatever else it carries

## Story
As an agent-factory operator, I want team-lead to triage every open issue labelled
`needs-team-lead` regardless of which `role:*`/`stage:*` labels or assignee it also carries, so
that a role that escalates without tidying up its labels doesn't leave the issue stuck in the
backlog forever.

## Context
Build roles are told to escalate with `bd label add <issue> needs-team-lead` (CLAUDE.md), and
they do so on issues that still carry their own `role:<x>` label - and may still be claimed
by them (assignee set, status in_progress). `bin/agent-loop.sh`'s `next_issue()` is meant to
treat `needs-team-lead` as team-lead's queue (`docs/ARCHITECTURE.md`), and the build roles' own
queues exclude such issues. Yet an issue labelled `needs-team-lead,role:po` has been observed
sitting in the backlog with nobody picking it up: the role queue skips it because of the
escalation label, and team-lead's poll is not surfacing it either. The exact cause is not
established (candidates: the assignee filter in team-lead's poll when the escalating role's claim
is still on the issue; the `--limit 200` window; other label/status conditions) and is for the
architect to find. This story is about the observable outcome.

## Acceptance criteria

1. **Given** an open issue labelled `needs-team-lead` and `role:<any role>` (e.g. `role:po`),
   unassigned, **when** team-lead next looks for work, **then** that issue is selected and
   triaged.
2. **Given** an open or in_progress issue labelled `needs-team-lead` that is still assigned to
   the role that escalated it, **when** team-lead next looks for work, **then** it is selected and
   triaged (the stale claim does not hide it).
3. **Given** an issue labelled `needs-team-lead` alongside `stage:*` and `story:*` labels,
   **when** team-lead next looks for work, **then** it is selected and triaged.
4. **Given** an issue labelled both `needs-team-lead` and `needs-human`, **when** team-lead
   looks for work, **then** it is still not selected (unchanged).
5. **Given** an issue labelled `needs-team-lead` that another live agent (not team-lead and not
   the escalating role) is actively working, **when** team-lead looks for work, **then** it does
   not steal it - unchanged, unless the architect finds the assignee rule must change, in which
   case the design says so explicitly.
6. **Given** a `needs-team-lead` issue that team-lead has triaged (label cleared and rerouted),
   **when** the role it was rerouted to looks for work, **then** it is picked up by that role's
   normal queue.
7. **Given** any of the above scenarios, **when** the fix is in place, **then** an automated
   test in `tests/` reproduces the previously stuck case and fails without the fix.

## Out of scope
- Changing what team-lead does once it has picked an issue up (`agents/team-lead.md`).
- Changing the no-`role:*` or `needs-chain` triage paths.
- Making build roles clear their own claim/labels before escalating (may be a design choice, but
  team-lead must be robust to it not happening).
