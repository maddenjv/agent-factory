# agent-factory-0is: Sync AGENTS.md with CLAUDE.md's current project conventions

## Story
As an agent-factory operator running agents on tools that read `AGENTS.md` instead of
`CLAUDE.md` (e.g. Codex), I want `AGENTS.md` to describe the same project conventions as root
`CLAUDE.md`, so that an agent's behavior doesn't depend on which convention file its tool happens
to read.

## Context
Root `CLAUDE.md` was rewritten to describe the current five-agent Beads/git workflow (the
Tracker/Git/Files/Definition-of-done sections, Agent Context Profiles, and Session Completion
protocol). Root `AGENTS.md` was never updated to match: it still has an old generic "Agent
Instructions" intro, a "Non-Interactive Shell Commands" section (`cp -f`/`mv -f`/`rm -f` advice)
that no longer exists in `CLAUDE.md`, none of `CLAUDE.md`'s current project-conventions content,
and an extra "BEGIN BEADS CODEX SETUP" block that `CLAUDE.md` doesn't have.

`CLAUDE.md`'s own text says: "AGENTS.md and CLAUDE.md are independent files (not symlinked and
not sharing an inode). Mirror substantive edits across both, or symlink one to the other." That
mirroring never happened after `CLAUDE.md`'s rewrite (confirmed via `diff AGENTS.md CLAUDE.md` at
repo root, 2026-09-23).

This story covers only root `AGENTS.md` and root `CLAUDE.md`. It does not cover the per-workspace
`CLAUDE.md` files under `.agent-factory/workspaces/<role>/` (e.g. this file's own workspace),
which are separate, role-specific copies outside this story's scope.

## Acceptance criteria

1. **Given** root `CLAUDE.md`'s current project-conventions content (the header through the
   Definition-of-done section, i.e. everything above the "BEGIN BEADS INTEGRATION" marker),
   **when** root `AGENTS.md` is read, **then** it contains the same project-conventions content
   (the old "Agent Instructions" intro and "Non-Interactive Shell Commands" section are gone).
2. **Given** the "BEGIN BEADS INTEGRATION" / "END BEADS INTEGRATION" managed block in root
   `CLAUDE.md`, **when** root `AGENTS.md` is read, **then** it contains the same managed block
   content.
3. **Given** root `AGENTS.md` previously had a "BEGIN BEADS CODEX SETUP" / "END BEADS CODEX
   SETUP" block not present in `CLAUDE.md`, **when** root `AGENTS.md` is read after this story,
   **then** that block is preserved unchanged and still present (Codex-specific setup content,
   out of scope to remove or merge into `CLAUDE.md`).
4. **Given** both files after this change, **when** `diff AGENTS.md CLAUDE.md` is run at the repo
   root, **then** the only remaining difference is the Codex-specific block described in
   criterion 3 (no drift in the shared project-conventions or Beads-integration content).

## Out of scope
- Changing the substance of any convention (this is a sync/mirroring fix, not a policy change).
- Updating per-workspace `CLAUDE.md` files under `.agent-factory/workspaces/*/`.
- Deciding whether to symlink one file to the other instead of mirroring content (that's a
  separate architectural decision `CLAUDE.md` explicitly leaves open; this story just fixes the
  drift using the mirroring approach already in place).
- Changes to `bd setup codex` or whatever tooling generates the "BEADS CODEX SETUP" block.
