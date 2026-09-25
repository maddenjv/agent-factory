# agent-factory-zwn7: WIP limit yields when it would leave a role idle

## Story
As an agent-factory operator, I want the PO's `WIP_LIMIT` throttle to hold back only when every
downstream role (architect, engineer, qa, reviewer) already has work to do, so that a fixed story
count doesn't leave agents sitting idle while there is ready work the PO could unlock by starting
another story.

## Context
`bin/agent-loop.sh` throttles the PO with `WIP_LIMIT` (default 2, `.env.example`): `in_flight()`
counts open stories whose `role:reviewer` issue isn't yet closed (excluding stories stalled behind
a `needs-human`/`needs-team-lead` issue, per `agent-factory-8wq`), and `wip_ok()` stops the PO from
starting another story once that count reaches `WIP_LIMIT`. That count treats every in-flight
story the same regardless of which stage it's actually at. Because each story only has one (or,
for the parallel design/tests tracks added by `agent-factory-icv`, two) issue ready at a time, a
small `WIP_LIMIT` can leave several of the four downstream roles with nothing ready for their
`role:` label - e.g. both in-flight stories sitting in qa's verify stage, so architect, engineer
and reviewer are idle - while the PO, holding back purely on the story count, has no story left to
start that could reach those roles. The limit exists to stop the factory from taking on more than
it can handle, not to force agents to idle when there's a story the PO could start to feed them.

This is distinct from `agent-factory-8wq`, which excluded stories stalled on `needs-human` from
the count; that story explicitly left "applying the limit to roles other than the PO" out of
scope. This story doesn't change who the limit applies to (still only the PO) - it changes when
the limit actually holds the PO back, based on whether downstream roles are idle.

## Acceptance criteria

1. **Given** `WIP_LIMIT` in-flight stories (per the existing, `needs-human`/`needs-team-lead`-
   aware count) and at least one of architect/engineer/qa/reviewer currently has no ready issue
   for its `role:` label and no issue it's already claimed (in progress), **when** the PO's WIP
   check runs, **then** the PO is allowed to start a new story even though the in-flight count is
   at or above `WIP_LIMIT`.
2. **Given** `WIP_LIMIT` in-flight stories and every one of architect/engineer/qa/reviewer
   currently has a ready or in-progress issue for its `role:` label, **when** the PO's WIP check
   runs, **then** the PO is held back, exactly as today.
3. **Given** the PO was most recently held back because every downstream role had work, **when**
   a downstream role subsequently runs out of ready and in-progress work for its `role:` label,
   **then** the PO's next WIP check (at its normal polling cadence) allows a new story to start.
4. **Given** a story stalled behind a `needs-human` or `needs-team-lead` issue, **when** the WIP
   check computes both the in-flight count and each role's ready/in-progress work, **then** that
   story's stalled issue is excluded from both, unchanged from today's behaviour
   (`agent-factory-8wq`).
5. **Given** `WIP_LIMIT` slots are all filled by non-stalled stories and every downstream role
   also has ready or in-progress work, **when** the WIP check runs, **then** the PO is still held
   back - this story does not remove the limit, only adds the idle-role exception to it.
6. **Given** the operator reads `README.md` / `.env.example` for `WIP_LIMIT`, **when** they look
   it up, **then** the description states that the limit yields to keep every role busy - it
   holds the PO back only while architect, engineer, qa and reviewer all already have ready or
   in-progress work, not purely on story count.

## Out of scope
- Changing the default `WIP_LIMIT` value.
- Applying any new throttle to architect/engineer/qa/reviewer's own claiming of ready work - they
  already pull whatever's ready for their `role:` label; this story only changes when the PO's
  throttle holds the PO back.
- Any change to the `needs-human`/`needs-team-lead` stalled-story exclusion itself
  (`agent-factory-8wq`, `agent-factory-ulq`) - this story reuses it as-is.
- Autoscaling the number of running agent containers, or any change to how many issues a single
  role's agent works concurrently (still one at a time, per `bin/agent-loop.sh`).
