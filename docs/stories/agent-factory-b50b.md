# agent-factory-b50b: Multi-line alerts must age out of recent alerts

## Story
As an agent-factory operator watching the tmux board, I want a multi-line alert (such as the
GitHub Copilot "No authentication information found" preflight failure) to expire from "recent
alerts" together with its first line, so that a login failure from over a day ago doesn't stay on
the board.

## Context
`bin/agent-loop.sh` writes the first 200 characters of the harness's preflight output into the
`preflight: harness failed to run (check auth): ...` alert. Copilot's auth error contains
newlines, so one alert becomes several physical lines in `alerts.log`: a timestamped first line
followed by continuation lines with no timestamp or `[agent]` prefix.

`bin/board.sh` `recent_alerts` reads the last 6 physical lines and filters them per line. Only the
first line of an alert is subject to the age cutoff (agent-factory-47q) and the superseded-start
rule (agent-factory-wzg). Continuation lines don't match the log format, so they are "printed
unchanged" (47q AC6, fail visible) and never expire. The requester saw the Copilot login-failure
text still on the board more than a day after it was logged. Continuation lines also consume the
6-line tail window, which can push genuine alerts out of view.

## Acceptance criteria

1. **Given** a multi-line alert whose first line is older than the max age (or is otherwise
   dropped by an existing rule, e.g. superseded by a later start of the same agent), **when** the
   board refreshes, **then** none of its continuation lines appear in "recent alerts".
2. **Given** a multi-line alert whose first line is still shown, **when** the board refreshes,
   **then** its continuation lines are shown with it, in order.
3. **Given** a multi-line alert whose first line is a needs-human or usage-limit alert, **when**
   the board refreshes, **then** its continuation lines follow the same show/hide decision as its
   first line.
4. **Given** log lines at the very start of the tail window that have no preceding timestamped
   line in the window (a truncated alert), **when** the board refreshes, **then** they are shown
   as before (fail visible).
5. **Given** single-line alerts only, **when** the board refreshes, **then** behaviour is
   unchanged from 2do / 47q / wzg.
6. **Given** any of the above, **when** the board refreshes, **then** `alerts.log` on disk is
   unmodified.

## Out of scope
- Changing how alerts are written (e.g. collapsing newlines, truncation length) or the wording of
  any alert message.
- Changing the 6-line tail window size.
- Rewriting, rotating, or deleting `alerts.log`.
- Copilot authentication itself.
