# Project conventions (shared by every agent)

You are one of five autonomous agents building this project: **po** (product owner), **architect**,
**engineer**, **qa**, **reviewer**. Nobody is watching in real time. Work is coordinated only through
Beads (`bd`) and git. Do exactly one assigned issue per session, then stop.

## Tracker
- All work lives in Beads. Never create TODO/plan markdown files.
- Run `bd prime` once at the start if you are unsure of exact CLI syntax (comments, labels, deps).
- Each story is a chain of issues: design (architect) -> tests (qa) -> implement (engineer) -> verify (qa) -> review (reviewer).
  Closing your issue hands the story to the next role automatically.
- Issue labels: `role:<who>`, `stage:<design|tests|implement|verify|review|rework>`, `story:<story-id>`.
- Before closing an issue, run `bd comment <your-issue> "<what you did, what you decided and why>"`
  - the next role (and any human skimming later) should be able to read the thread on an issue and
  understand what happened without reopening your session. Use `bd comment` for this kind of
  progress/handoff note; it's separate from the `--append-notes` note used below for `needs-human`.
- If you notice work outside your scope (a bug, a missing feature, tech debt), file a new issue and link it
  with `bd dep add <new> <current> --type discovered-from`. Do not fix other roles' work yourself.
- If you are blocked, unsure, or the input is wrong or under-specified: **before** labelling, run
  `bd update <your-issue> --append-notes "<exactly what you need from a human, and why>"` - specific
  enough that a human reading only `bd show <your-issue>` (no other context) knows what to answer -
  then `bd label add <your-issue> needs-human`, and stop. A human will respond. Guessing is worse
  than stopping. A `needs-human` issue with no note on it is not a valid way to end your session.

## Git
- You have your own clone; remote is `origin`. Only the reviewer merges to `main`.
- All work for a story happens on the branch `story/<story-id>` (the `story:` label on your issue gives the id).
  If it exists on origin, check it out and `git pull`; if not (PO only), create it from `origin/main`.
- Commit small and often, prefix messages with `[<issue-id>]`, and `git push origin story/<story-id>` after every commit.
  Anything not pushed is lost when your session ends.
- Stage explicit paths (`git add path/...`). Never `git add -A` / `git add .`, and never commit anything under `.beads/`.

## Files
- `docs/stories/<story-id>.md` - the user story + acceptance criteria (PO)
- `docs/design/<story-id>.md` - implementation design (architect)
- `docs/ARCHITECTURE.md` - project-wide stack, layout, conventions, test strategy (architect; keep it current)

## Definition of done for your session
Either (a) your issue is closed with a `bd comment` handoff note, or (b) it is labelled
`needs-human` with a `--append-notes` note explaining exactly what's needed (see Tracker, above),
or (c) you filed rework issues that block it and set it back to open (only qa and reviewer do
this). Anything else counts as a failed session.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:1105d646 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
