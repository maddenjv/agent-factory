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
- Before closing an issue, leave a short note on it: what you did, what you decided and why.
- If you notice work outside your scope (a bug, a missing feature, tech debt), file a new issue and link it
  with `bd dep add <new> <current> --type discovered-from`. Do not fix other roles' work yourself.
- If you are blocked, unsure, or the input is wrong or under-specified: add a note explaining exactly what
  you need, run `bd label add <your-issue> needs-human`, and stop. A human will respond. Guessing is worse than stopping.

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
Either (a) your issue is closed with a note, or (b) it is labelled `needs-human` with a note explaining why,
or (c) you filed rework issues that block it and set it back to open (only qa and reviewer do this).
Anything else counts as a failed session.
