# agent-factory-59gv: Lint tests for hard-coded dates

## Story
As an agent-factory maintainer, I want a check that flags hard-coded calendar dates in `tests/`
scripts, so that tests stop breaking later just because the clock moved on or a fixture date was
baked into an assertion, and the author is told at write time rather than at some later story's
verify stage.

## Context
About 54 fix/rework issues have the form "Regression: tests/<other-story>_test.sh fails" because
an older test hard-codes something incidental that a later story or the passage of time changed.
One recurring class is hard-coded timestamps/dates (e.g. `2026-09-23`, board-render timestamp
flake). Today `tests/` (both `tests/<story-id>_test.sh` and `tests/acceptance/<story-id>.sh`) has
no lint at all; QA's verify stage just runs every script. Other classes (stale wording, fixed
line-range extraction) are deliberately not covered here - this story picks the one mechanically
detectable class. Currently `tests/agent-factory-2do_test.sh` and `tests/acceptance/agent-factory-0is.sh`
contain a `2026-09-23` literal.

The check is a new script `bin/check-tests.sh`, run from the repo root, that scans every `*.sh`
file under `tests/` (recursively).

## Acceptance criteria

1. **Given** a `tests/` script containing a line with an ISO date literal (`YYYY-MM-DD`, with or
   without a trailing `THH:MM:SS` time) and no opt-out marker, **when** `bin/check-tests.sh` runs,
   **then** it exits non-zero and prints that file's path and line number on stdout or stderr.
2. **Given** a `tests/` script whose only date literals are on lines ending in the marker comment
   `# fixed-date-ok`, **when** `bin/check-tests.sh` runs, **then** those lines are not reported.
3. **Given** a `tests/` tree with no unmarked date literals, **when** `bin/check-tests.sh` runs,
   **then** it exits 0 and reports nothing as a violation.
4. **Given** several offending lines across several files, **when** the check runs, **then** every
   offending `path:line` is reported in one run (it does not stop at the first).
5. **Given** the repo at the end of this story, **when** `bin/check-tests.sh` runs against the real
   `tests/` directory, **then** it exits 0 and every existing test script still passes (existing
   hard-coded dates are replaced with computed values or, where a fixed date is genuinely the
   fixture, marked `# fixed-date-ok`).
6. **Given** the check's directory can be pointed elsewhere (e.g. `bin/check-tests.sh <dir>`),
   **when** run with a directory argument, **then** it scans that directory instead of `tests/`.
7. **Given** QA's verify stage description in `docs/ARCHITECTURE.md`'s Test strategy, **when** this
   story is done, **then** it states that `bin/check-tests.sh` must pass and documents the
   `# fixed-date-ok` marker.

## Out of scope
- Detecting stale wording, line-number/line-range extraction, or other brittle-assertion classes.
- Predicting which older tests a story's change will break.
- Wiring the check into the agent loop or git hooks automatically.
- Rewriting tests beyond the existing date literals.
