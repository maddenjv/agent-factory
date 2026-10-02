# agent-factory-7yn3: team-lead claims an escalated issue still assigned to the escalating role

## Story
As an agent-factory operator, I want team-lead to successfully claim and triage a
`needs-team-lead` issue that is still assigned to the build role that escalated it, so that team-lead
never loops on "could not claim" and the stuck story gets unstuck.

## Context
Observed: team-lead's loop logged `could not claim agent-factory-ar5n` and made no progress.
That issue is `in_progress`, assigned to `qa`, labelled `needs-team-lead`, `role:qa`,
`stage:verify`, `story:agent-factory-lv8s`, and its lease had expired (qa's last heartbeat was
tens of minutes old). This is exactly the case `agent-factory-rcjb` / `agent-factory-9awd` were
meant to cover (team-lead takes over the escalating role's stale claim; see
`docs/ARCHITECTURE.md`), yet the claim still fails. The root cause is not established (candidates:
the takeover condition in `claim()` in `bin/agent-loop.sh` not matching this assignee/label
shape, `bd update` refusing the takeover, a running loop on older code) and is for the architect to
find. `claim()` failing makes the loop sleep 5s and re-select the same issue, so one unclaimable
issue wedges team-lead, which also blocks every other triage item.

## Acceptance criteria
1. **Given** an `in_progress` issue assigned to `qa` (or any other build role) labelled
   `needs-team-lead` and the matching `role:<that role>` label, **when** team-lead next picks it
   up, **then** the claim succeeds, the issue is assigned to team-lead, and team-lead triages it.
2. **Given** the same issue whose assignee's lease has expired, **when** team-lead picks it up,
   **then** the claim succeeds (an expired lease never blocks takeover).
3. **Given** that same issue still carrying `stage:*` and `story:*` labels, **when** team-lead
   picks it up, **then** the claim succeeds (extra labels do not matter).
4. **Given** a `needs-team-lead` issue assigned to another live agent that is neither team-lead nor
   the escalating role, **when** team-lead looks for work, **then** it is still not taken (unchanged).
5. **Given** an issue team-lead genuinely cannot claim for any reason, **when** the claim fails,
   **then** the failure is logged with the reason and team-lead moves on to other triage work
   instead of retrying the same issue forever.
6. **Given** any of the above, **when** the fix is in place, **then** an automated test reproduces
   the failing scenario (including the exact assignee/label shape of agent-factory-ar5n) and passes.

## Out of scope
- Changing which issues team-lead selects for triage (`agent-factory-rcjb`).
- Lease or heartbeat timing changes for build roles.
- Deciding the `agent-factory-lv8s` verify issue itself (agent-factory-ar5n).
