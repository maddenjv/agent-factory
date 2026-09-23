# agent-factory-icv: Parallel design/implement and test-writing tracks, merged before review

## Story
As an agent-factory operator, I want the architect+engineer track and the qa test-writing track
to run in parallel (instead of qa waiting on the architect's design to close), with both tracks
merged together before a single reviewer stage that can send rework back to just the track that
was wrong, so that stories move through the factory faster without losing the isolation that lets
each role work from a clean git state.

## Context
Today `bin/new-story.sh` creates a strictly linear chain: `design(architect) -> tests(qa) ->
implement(engineer) -> verify(qa) -> review(reviewer)`, all five issues linked with `blocks`
dependencies, and every role commits to the same branch `story/<id>` (README "Flow", `bin/new-
story.sh`). qa's test-writing issue currently depends on the architect's design closing, even
though writing acceptance tests from the story's acceptance criteria doesn't require the design
doc to exist. The target shape (confirmed by John, 2026-09-23):
- qa keeps its two existing phases: **write tests** (from the story, not the design) and
  **verify** (run tests against the finished implementation, after engineer).
- Write-tests (qa) and design+implement (architect -> engineer) run in parallel, each on its own
  branch, merging into `story/<id>` before review.
- Verify (qa) depends on both implement and write-tests being done, since it needs the merged
  code and the merged tests.
- Reviewer rework is scoped to the track at fault: a design problem sends work back through
  architect -> engineer (qa's test-writing is left untouched); an implementation-only problem
  sends work back to engineer only (qa untouched); a test problem sends work back to qa, and if
  the corrected tests then fail against the implementation, that failure is what sends work back
  to engineer (design is untouched in both of the latter two cases).

This story covers the dependency-graph/branching change to the story chain (`bin/new-story.sh`
and whatever `agent-loop.sh` / role prompts need to honor per-track branches) and documenting the
new flow with a mermaid diagram in the README. It does not cover git implementation details left
to the architect's design (exact branch-naming scheme, merge-conflict handling).

## Acceptance criteria

1. **Given** a new story's stage chain is created, **when** the dependency graph is inspected
   (e.g. `bd show`), **then** the design (architect) issue and the write-tests (qa) issue have no
   dependency on each other, and both are ready as soon as the story exists (neither blocks the
   other).
2. **Given** the write-tests (qa) issue, **when** it is worked, **then** it is scoped to the
   story's acceptance criteria only — it does not require or reference `docs/design/<id>.md`.
3. **Given** the design (architect) issue, **when** the implement (engineer) issue is created,
   **then** implement depends only on design (not on write-tests), so engineer can start as soon
   as architect closes design, regardless of whether qa has finished writing tests yet.
4. **Given** both implement (engineer) and write-tests (qa) issues, **when** the verify (qa)
   issue is created, **then** verify depends on BOTH closing, and does not become ready until
   each has closed.
5. **Given** the verify (qa) issue, **when** the review (reviewer) issue is created, **then**
   review depends only on verify closing.
6. **Given** design+implement and write-tests are both in progress at the same time, **when**
   each role commits its work, **then** each track commits to its own branch (neither the shared
   `story/<id>` branch nor the other track's branch), so concurrent work on the two tracks cannot
   collide.
7. **Given** the design branch is complete (design issue closed), **when** engineer starts the
   implement issue, **then** engineer's work results in the design track's branch being merged
   into `story/<id>` (directly or via engineer's own branch merged in) before implement closes.
8. **Given** the write-tests branch is complete (write-tests issue closed) and implement has
   closed, **when** qa starts the verify issue, **then** qa's work results in the write-tests
   branch being merged into `story/<id>` before verify runs the tests against the merged code.
9. **Given** the reviewer finds a problem in the design, **when** the reviewer files rework,
   **then** the rework issue(s) target the architect (re-running design, which in turn re-runs
   implement), and no new issue or reopening is filed against the write-tests or verify work.
10. **Given** the reviewer finds a problem only in the implementation (design is sound), **when**
    the reviewer files rework, **then** the rework issue targets the engineer only, and no new
    issue or reopening is filed against the architect's design or qa's test-writing work.
11. **Given** the reviewer finds a problem in the tests, **when** the reviewer files rework,
    **then** the rework issue targets qa, the architect's design is left untouched, and if the
    corrected tests subsequently fail against the existing implementation during re-verify, that
    failure is what produces a new rework issue targeting the engineer (not a second round of qa
    rework).
12. **Given** `README.md`, **when** it is read, **then** it contains a mermaid diagram depicting:
    `po` feeding into a fork where `architect -> engineer` and `qa` (write tests) run in
    parallel, both merging before a single `reviewer` stage, with labelled arrows from
    `reviewer` back to `architect`, `engineer`, and `qa` representing the three rework paths
    from AC9-AC11.
13. **Given** the README's existing prose "Flow" section, **when** it is read, **then** it
    describes the parallel write-tests/design+implement tracks, the merge-before-review point,
    and the three rework paths — replacing the current description of a single linear
    `design -> tests -> implement -> verify -> review` chain.

## Out of scope
- The exact branch-naming scheme and merge mechanics (git commands, who runs `git merge` vs.
  relies on a script) — left to the architect's design, so long as AC6-AC8 hold.
- Merge-conflict resolution policy beyond what already exists for a single shared branch.
- Changing `WIP_LIMIT`, the `needs-human` escalation mechanism, or the 2-rework-round-to-
  `needs-human` circuit breaker (`README.md` "Flow" item 5) — unrelated to this story.
- Any change to how `HUMAN_APPROVE_STORIES=1`'s design-stage gate works.
