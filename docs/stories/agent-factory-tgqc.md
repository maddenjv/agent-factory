# agent-factory-tgqc: One-line alerts, and a cause on "not completed" alerts

## Story
As an agent-factory operator (or team-lead) triaging from `alerts.log`, I want every alert to be
exactly one line and the "not completed after N attempts" alert to say why the session failed, so
that I can understand a failure from `alerts.log` alone without opening transcripts.

## Context
`alert()` in `bin/agent-loop.sh` writes its message raw. Alerts that embed harness output
(e.g. `preflight: harness failed to run (check auth): ...`, usage-limit messages) can contain
newlines, so one alert becomes several physical lines: a timestamped first line plus orphan
continuation lines (e.g. `To authenticate, you can use any of the following m...`) and blank
lines. The log currently holds ~20 such blank/orphan lines. The board hides stale continuation
lines at display time (agent-factory-b50b); this story fixes them at the source.

Separately, `record_failure` raises `<id> not completed after N attempts; labelled <label>` once
the attempt cap is hit. 11 such alerts exist and none says what ended the session (non-zero
harness exit, crash, ended without closing/explaining, etc.), so the cause is only recoverable
from the transcript.

## Acceptance criteria

1. **Given** an alert message containing newlines (LF, CRLF, or lone CR), **when** it is logged,
   **then** `alerts.log` gains exactly one new line, in the usual `<timestamp> [<agent>] <text>`
   format, with each line break replaced by a single space.
2. **Given** an alert message with leading/trailing blank lines or consecutive blank lines,
   **when** it is logged, **then** no blank line is added to `alerts.log` and the message has no
   leading/trailing whitespace or repeated spaces from the collapsed breaks.
3. **Given** an alert message with no newlines, **when** it is logged, **then** the line written
   is identical to today's output.
4. **Given** a multi-line alert, **when** it is logged, **then** the copy in `loop.log` and the
   `NOTIFY_URL` notification text are also single-line (same text as in `alerts.log`).
5. **Given** an issue's session ends without the issue being completed and the attempt cap is
   reached, **when** the "not completed after N attempts" alert is raised, **then** that same
   single alert line also states the cause of the last failed session (at minimum the harness exit
   status when non-zero, or a stated "session ended without closing or explaining" when the
   harness exited cleanly).
6. **Given** the last session's harness output contains an error message, **when** the
   not-completed alert is raised, **then** the alert includes a truncated (bounded, e.g. ≤200
   characters), single-line excerpt of it.
7. **Given** a not-completed alert, **when** it is read, **then** it still begins with
   `<id> not completed after <N> attempts; labelled <label>` so existing parsers/board filters
   keep matching it.
8. **Given** the attempt cap has not been reached, **when** a session fails, **then** no alert is
   written (unchanged).

## Out of scope
- Rewriting, rotating, or cleaning up existing blank/orphan lines already in `alerts.log`.
- Changing the board's display filtering (agent-factory-47q, -wzg, -b50b).
- Changing attempt-cap logic, retry behaviour, or the notes appended to the issue (beyond what is
  needed to expose the cause to the alert).
- Adding a structured/JSON alert store.
