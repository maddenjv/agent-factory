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
- All work for a story happens on the branch `story/<story-id>` (the `story:` label on your issue gives the id),
  except the design track (architect, then the engineer who implements it) and the write-tests track (qa's
  write-tests stage), which each work on their own branch cut from `story/<story-id>` - `story/<story-id>/design`
  and `story/<story-id>/tests` - merged back into `story/<story-id>` before the next stage needs the result. See
  your role prompt for exactly when to check out, create and merge each. If a branch exists on origin, check it
  out and `git pull`; if not, create it from its base (`origin/main` for `story/<story-id>`, PO only; otherwise
  `story/<story-id>`).
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
