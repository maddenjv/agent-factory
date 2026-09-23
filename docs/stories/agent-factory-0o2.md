# agent-factory-0o2: Board accuracy

## Story
As an agent-factory operator watching the tmux board, I want issues that are waiting on a human
(directly labelled `needs-human`, or blocked by an issue that is) kept out of the "ready" section
and visible in sections that reflect their real state, so that "ready" only ever lists work an
agent could actually pick up right now.

## Context
`bin/board.sh` renders "ready" by printing `bd ready --limit 50 --json` verbatim
(bin/board.sh:53-54) and "needs-human" by listing every open issue carrying the `needs-human`
label (bin/board.sh:55-56). `bd ready`'s blocking check is driven by dependencies, not labels: an
issue that itself carries `needs-human` but has no open blocking dependency is "ready" from bd's
point of view, so today it can appear in both the "ready" and "needs-human" sections at once -
implying an agent could claim it when a human response is actually required first. Issues that
depend on a `needs-human`-labelled issue are already excluded from `bd ready`'s output (an open
blocking dependency keeps them out), but the board currently has nowhere to show them - they just
vanish from the board entirely, giving no visibility into what's waiting and why.

## Acceptance criteria

1. **Given** an open issue carries the `needs-human` label, **when** the board renders, **then**
   that issue does not appear in the "ready" section (it appears only in "needs-human").
2. **Given** an open issue has an open, unresolved dependency on an issue that carries the
   `needs-human` label, **when** the board renders, **then** the dependent issue does not appear
   in the "ready" section.
3. **Given** an open issue has an open, unresolved dependency on an issue that carries the
   `needs-human` label, **when** the board renders, **then** the dependent issue appears in a new
   "blocked" section (shown between "needs-human" and "spend today"), identifying both the
   dependent issue and which `needs-human` issue it's waiting on.
4. **Given** the `needs-human` label is removed from a blocking issue (including by closing it),
   **when** the board next renders, **then** issues that depended on it no longer appear in
   "blocked" (and reappear in "ready" if they have no other open blockers).
5. **Given** an issue is blocked by an open dependency that does *not* carry the `needs-human`
   label, **when** the board renders, **then** that issue is excluded from "ready" exactly as
   today, and does not appear in the new "blocked" section (which is scoped to needs-human
   blocks only).
6. **Given** an issue is closed, **when** the board renders, **then** it never appears in
   "ready", "needs-human", or "blocked", regardless of any label it carries.

## Out of scope
- Changing what `bd ready` itself considers blocked, or any `bd` command behavior - this story
  only changes what `bin/board.sh` displays.
- A general "blocked" section covering every kind of blocking dependency - only blocks caused by
  a `needs-human`-labelled issue are in scope (see AC5).
- Transitive chains beyond one hop (an issue blocked by an issue that is itself blocked by
  needs-human, but not itself labelled needs-human) - out of scope; only direct dependencies on a
  needs-human-labelled issue are covered.
- Alert log expiry / "recent alerts" behavior - unrelated, already handled by
  agent-factory-2do.
