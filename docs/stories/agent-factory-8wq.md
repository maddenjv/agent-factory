# agent-factory-8wq: Don't count stalled (needs-human) stories toward the PO's WIP limit

## Story
As an agent-factory operator, I want stories that are stalled on a `needs-human` issue to stop
counting toward the PO's WIP limit, so that the PO keeps starting new stories while agents would
otherwise sit idle waiting for me.

## Context
`bin/agent-loop.sh` throttles the PO with `WIP_LIMIT` (default 2, `.env.example`): `in_flight()`
counts every story whose `role:reviewer` issue is not closed, and `wip_ok()` stops the PO from
starting another while that count is at the limit. A story whose current issue is labelled
`needs-human` (or whose remaining issues are all waiting behind one, as shown in the board's
"blocked (waiting on a needs-human issue)" section) makes no progress until a human acts, yet it
still occupies a WIP slot. With two such stories, the whole factory idles.
"Blocked" here means only blocked behind a `needs-human` issue: ordinary dependency-chain
waiting (e.g. the review issue waiting on implement) is normal in-flight work and still counts.

## Acceptance criteria

1. **Given** `WIP_LIMIT=2` and two open stories, one of which has an open issue labelled
   `needs-human`, **when** the PO's WIP check runs, **then** only one story is counted and the PO
   is allowed to start a new story.
2. **Given** a story whose open issues are blocked (via dependencies) on an issue labelled
   `needs-human`, **when** the WIP count is computed, **then** that story is not counted.
3. **Given** a story whose open issues are progressing normally (none labelled `needs-human`, none
   waiting on one), including issues that are merely blocked by earlier stages of the chain,
   **when** the WIP count is computed, **then** it is counted, exactly as today.
4. **Given** a stalled story that a human has released (e.g. via `approve.sh`, removing
   `needs-human`), **when** the WIP count is next computed, **then** it counts toward the limit
   again.
5. **Given** `WIP_LIMIT` slots are all filled by non-stalled stories and other stories are
   stalled, **when** the WIP check runs, **then** the PO is still held back (the limit itself is
   unchanged).
6. **Given** the operator reads `README.md` / `.env.example`, **when** they look up `WIP_LIMIT`,
   **then** it states that stories stalled on `needs-human` are not counted.

## Out of scope
- Changing the default `WIP_LIMIT` value or applying the limit to roles other than the PO.
- Any change to how `needs-human` is set, cleared, or displayed (board, `approve.sh`).
- Auto-resuming or re-prioritising stalled stories.
