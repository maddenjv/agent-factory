# agent-factory-vfu3: A merge path for storyless fix work

## Story
As an agent-factory operator, I want small, storyless follow-up work (a doc correction, a
one-line test fix, anything filed `discovered-from` a closed issue that doesn't need its own
design/tests/implement cycle) to have a defined, documented way to reach `main`, so that such
work doesn't silently strand on an unmerged branch forever.

## Context
`docs/ARCHITECTURE.md` and `CLAUDE.md` define exactly one path to `main`: a `story/<story-id>`
branch that runs the full design (architect) -> tests (qa) -> implement (engineer) -> verify (qa)
-> review (reviewer) chain, built by `bin/new-story.sh`. `agents/reviewer.md` is written entirely
around that shape - it checks out `story/<story-id>`, reviews against
`docs/stories/<story-id>.md` and `docs/design/<story-id>.md`, and merges that branch.

In practice, agents doing small `discovered-from` follow-ups (fixing a stale doc, correcting a
test after a related story shipped) have converged on cutting a `fix/<issue-id>` branch from
`main`, pushing one commit, and closing their issue with a comment like "needs merge to main -
only the reviewer merges." Nothing is written down anywhere that tells the reviewer - or any
agent - that such a comment means anything, and `agents/reviewer.md` only ever looks at
`stage:review` issues carrying a `story:` label. The result: three single-commit branches
(`fix/agent-factory-367`, `fix/agent-factory-3lg`, `fix/agent-factory-wqd`), each already a
complete, working fix, sitting unmerged on `origin` with their originating issues already closed
- invisible to everyone, including the humans who'd otherwise notice.

Routing this kind of work through the full five-stage story chain would mean re-designing,
re-testing and re-implementing work that is already done and already correct, just to get a
green light to merge - the wrong amount of process for a single-commit fix. Instead, this story
adds a second, lightweight path to `main` for exactly this case, sitting alongside the existing
story path rather than replacing it: a real issue the reviewer can act on without a `story:`
label or a `docs/stories/<id>.md` file, that names the `fix/<issue-id>` branch to merge. Full
story treatment stays mandatory for anything that actually needs new design or new tests.

## Acceptance criteria

1. **Given** an agent has finished self-contained follow-up work on a `fix/<issue-id>` branch
   pushed to `origin` (no `story/<story-id>` involved), **when** they finish their session,
   **then** the documented convention has them file a real, actionable issue requesting the merge
   - not close their own issue with only a comment claiming it needs merging.
2. **Given** such a merge-request issue exists, **when** the reviewer looks for work, **then** it
   appears in the reviewer's normal queue alongside story review issues, without requiring a
   `story:` label or a `docs/stories/<id>.md` file to exist.
3. **Given** the reviewer picks up a `fix/<issue-id>` merge-request issue, **when** they review it,
   **then** they check the diff against `main` for the same correctness, security and code-quality
   bar as a story review (scaled to what a single small commit warrants), and either merge
   `fix/<issue-id>` into `main` and push, or send it back with a blocking finding - the same two
   outcomes available for a story review.
4. **Given** a completed, documented merge, **when** it lands, **then** the merged commit and the
   closed issue together leave a clear trail of what was merged and why (matching the existing
   story-review closing convention), even though no `story:` label is involved.
5. **Given** written project conventions (`CLAUDE.md`, `docs/ARCHITECTURE.md`, `agents/reviewer.md`
   as appropriate), **when** an agent reads them, **then** they can tell, without asking anyone,
   when storyless follow-up work is small enough for the `fix/<issue-id>` path versus when it must
   become a full story - and how to file the merge-request issue correctly either way.
6. **Given** the three already-stranded branches (`fix/agent-factory-367`, `fix/agent-factory-3lg`,
   `fix/agent-factory-wqd`), **when** this story is done, **then** each has either been merged to
   `main` via the new path or explicitly, visibly discarded (documented reason, branch deleted) -
   none is left silently stranded.
7. **Given** a future `discovered-from` issue that only needs a small, already-scoped fix, **when**
   an agent closes it, **then** the same documented path is available to get that fix to `main`
   without inventing a new convention on the spot.

## Out of scope
- Any change to the existing story chain (design -> tests -> implement -> verify -> review) or to
  `bin/new-story.sh` - it continues to be required for work that needs new design or new tests.
- Automated detection or linting that flags a stranded `fix/` branch - this story is about giving
  the convention a merge path and writing it down, not building monitoring for violations of it.
- Changing how `bd ready` / role-routing works for existing story-stage issues.
- Retroactively re-litigating whether the three stranded commits are individually correct - that
  was already decided when their original issues were reviewed and closed; this story only gets
  them (or an explicit decision not to) to `main`.
