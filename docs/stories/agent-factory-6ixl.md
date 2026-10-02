# agent-factory-6ixl: bin/init.sh completes setup in one run

## Story
As an operator setting up agent-factory on a new project, I want a single `bin/init.sh` run to
finish initialisation (or tell me exactly what to do next), so that I am never left with a
half-initialised project, a failing re-run, and no built docker images.

## Context
On a fresh project, `bin/init.sh` creates `.agent-factory/.env` from `.env.example`, prints
"edit it ... then re-run bin/init.sh", and `exit 1` (bin/init.sh, the `[ ! -f "$AGENT_ENV_FILE" ]`
branch). Three problems follow:
- The default `.env` needs no edits (auth reuses the host `~/.claude` login), so the forced stop
  is usually pointless, and it exits non-zero with no follow-on instructions.
- The re-run then fails the "uncommitted changes" check, because `.agent-factory/` now exists
  untracked in the project and is not yet in the project's `.gitignore` (`bin/init-project.sh`
  only adds it later, after that check).
- The docker images are never built (`dc build agent`), so the factory is unusable.

Related: `docs/stories/agent-factory-jqn.md` AC4 requires the starter `.env` to be created from
`.env.example` at the project-level path; that stays true. This story changes only what happens
after it is created.

## Acceptance criteria
1. **Given** a clean git project with no `.agent-factory/`, **when** `bin/init.sh` is run once,
   **then** it creates `.agent-factory/.env` (identical in content to today's starter, per jqn AC4)
   and continues through to the end - docker images built, dolt started, project initialised -
   finishing with the "Done. Next: .../bin/start.sh" message and exit status 0.
2. **Given** that first run, **when** it creates the starter `.env`, **then** it prints where the
   file is and that optional settings (auth token, models, budget) can be edited there, with the
   instruction to re-run `bin/init.sh` afterwards if any were changed.
3. **Given** a clean git project in which `.agent-factory/` exists only because `bin/init.sh`
   created it (not yet listed in `.gitignore`), **when** `bin/init.sh` is run again, **then** it
   does not fail the uncommitted-changes check because of `.agent-factory/`.
4. **Given** a project with uncommitted changes other than `.agent-factory/`, **when**
   `bin/init.sh` is run, **then** it still refuses with the existing uncommitted-changes error and
   makes no scaffolding commit.
5. **Given** a project already initialised by a successful run, **when** `bin/init.sh` is run
   again, **then** it succeeds without error and leaves `.env` values intact (re-runs stay
   idempotent).
6. **Given** `--harness=<claude-code|copilot>` on the first run, **when** init continues past
   `.env` creation, **then** the chosen harness is recorded in `.env` and used for the image build.

## Out of scope
- Changing `.env.example` contents or variable meanings.
- Any change to what `bin/init-project.sh` scaffolds.
- Changing the kit repo's own `.gitignore`.
