# agent-factory-1aq: Install shellcheck in the agent image

## Story
As an agent-factory operator, I want `shellcheck` installed in the `agent` container image, so that
agents (engineer, qa, reviewer) can lint the `bin/*.sh` scripts from inside their containers.

## Context
`docs/ARCHITECTURE.md` expects `shellcheck` cleanliness for every bash script and tells QA to
`shellcheck` the diff, but the `agent` image (built from this repo's `Dockerfile`) does not
contain it, so agents cannot run that check. The image currently ships `claude`, `bd`, `git`,
`jq`, `curl` and `bash`.

## Acceptance criteria

1. **Given** a clean checkout, **when** `docker compose build agent` runs, **then** it succeeds.
2. **Given** the built image, **when** `docker compose run --rm --entrypoint bash agent -lc 'shellcheck --version'`
   runs, **then** it exits 0 and prints a shellcheck version banner.
3. **Given** the built image, **when** shellcheck is run inside the container against
   `bin/lib.sh` from this repo, **then** it executes and reports on the file (exit code reflects
   the lint result, not "command not found").
4. **Given** the built image, **when** the existing tools are checked (`claude`, `bd`, `git`, `jq`,
   `curl`) and the user/UID/GID are inspected, **then** all behave as before this change.

## Out of scope
- Wiring shellcheck into CI or into any script/agent workflow.
- Fixing any existing shellcheck warnings in `bin/*.sh`.
- Installing other linters or tools.
