# agent-factory-whtf: Throttle verbosity on board

## Story
As a human watching `bin/board.sh`, I want the `-- throttle (po/architect) --` section to show
nothing when po/architect are not being held back, so that the board stays quiet when there's
nothing to look at and only draws my eye to it when something is actually throttled.

## Context
`agent-factory-q4tj` added team-lead's throttle judgment (`.agent-factory/control/throttle.json`,
written by `bin/set-throttle.sh`) and a `-- throttle (po/architect) --` board section
(`throttle_section()` in `bin/board.sh`) that always prints exactly one line, in every case:
- no `throttle.json` yet: `(no assessment yet - po/architect proceed unthrottled)`
- `idle:false`: `GO  (assessed <time>)  <reason>`
- `idle:true`: `IDLE  (assessed <time>)  <reason>`

In the steady state - which is most of the time, since po/architect are throttled only when
team-lead judges the downstream backlog too deep or quota too low - this section and its header
print unconditionally on every board render even though there's nothing actionable to show. The
request is to cut that down: only surface this section when po/architect are actually being held
back.

This only changes what `bin/board.sh` prints. It does not change `throttle.json`'s schema,
`bin/set-throttle.sh`, `bin/agent-loop.sh`'s `throttle_ok()`, or team-lead's judgment itself
(all from `agent-factory-q4tj`, documented in `docs/design/agent-factory-q4tj.md` and
`docs/ARCHITECTURE.md`).

## Acceptance criteria

1. **Given** `throttle.json` doesn't exist yet (team-lead hasn't made an assessment), **when**
   `bin/board.sh` renders, **then** the throttle section (including its `-- throttle (po/architect)
   --` header) does not appear anywhere in the output.

2. **Given** `throttle.json` records `idle:false` (po/architect are not being held back), **when**
   `bin/board.sh` renders, **then** the throttle section (including its header) does not appear
   anywhere in the output.

3. **Given** `throttle.json` records `idle:true` (po/architect are being held back), **when**
   `bin/board.sh` renders, **then** the output includes the `-- throttle (po/architect) --` header
   followed by the recorded reason and assessed-at time, in the same format as today's `IDLE
   (assessed <time>)  <reason>` line (or equivalent - the point is the reason stays visible when it
   matters, not the exact wording).

4. **Given** `throttle.json` exists but is unreadable/malformed (regression case already covered by
   `agent-factory-q4tj`'s tests), **when** `bin/board.sh` renders, **then** that failure is still
   surfaced (do not silently swallow a malformed-file error along with the "nothing to show" cases
   above) - only the genuinely-nothing-to-report cases (AC1, AC2) go silent.

## Out of scope
- Any change to `throttle.json`'s schema, `bin/set-throttle.sh`, `throttle_ok()`, or team-lead's
  assessment logic - this story only touches what `bin/board.sh` displays.
- Changing verbosity of any other `board.sh` section (`ready`, `in progress`, `blocked`,
  `needs-human`, etc.) - only the throttle section.
