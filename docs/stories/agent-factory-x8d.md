# agent-factory-x8d: Restart implementation when a merge-conflict rework cannot be resolved

## Story
As an agent-factory operator, I want a story whose merge-conflict rework could not be resolved to
have its implementation redone from current `origin/main`, so that a hopelessly diverged story
recovers automatically instead of stalling on a human.

## Context
Follows agent-factory-h71: when the reviewer's merge of `story/<id>` conflicts, it files a
`stage:rework` conflict-resolution issue (engineer, or qa for test-only conflicts) and blocks its
review issue on it. That rework can fail: the assigned role may declare the conflict
unresolvable, or `agent-loop.sh` may hit `MAX_ATTEMPTS_PER_ISSUE` and label the rework issue
`needs-human`. Today that leaves the story stuck. Instead, the story's implementation is redone:
fresh `implement`, `verify` and `review` issues are created (same roles/labels as `new-story.sh`
produces), and the engineer re-implements from the existing `docs/design/<id>.md` on a branch
based on current `origin/main`. The design and tests stages are not repeated.

## Acceptance criteria

1. **Given** a conflict-resolution rework issue for a story, **when** the assigned role marks it
   unresolvable (with a note saying why), **then** the story is restarted (see 3-6) and the story
   is not left `needs-human`.
2. **Given** a conflict-resolution rework issue, **when** `agent-loop.sh` labels it `needs-human`
   because the attempt cap was reached, **then** the story is restarted (see 3-6) rather than
   left waiting for a human.
3. **Given** a story is restarted, **then** new `stage:implement` (`role:engineer`),
   `stage:verify` (`role:qa`) and `stage:review` (`role:reviewer`) issues labelled `story:<id>`
   exist, chained implement -> verify -> review, and the implement issue is immediately ready.
4. **Given** a story is restarted, **then** the previous implement, verify, review and
   conflict-rework issues for that story are closed with a reason referencing the restart, and
   none of them remains open or ready.
5. **Given** the new implement issue is picked up, **then** its description tells the engineer
   to start `story/<id>` again from current `origin/main` (discarding the old, conflicting
   implementation commits), implement per `docs/design/<id>.md`, and make the existing
   acceptance tests pass.
6. **Given** a story is restarted, **then** no new design or tests issue is created, and the
   restart is recorded with a `bd comment` on the new implement issue naming the old issues and
   the reason (unresolvable / attempt cap).
7. **Given** a story that has already been restarted once, **when** its conflict rework again
   cannot be resolved, **then** it is not restarted again; the new review issue is labelled
   `needs-human` with a note explaining the repeated failure.
8. **Given** a rework issue that is not a merge-conflict resolution (e.g. an ordinary
   request-changes rework), **when** it is labelled `needs-human` or unresolvable, **then** no
   restart happens and existing behaviour is unchanged.

## Out of scope
- Redoing design or tests stages, or restarting for failures other than merge conflicts.
- Changing how h71 files the conflict-rework issue.
- Automatically preserving or porting work from the discarded implementation.
