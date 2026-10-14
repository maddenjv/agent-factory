# agent-factory-4yvo: Catch merge conflicts with main before a story reaches review

## Story
As an agent-factory operator, I want a story branch that would conflict with `origin/main` to be
detected and sent back for resolution before the reviewer picks it up, so that the reviewer's
session is spent reviewing rather than discovering a conflict and filing rework.

## Context
Between 2026-09 and 2026-10 about a dozen rework issues were titled "Merge conflict: bring
story/<id> up to date with origin/main" (or "fix/<id> stale against origin/main"). Each one cost
a full reviewer session (find conflict, abort, file rework) plus an engineer/qa session to fix it,
and then a second review. Today (`agents/reviewer.md`, story `agent-factory-h71`) the conflict is
only discovered at merge time, at the very end of the chain. Main keeps moving while a story
sits in earlier stages, so the conflict usually existed well before review was reached.

The mechanism for resolving a conflict already exists: a `stage:rework` issue labelled
`merge-conflict`, routed to `role:engineer` (code, docs, or mixed) or `role:qa` (tests only).
This story is about *when* the conflict is noticed and *where* the work is sent, not how it is
resolved. How and where detection runs is the architect's call.

Only a real conflict counts. A branch that is merely behind `origin/main` but merges cleanly
needs nothing, and forcing a merge-up there would add churn rather than remove it. The same
applies to `fix/<issue-id>` branches that go straight to review.

## Acceptance criteria

1. **Given** a story whose review issue is about to become available to the reviewer, **and**
   `story/<id>` would conflict when merged into current `origin/main`, **when** the factory
   performs its pre-review check, **then** the reviewer does not get the review issue to work on
   until the conflict has been resolved, and a `stage:rework`, `merge-conflict` issue labelled
   `story:<id>` is filed.
2. **Given** such a conflict, **when** the rework issue is filed, **then** it is routed with the
   same rule the reviewer uses today (`role:qa` if every conflicting file is a test file,
   otherwise `role:engineer`) and its description names the conflicting files and the commits on
   each side.
3. **Given** the conflict has been resolved and `story/<id>` pushed, **when** the rework issue is
   closed, **then** the review issue becomes available to the reviewer again (re-checked, so a
   new conflict from main moving again repeats criteria 1-2 rather than slipping through).
4. **Given** `story/<id>` is behind `origin/main` but merges cleanly, **when** the pre-review
   check runs, **then** no rework issue is filed and the review issue proceeds normally.
5. **Given** `story/<id>` merges cleanly, **when** the check runs, **then** the branch on origin
   is not modified (detection never pushes or leaves a merge in progress anywhere).
6. **Given** the check has already filed a conflict rework issue for a story that is still open,
   **when** the check runs again, **then** no duplicate rework issue is filed.
7. **Given** a `fix/<issue-id>` merge-request issue (storyless path) is about to become available
   to the reviewer, **when** `fix/<issue-id>` would conflict with `origin/main`, **then**
   criteria 1-3 apply to it in the same way.
8. **Given** the check cannot run (for example `origin` is unreachable or the branch does not
   exist on origin), **when** it fails, **then** the failure is logged and the review issue is
   not blocked by it, so the check can never stall a story on its own.
9. **Given** the reviewer still hits a conflict at merge time (main moved after the check),
   **when** it merges, **then** the existing reviewer merge-conflict rework flow is unchanged.

## Out of scope
- Automatically resolving conflicts or merging `origin/main` into story branches.
- Proactively merging main into branches that are only behind (no conflict).
- Checking at stages earlier than the hand-off to review (design, tests, implement).
- Changing the reviewer's merge-time conflict handling or rework-attempt caps.
- Detecting semantic (non-textual) breakage from main moving.
