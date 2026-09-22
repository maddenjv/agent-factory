# agent-factory-jqn: .env per project

## Story
As an agent-factory operator running the kit against more than one project, I want each
project's own `.env` to be used when it exists, so that per-project settings (model choice,
budget caps, notification URL, etc.) don't leak across unrelated projects - while still getting
sensible defaults if a project hasn't set one up yet.

## Context
Today there is exactly one `.env`, created once by `bin/init.sh` at `$KIT_DIR/.env`
(`bin/init.sh:8-10`) and loaded by every role container via `docker-compose.yml`'s
`env_file: .env` (docker-compose.yml:53), which resolves relative to the kit's own compose file.
Because `docker-compose.yml` is shared by every project agent-factory is pointed at (see
`bin/lib.sh`'s `dc()`), all projects currently read and write the same kit-level `.env` - there is
no way to give one project a different `MODEL_ENGINEER`, `DAILY_BUDGET_USD`, `NOTIFY_URL`, etc.
without affecting every other project run from the same kit checkout.

`docs/ARCHITECTURE.md` and `bin/lib.sh` already establish the convention that a project's own
agent-factory state lives under `PROJECT_DIR/.agent-factory` (`DATA_DIR`), travelling with the
project rather than being buried in the kit. This story extends that convention to `.env`.

## Acceptance criteria

1. **Given** a project with its own `.env` present under that project's agent-factory data
   directory (`PROJECT_DIR/.agent-factory/.env`), **when** any role container is started for that
   project (`bin/start.sh` or equivalent), **then** the values from that project's `.env` are the
   ones in effect inside the container (verifiable via a setting like `MODEL_ENGINEER` that
   differs from the kit-level `.env`).
2. **Given** a project with no `.env` of its own, **when** a role container is started for that
   project, **then** the kit-level `$KIT_DIR/.env` is used as a fallback, unchanged from today's
   behaviour.
3. **Given** a project `.env` that only sets some variables, **when** a role container is
   started, **then** variables absent from the project `.env` do NOT silently fall back to the
   kit-level `.env`'s values for that same variable - the two files are not merged key-by-key,
   only one or the other is loaded (whichever the project has), so operators aren't surprised by
   values coming from a file they didn't edit.
4. **Given** a fresh project with neither a project-level nor a kit-level `.env` yet, **when**
   `bin/init.sh` is run, **then** it creates a starter `.env` from `.env.example` in the correct
   location for that project, same as today's "created .env, edit it and re-run" flow
   (`bin/init.sh:8-11`), so first-time setup isn't broken by this change.
5. **Given** an existing kit-level `$KIT_DIR/.env` from before this change, **when** a project
   that has never had its own `.env` continues to run, **then** it keeps working exactly as
   before with no manual migration step required.
6. **Given** the README's setup instructions, **when** read after this change, **then** they
   describe the per-project `.env` and the kit-level fallback, so operators managing more than
   one project know where to put project-specific settings.

## Out of scope
- Any change to what variables `.env`/`.env.example` contains, or their meanings/defaults.
- Merging or layering more than two `.env` sources (e.g. per-role `.env` files) - this story is
  project-level vs. kit-level fallback only, as requested.
- Changing where any other per-project state (`workspaces/`, `dolt/`, `logs/`, `claude/`) lives.
- Secrets management/encryption for `.env` contents - out of scope, unchanged from today.
