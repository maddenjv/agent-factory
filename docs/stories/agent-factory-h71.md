# agent-factory-h71: Reviewer routes merge conflicts to rework instead of needs-human

## Story
As an agent-factory operator, I want a merge conflict hit by the reviewer to be sent back to the
engineer or qa as rework, so that routine conflicts with a moved `main` get resolved
automatically instead of stalling the story on a human.

## Context
Today `agents/reviewer.md` says that when approving and `git merge --no-ff story/<story-id>`
conflicts, the reviewer appends a note and labels its issue `needs-human`. The reviewer already
has a rework mechanism for "request changes": file a `stage:rework` issue for the at-fault role,
link it `discovered-from`, make the review issue depend on it, and set the review issue back to
open. Merge conflicts should reuse that mechanism. The engineer and qa rework prompts must
accommodate a rework issue whose request is "bring the story branch up to date with
origin/main and resolve conflicts" (rather than a code/test defect).

## Acceptance criteria

1. **Given** the reviewer approves a story and merging `story/<id>` into `main` conflicts,
   **when** the reviewer handles it, **then** it does not label its review issue `needs-human`.
2. **Given** such a conflict, **when** the conflicting files are all non-test code (or docs),
   **then** the reviewer files a `stage:rework` issue labelled `role:engineer,story:<id>`.
3. **Given** such a conflict, **when** the conflicting files are all tests, **then** the rework
   issue is labelled `role:qa`.
4. **Given** such a conflict, **when** the conflicting files include both code and tests,
   **then** the rework issue is labelled `role:engineer`.
5. **Given** the rework issue is filed, **then** its description names the conflicting files and
   the commits involved, and asks that `story/<id>` be brought up to date with `origin/main`
   with conflicts resolved and pushed.
6. **Given** the rework issue is filed, **then** it is linked `discovered-from` the review
   issue, the review issue depends on it, and the review issue is set back to open (same as
   request-changes).
7. **Given** the reviewer aborts the failed merge, **then** local `main` is left clean (no
   in-progress merge, nothing pushed to origin).
8. **Given** an engineer or qa session picks up a conflict-resolution rework issue, **when** it
   follows its prompt, **then** the prompt tells it to merge/rebase `origin/main` into
   `story/<id>`, resolve conflicts, re-run the test suite, and push the branch.

## Out of scope
- The fallback when the conflict cannot be resolved (separate feature request).
- Changing the existing request-changes flow or the 2-rework-issue `needs-human` cap, except as
  needed so conflict rework fits alongside it.
