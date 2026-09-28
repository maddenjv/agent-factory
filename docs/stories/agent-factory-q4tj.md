# agent-factory-q4tj: Team-lead decides when po and architect go idle, not a fixed WIP heuristic

## Story
As the agent-factory system, I want team-lead to decide when po and architect should stop
starting new stories - based on how large the engineer/qa/reviewer backlog has grown and how much
usage quota remains - instead of po applying a fixed `WIP_LIMIT`/idle-downstream-role heuristic on
its own, so that throughput is sized to keep the roles where most agent time is spent
(engineer/qa/reviewer) busy, and the factory doesn't start work it can't finish before quota or
budget runs out.

## Context
Today `bin/agent-loop.sh`'s `wip_ok()`/`in_flight()`/`idle_downstream_role()` throttle only `po`
(architect is never throttled) against a fixed `WIP_LIMIT` count of "stories with an open
`role:reviewer` issue," but let po proceed anyway if any of architect/engineer/qa/reviewer has no
ready-or-in-progress issue. This is a static bash heuristic with no visibility into actual backlog
depth or complexity, and no awareness of remaining usage quota. It also has a known accounting gap
(`agent-factory-gn4v`): a story sitting only on team-lead's `role:team-lead,needs-chain` issue (no
stage issue yet, post `agent-factory-x8wj`) counts toward neither check, so po could start one more
concurrent story than `WIP_LIMIT` intends during that window.

Human decision (2026-09-28, on `agent-factory-gn4v`, approved): rather than just patching the
accounting gap, move the decision itself off po's fixed rule and onto team-lead's judgment.
Team-lead should size throughput to keep engineer/qa/reviewer busy (where most agent time is
spent); po and architect - top-of-funnel - should go idle only when team-lead judges the
engineer/qa/review backlog has grown too large to justify starting more work, with team-lead
deciding what backlog size counts as "too large" rather than a hardcoded number. Team-lead should
also weigh remaining usage quota: don't start new stories the factory can't finish before
quota/budget runs out, favoring completion of in-flight work over starting new work.
`bin/agent-loop.sh` already has `budget_ok()`/`spent_today()`/`DAILY_BUDGET_USD` (a dollar spend
cap) and separate Claude Code plan usage-limit detection (`quota_hit_message`,
`usage_limit_wait_seconds`) - reuse or extend these rather than duplicating them.

This does not change what engineer/qa/reviewer do, and does not change the stage-chain sizing
`agent-factory-x8wj` already gave team-lead (which stages a story's chain includes) - it changes
who decides, and on what basis, whether po/architect keep pulling new top-of-funnel work at all.

## Acceptance criteria

1. **Given** team-lead judges the engineer/qa/reviewer backlog has room, **when** po or architect
   finishes its current issue and checks for more work, **then** it is allowed to claim and start
   another ready issue.

2. **Given** team-lead judges the engineer/qa/reviewer backlog has grown too large to justify
   starting more work, **when** po or architect would otherwise pick up a new ready issue,
   **then** it goes idle instead of claiming it. Engineer, qa, and reviewer are never idled by this
   policy - only po and architect are top-of-funnel here.

3. **Given** this decision is now team-lead's judgment call, **then** "too large" is not a fixed
   count of stories with an open `role:reviewer` issue or any other hardcoded number - team-lead
   assesses it per situation, the same way it already exercises judgment sizing a story's stage
   chain (`agent-factory-x8wj`).

4. **Given** remaining usage quota or budget is low enough that the factory is unlikely to finish
   additional new work before it runs out, **when** po or architect would otherwise start a new
   story, **then** team-lead's judgment holds them back from starting it, favoring completion of
   in-flight stories over starting new ones.

5. **Given** a story that currently has only team-lead's `role:team-lead,needs-chain` issue open
   (no design/tests/implement/verify/review issue yet exists for it), **when** team-lead assesses
   backlog size, **then** that story is accounted for as occupying capacity - it does not vanish
   from the assessment the way it does in today's `in_flight()`/`idle_downstream_role()`
   (`agent-factory-gn4v`'s bug is resolved as a consequence of this story, not patched separately).

6. **Given** team-lead's assessment changes over time (backlog shrinks, quota recovers, backlog
   grows), **when** po or architect next checks whether to start new work, **then** they act on
   the updated assessment - the decision is not a one-time snapshot fixed at some earlier point in
   the run.

7. **Given** po or architect is idle because of this policy, **when** a human inspects the running
   system (logs/alerts/`bd show`, or equivalent), **then** they can find a stated reason (backlog
   too large / quota too low) for the idling, not just silence - in the same spirit as today's
   `agent-loop.sh` `alert`/`log` calls, though not necessarily the identical mechanism.

## Out of scope
- The exact mechanism by which team-lead's decision reaches po/architect's loop (e.g. a new
  team-lead poll trigger, a control file, a bd label or synthetic issue) - that is architect's
  design call for this story.
- Any change to engineer/qa/reviewer's own throttling - they are never idled by this policy, only
  po/architect are.
- The existing dollar-based `DAILY_BUDGET_USD` pause (`budget_ok()`) or the Claude Code plan
  usage-limit wait behavior (`quota_hit_message`/`usage_limit_wait_seconds`) as mechanisms in their
  own right - this story is about whether po/architect start new work, and may read from these,
  but does not redesign them.
- A numeric formula or fixed rubric for "backlog too large" - deliberately a team-lead judgment
  call, the same way stage-chain sizing (`agent-factory-x8wj`) has no fixed rubric.
- Redesigning the five-stage chain or what counts as a story - unchanged from
  `agent-factory-x8wj`.
