# agent-factory-2do: Expire recent alerts

## Story
As an agent-factory operator watching the tmux board, I want the "recent alerts" panel to stop
showing alerts once the condition that raised them has resolved, so that the panel reflects
what's actually still wrong right now instead of noise from problems that already fixed
themselves.

## Context
`bin/board.sh` renders a "recent alerts" section by tailing the last 6 lines of
`$DATA_DIR/control/alerts.log` (bin/board.sh:15-16), an append-only text log written by
`alert()` in `bin/agent-loop.sh` (bin/agent-loop.sh:39-42). Every alert line is timestamped and
prefixed with the agent id, but the log has no notion of an alert being "resolved" - a line
stays in the tail window purely until 6 newer lines push it out, regardless of whether the
underlying problem is still real.

Looking at what `alert()` is actually called with (bin/agent-loop.sh:181,183,201,254,271,285,295,306),
two families of alert are raised for conditions that are known to self-resolve, and for which
agent-factory already has (or can derive) a way to check "is this still true right now":

- **needs-human alerts** ("`$id flagged needs-human ...`", "`$id not completed after N
  attempts; labelled needs-human`") - raised when an issue gets the `needs-human` label
  (bin/agent-loop.sh:181,183,201). This resolves the moment a human clears that label (or closes
  the issue), which `bd show <id>` already reports.
- **usage-limit / quota-wait alerts** ("`... usage limit hit (...); waiting Ns ...`",
  "`preflight: usage limit hit (...); waiting Ns ...`") - raised with an explicit wait duration
  computed by `usage_limit_wait_seconds` (bin/agent-loop.sh:254,295). This resolves once that
  wait window has elapsed after the alert's own timestamp.

Other alerts logged by `alert()` (circuit breaker stopping, daily budget reached, git sync
failing, cannot clone, preflight `claude` failure) don't have a comparably cheap, unambiguous
"still true?" check available today (e.g. "circuit breaker stopped the agent" isn't something
that un-happens) - this story leaves them as-is, still governed only by the existing tail-window
behavior.

## Acceptance criteria

1. **Given** a needs-human alert was logged for issue X, **when** the `needs-human` label is
   later removed from X (including by closing X), **then** that alert line no longer appears in
   the board's "recent alerts" section on the next refresh.
2. **Given** a needs-human alert was logged for issue X and X still carries the `needs-human`
   label, **when** the board refreshes, **then** the alert continues to appear (subject to the
   existing tail-window limit), unaffected by this change.
3. **Given** a usage-limit alert was logged with a wait duration N seconds, **when** the current
   time is past (alert timestamp + N seconds), **then** that alert line no longer appears in
   "recent alerts" on the next refresh.
4. **Given** a usage-limit alert was logged with a wait duration N seconds, **when** the current
   time has not yet reached (alert timestamp + N seconds), **then** the alert continues to
   appear.
5. **Given** alerts other than needs-human or usage-limit (circuit breaker, daily budget, git
   sync failure, clone failure, preflight failure), **when** the board refreshes, **then** they
   continue to appear exactly as today (no expiry logic applied to them).

## Out of scope
- Adding expiry/resolution logic for circuit-breaker, daily-budget, git-sync, clone, or
  preflight-failure alerts - they keep today's tail-only behavior.
- Rewriting, deleting, or rotating lines in `alerts.log` itself - only what the board *displays*
  changes; the on-disk log stays a complete, append-only history.
- Any change to how `alert()` decides to log something, `NOTIFY_URL` push notifications, or the
  format of existing alert messages (this story parses them, not changes them).
- A persistent/structured alert store (e.g. a database or JSON file) replacing `alerts.log`.
