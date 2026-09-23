# agent-factory-vzt: QA verifies the whole accumulated test suite to catch regressions

## Story
As an agent-factory operator, I want the qa agent's verify stage to run every acceptance test the
project has accumulated (not just the current story's) and treat a newly failing older test as a
regression defect, so that new code cannot silently reintroduce old bugs.

## Context
Each story leaves an acceptance test under `tests/` (`tests/<story-id>_test.sh`). `agents/qa.md`
stage:verify says "run the full test suite on this merged result", but does not say what that
means here or what to do when a test belonging to a *different* story fails. The motivating case:
the usage-limit handling in `bin/agent-loop.sh` (agent must wait for the quota reset rather than
fail; see agent-factory-stg) was reintroduced as a bug by later work, and nothing caught it.
Protecting that behaviour is done by keeping its story's acceptance test in `tests/` and running it
on every later story; this story makes that running systematic.

## Acceptance criteria

1. **Given** qa is verifying a story, **when** it follows its instructions, **then** it runs every
   test script under `tests/` (all stories', not only the current story's) on the merged
   `story/<story-id>` branch and records the per-script pass/fail results in its `bd comment`.
2. **Given** a test script belonging to a different, earlier story fails during verify, **when** qa
   handles it, **then** it files a `role:engineer,stage:rework` bug titled/described as a
   regression that names the failing script and the behaviour it protects, and does not close the
   verify issue.
3. **Given** a test from an earlier story fails because that story's intended behaviour was
   deliberately changed by the current story, **when** qa handles it, **then** the bug or a
   `needs-human` note states that explicitly rather than silently editing or deleting the old test.
4. **Given** all scripts under `tests/` pass, **when** qa closes the verify issue, **then** the
   handoff comment states how many scripts ran and that none failed.
5. **Given** a story that touches quota/usage-limit handling, **when** qa verifies it, **then** the
   usage-limit test from agent-factory-stg is among the scripts run (i.e. it is present in
   `tests/` on main once that story merges) and a failure of it is reported as a regression.

## Out of scope
- Changing the usage-limit behaviour itself (agent-factory-stg).
- Adding a CI system, test framework, or `make test` target.
- Test-suite speed-ups, parallel runs, or flaky-test handling.
- Any change to qa's stage:tests or stage:rework procedures.
