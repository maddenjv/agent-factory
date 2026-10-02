# agent-factory-lv8s: Stale multi-line alert tail shown in "recent alerts"

## Story
As an agent-factory operator watching the tmux board, I want a multi-line alert whose first line
has aged out or been superseded to disappear from "recent alerts" in full, so that leftover
fragments of an old, long-resolved alert (for example a Copilot auth error on a claude-code
factory) don't look like a current problem.

## Context
The requester runs the `claude-code` harness yet saw "Copilot can be authenticated with GitHub
using an OAuth Token or a Fine-Grained Personal Access Token." under "recent alerts".

Investigation of `alerts.log`: that text is the tail of a "preflight: harness failed to run (check
auth)" alert logged 2026-09-29 by five agents while the factory was started on the `copilot`
harness. The harness error output is multi-line, so each such alert spans several log lines, only
the first of which carries the timestamp/agent header. `bin/board.sh`'s `recent_alerts` reads the
last 6 physical lines of `alerts.log`; when that window begins in the middle of an old multi-line
alert, the headerless continuation lines have no timestamped line to inherit visibility from, and
agent-factory-b50b's "truncated alert" rule prints them ("fail visible"). Result: three days later,
with only unrelated newer alerts behind it, the orphaned tail of an old alert is displayed
indefinitely, regardless of age (agent-factory-47q's age cutoff) or restart (agent-factory-wzg).

The harness setting itself is not the problem here; this story is about the board not showing
fragments it cannot attribute to a current alert.

## Acceptance criteria

1. **Given** the last lines of `alerts.log` include continuation lines (no timestamp/agent header)
   of a multi-line alert whose header line lies before the displayed window, and the alert is older
   than the age limit (default 60 minutes), **when** the board refreshes, **then** none of those
   continuation lines appear in "recent alerts".
2. **Given** the same situation but the alert is still younger than the age limit and not
   otherwise resolved, **when** the board refreshes, **then** the alert is still visible and its
   header line is shown with it (the operator is never shown only a headerless fragment).
3. **Given** a multi-line alert whose header is in the window and has aged out or been
   superseded, **when** the board refreshes, **then** its continuation lines are hidden along with
   the header (existing behaviour preserved).
4. **Given** a multi-line alert whose header is in the window and is still current, **when** the
   board refreshes, **then** header and continuation lines are all shown (existing behaviour
   preserved).
5. **Given** a long multi-line alert is the most recent entry in `alerts.log` and is still
   current, **when** the board refreshes, **then** its full text, including the header, is shown
   and not cut off by the size of the window onto the log.

## Out of scope
- Changing how the harness is selected or validated (`bin/init.sh`, `HARNESS`).
- Changing the wording or length of preflight error alerts, or the 60-minute age default.
- Resolution rules for needs-human, usage-limit and preflight alerts beyond the above.
