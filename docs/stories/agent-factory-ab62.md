# agent-factory-ab62: Team-lead releases its claim after routing an issue

## Story
As an agent in a downstream role queue, I want team-lead to release its claim on every issue it
has finished triaging, so that the issue shows up in my `bd ready` queue instead of sitting
claimed by team-lead and invisible to me.

## Context
`agents/team-lead.md` describes how team-lead triages issues: routing unrouted issues (no `role:*`
label) to a queue, rerouting `needs-team-lead` issues, and building stage chains for new stories.
To triage an issue team-lead has to claim it, which sets an assignee and puts it in progress.
A claimed issue is not returned by other roles' `bd ready`, so if team-lead routes an issue (adds
`role:*` / `stage:*` labels) but leaves its claim in place, the next role never picks it up.
In practice team-lead has been running `bd unclaim <id>` by hand after routing (see the comment on
agent-factory-ab62); this story makes that standard, documented behaviour rather than something
team-lead happens to remember.

## Acceptance criteria

1. **Given** team-lead has claimed an issue and routed it to a role queue (assigned a `role:*`
   label), **when** team-lead finishes its session on that issue, **then** the issue has no
   assignee and its status is open, and it appears in the target role's `bd ready`.
2. **Given** team-lead reroutes a `needs-team-lead` issue back to the role that owns the work,
   **when** it finishes, **then** the issue is unclaimed in the same way as in criterion 1.
3. **Given** team-lead has decided a story's stage chain and built it, **when** it finishes,
   **then** any issue team-lead itself claimed during that work (e.g. the chain-sizing issue, if
   left open) is not left claimed.
4. **Given** team-lead is about to end a session on an issue it is deliberately keeping (e.g.
   escalated to a human via `needs-human`, or closed), **when** it finishes, **then** no
   unclaim is required beyond that state's normal handling - the unclaim rule applies only to
   issues handed on to another role's queue.
5. **Given** `agents/team-lead.md`, **when** a reader looks for what team-lead does after routing
   an issue, **then** it states explicitly that team-lead must run `bd unclaim <id>` after routing
   so the next role can pick the issue up.

## Out of scope
- Changing how other roles claim or release issues.
- Automatic expiry or reaping of stale claims / leases.
- Changing the routing or triage rules themselves.
