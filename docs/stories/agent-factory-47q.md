# agent-factory-47q: Time-based expiry for recent alerts

## Story
As an agent-factory operator watching the tmux board, I want alerts in the "recent alerts" panel
to age out after a fixed time, so that day-old alerts (e.g. a circuit-breaker stop or an expired
OAuth session from yesterday) don't sit on the board looking current.

## Context
Story agent-factory-2do added *resolution-based* expiry to `bin/board.sh` `recent_alerts`, but only
for needs-human alerts (label removed) and usage-limit alerts (wait elapsed). Every other alert
(circuit breaker, daily budget, git sync, clone failure, preflight `claude` failure) is shown
purely by the "last 6 lines of `alerts.log`" window, so with a quiet log they stay forever. The
requester observed a 2026-09-23 circuit-breaker alert and preflight auth failure still visible a
day later. This story adds a plain age cutoff for those remaining alerts.

## Acceptance criteria
1. **Given** an alert line (of a type not already governed by 2do's resolution rules) whose
   timestamp is older than the max age, **when** the board refreshes, **then** it does not appear
   in "recent alerts".
2. **Given** such an alert whose timestamp is within the max age, **when** the board refreshes,
   **then** it still appears, unchanged.
3. **Given** no configuration, **when** the board runs, **then** the max age is 1 hour.
4. **Given** the operator sets an environment variable `ALERT_MAX_AGE_MINUTES=N` (positive
   integer), **when** the board refreshes, **then** N minutes is used as the max age.
5. **Given** a needs-human or usage-limit alert, **when** the board refreshes, **then** its
   existing 2do behaviour is unchanged (a still-flagged needs-human alert is NOT hidden by age,
   since the issue still needs a human).
6. **Given** an alert line whose timestamp cannot be parsed, **when** the board refreshes, **then**
   it is shown as before (fail visible).
7. **Given** any of the above, **when** the board refreshes, **then** `alerts.log` on disk is
   unmodified and the existing 6-line tail window still applies.

## Out of scope
- Rewriting, rotating or deleting `alerts.log`.
- Changing which events are logged, alert message formats, or `NOTIFY_URL` notifications.
- Per-alert-type max ages, or resolution checks for circuit-breaker/budget/preflight alerts.
- Any change to needs-human or usage-limit expiry semantics.
