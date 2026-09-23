# Design: agent-factory-0is — Sync AGENTS.md with CLAUDE.md conventions

## Approach

This is a content-sync fix, not new functionality. Root `AGENTS.md` (127 lines) has drifted from
root `CLAUDE.md` (98 lines): it still carries an old "Agent Instructions" intro and a
"Non-Interactive Shell Commands" section that no longer exist in `CLAUDE.md`, and it lacks all of
`CLAUDE.md`'s current project-conventions content (Tracker/Git/Files/Definition-of-done, Agent
Context Profiles, Session Completion). Both files already share an identical
`<!-- BEGIN BEADS INTEGRATION -->` ... `<!-- END BEADS INTEGRATION -->` managed block. `AGENTS.md`
additionally has a `<!-- BEGIN BEADS CODEX SETUP -->` ... `<!-- END BEADS CODEX SETUP -->` block
that `CLAUDE.md` does not have and that is explicitly out of scope to touch (story's AC3).

The fix: replace everything in `AGENTS.md` above its `<!-- BEGIN BEADS INTEGRATION -->` marker
with the current `CLAUDE.md` content from its start through its `<!-- END BEADS INTEGRATION -->`
marker (i.e. everything in `CLAUDE.md`, since that file ends right after that marker). Leave
`AGENTS.md`'s trailing `<!-- BEGIN BEADS CODEX SETUP -->` block completely untouched, appended
after the copied content.

No script or tooling is needed — this is a one-time manual sync of two markdown files performed
by the engineer with an editor/diff tool. There is no ARCHITECTURE.md change required (project
scaffold and conventions are unaffected; this story only touches the two convention files
themselves).

## Files to change

- `AGENTS.md` (repo root): replace lines 1 through the end of its own
  `<!-- END BEADS INTEGRATION -->` block with the full current content of `CLAUDE.md` (header
  through `CLAUDE.md`'s `<!-- END BEADS INTEGRATION -->` line — currently `CLAUDE.md` lines 1–98).
  Everything currently in `AGENTS.md` from `<!-- BEGIN BEADS CODEX SETUP -->` to
  `<!-- END BEADS CODEX SETUP -->` (currently lines 105–127) is preserved byte-for-byte,
  immediately following the newly-copied content.
- `CLAUDE.md`: unchanged. It is the source of truth for this sync; nothing here should need editing
  to satisfy this story's acceptance criteria. (If engineer finds `CLAUDE.md` itself has since
  drifted from this design doc's snapshot, that's a separate discrepancy — re-run `diff` and use
  whatever `CLAUDE.md` currently contains as the source, not this doc's quoted line numbers.)

## Data / interfaces

None — this is documentation content only, no code, no schemas.

## Error cases

- **Managed-block drift**: the `<!-- BEGIN BEADS INTEGRATION -->` block includes a `hash:` value
  in its opening comment (e.g. `hash:1105d646`). Copy it verbatim from `CLAUDE.md` — do not
  hand-edit or recompute it.
- **Trailing newline / whitespace mismatches**: after the edit, `diff AGENTS.md CLAUDE.md` should
  report differences *only* within the Codex block region (AC4). If `diff` shows whitespace-only
  noise elsewhere, fix it — it means the copy wasn't exact.
- **Accidental Codex-block edits**: since the Codex block sits immediately after the region being
  replaced, take care the replacement only touches lines above `<!-- BEGIN BEADS CODEX SETUP -->`
  in `AGENTS.md`. Verify with `diff` against the pre-change `AGENTS.md` (git diff) that the Codex
  block's lines are untouched.

## Acceptance criteria mapping

1. **AC1** (shared project-conventions content present in `AGENTS.md`, old intro/section gone):
   satisfied by replacing `AGENTS.md`'s pre-managed-block content with `CLAUDE.md`'s content.
2. **AC2** (managed Beads block matches): satisfied automatically since the replacement copies
   `CLAUDE.md` through its `<!-- END BEADS INTEGRATION -->` marker, which already matches
   `AGENTS.md`'s existing managed block — no separate edit needed there beyond the copy.
3. **AC3** (Codex block preserved unchanged): satisfied by leaving `AGENTS.md` lines 105–127 (the
   `BEADS CODEX SETUP` block) completely untouched.
4. **AC4** (`diff AGENTS.md CLAUDE.md` shows only the Codex block as remaining difference):
   satisfied as a consequence of 1–3. Engineer/QA should verify this literally with
   `diff AGENTS.md CLAUDE.md` at repo root after the edit — the only hunk should be the addition
   of the Codex block (present in `AGENTS.md`, absent from `CLAUDE.md`).

## Test strategy

This story has no executable code, so "tests" are documentation-content checks. QA should verify
via direct file inspection / shell commands, not a test framework:

1. `diff AGENTS.md CLAUDE.md` at repo root — the only difference must be the
   `<!-- BEGIN BEADS CODEX SETUP -->` ... `<!-- END BEADS CODEX SETUP -->` block existing only in
   `AGENTS.md` (covers AC4, and by construction AC1/AC2).
2. `grep -c "Agent Instructions" AGENTS.md` and `grep -c "Non-Interactive Shell Commands"
   AGENTS.md` both return 0 (covers AC1's "old content is gone" clause).
3. `grep -q "BEGIN BEADS CODEX SETUP" AGENTS.md` and the block's content still matches what it was
   before this change (compare against `git show story/agent-factory-0is~<pre-change>:AGENTS.md`
   or the copy quoted in this design doc) — confirms AC3 (untouched, not just present).
4. `grep -q "BEGIN BEADS INTEGRATION" AGENTS.md` and the hash comment matches `CLAUDE.md`'s exactly
   — confirms AC2.

No unit/integration test framework applies here since `docs/ARCHITECTURE.md` doesn't define one
for plain markdown content; these are acceptance-level file checks QA runs directly.
