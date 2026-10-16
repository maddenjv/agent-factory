# agent-factory-4sxw: Wait until the quota reset time when the message has no minutes

## Story
As an agent-factory operator, I want an agent that hits the usage limit to sleep until the
quota's stated reset time even when that time is written as a bare hour (e.g. "resets 7pm
(UTC)"), so that agents stop waking and retrying every `QUOTA_RETRY_INTERVAL` (900s) for hours
when the reset time is already known.

## Context
`usage_limit_wait_seconds` in `bin/agent-loop.sh` turns a usage-limit message into a sleep
duration. It only recognises clock times written with minutes (`H:MMam/pm`, e.g. "resets
5:50pm"). When the CLI says "hit your session limit · resets 7pm (UTC)" - hour only, no
minutes - nothing matches and the function falls back to polling every `QUOTA_RETRY_INTERVAL`
(900s). The team-lead log on 2026-10-15 shows exactly this: `usage limit hit (hit your session
limit · resets 7pm (UTC) ); waiting 900s`. The same wait function is used by the preflight
check and by both in-run quota hits, so all three paths share the defect.

Existing behaviour that must be preserved: `H:MM` times keep working; a reset that passed less
than 10 minutes ago retries after 60s; a reset already passed earlier today rolls to tomorrow;
a 60s buffer is added past the reset; a message with no parseable time falls back to
`QUOTA_RETRY_INTERVAL`.

## Acceptance criteria
1. **Given** a usage-limit message containing an hour-only time such as "resets 7pm (UTC)" and
   a current time of 15:00 UTC, **when** the agent computes how long to wait, **then** the wait
   is until 19:00 plus the existing 60s buffer (14460s), not `QUOTA_RETRY_INTERVAL`.
2. **Given** an hour-only "12am" or "12pm" message, **when** the wait is computed, **then** 12am
   is treated as 00:00 and 12pm as 12:00.
3. **Given** an hour-only time that passed less than 10 minutes ago, **when** the wait is
   computed, **then** the wait is 60s; **given** one that passed earlier today by more than 10
   minutes, **then** the wait runs until that time tomorrow (plus buffer).
4. **Given** a message with minutes (e.g. "resets 5:50pm"), **when** the wait is computed,
   **then** the result is the same as before this change.
5. **Given** a message with no clock time at all, **when** the wait is computed, **then** the
   wait is `QUOTA_RETRY_INTERVAL`.
6. **Given** an agent hits the limit with an hour-only reset message, **when** it logs the
   quota alert, **then** the alert's "waiting Ns" shows the computed wait rather than 900s.

## Out of scope
- Time zones other than the container's local time (UTC by default); an explicit "(UTC)" label
  keeps being treated as local time as today.
- Date-bearing reset formats (e.g. "resets Oct 17, 7pm") and 24-hour clock formats.
- Changes to the po/architect throttle assessment or to `QUOTA_RETRY_INTERVAL` itself.
