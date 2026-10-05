# agent-factory-zf0i: a role picks up work team-lead routed to it, even if team-lead left its claim on it

## Story
As an agent-factory operator, I want an issue that team-lead has routed to a role (by giving it a
`role:<x>` label) to be picked up by that role even when team-lead forgot to `bd unclaim` it, so
that a missed unclaim cannot silently strand work.

## Context
team-lead's session is started with the issue claimed (assignee `team-lead`, in progress). After it
adds a `role:<x>` label it is supposed to `bd unclaim` (`agents/team-lead.md`, "Release your claim
when you hand an issue on"). When it doesn't, the issue stays assigned to team-lead and in progress,
so it is invisible to the target role's `bd ready` and `next_issue()` in `bin/agent-loop.sh` never
returns it. Observed on this very issue: team-lead routed it to `role:po` but left its claim, and po
did not pick it up. The inverse case already has a safety net (`agent-factory-rcjb`: team-lead takes
over a build role's stale claim on a `needs-team-lead` issue); this story adds the mirror image.

## Acceptance criteria
1. Given an open issue assigned to `team-lead`, labelled `role:<x>` (x any of po, architect,
   engineer, qa, reviewer) and neither `needs-team-lead`, `needs-chain` nor `needs-human`, and
   whose blockers are all closed, when role x's loop looks for work, then it claims and works the
   issue.
2. Given the same issue, when role x claims it, then the assignee becomes role x's agent id and
   the issue is in progress (no leftover team-lead claim).
3. Given an issue assigned to `team-lead` that carries `needs-team-lead` or `needs-chain`, when
   any non-team-lead role looks for work, then it does not take the issue.
4. Given an issue assigned to anyone other than `team-lead` or the role itself (e.g. another
   role's agent), when role x looks for work, then it does not take the issue (existing behaviour
   preserved).
5. Given an issue assigned to `team-lead` with `role:<x>` that is still blocked by an open
   dependency, when role x looks for work, then it does not take the issue.
6. Given a team-lead session that is currently running on an issue, when that issue carries a
   `role:<x>` label, then role x does not take it out from under the running session.
7. Given a takeover that fails, then the failure is logged and the issue skipped for a while,
   as with other failed claims, rather than retried every cycle.

## Out of scope
- Changing team-lead's prompt or making team-lead's unclaim step more reliable.
- Takeover of claims held by roles other than team-lead.
- Any change to how team-lead picks up its own work.
