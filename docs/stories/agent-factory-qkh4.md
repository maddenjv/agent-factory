# agent-factory-qkh4: init.sh checks its dependencies up front

## Story
As an agent-factory operator setting up a project for the first time, I want `bin/init.sh` to
tell me clearly when Docker or Docker Compose is missing, so that I know exactly what to install
instead of decoding a misleading error.

## Context
`bin/lib.sh`'s `dc()` runs `docker compose -f ...`. When the Compose plugin is not installed,
Docker treats `compose` as an unknown command and the user sees an error about the `-f` flag not
being available, which says nothing about the real cause. `bin/init.sh` is the first script an
operator runs, so it is the right place to catch this before it touches the filesystem (it
already validates `--harness` early for the same reason).

## Acceptance criteria

1. **Given** the `docker` command is not installed, **when** `bin/init.sh` is run, **then** it
   exits non-zero with a message that names Docker as the missing dependency, and does not
   mention the `-f` flag.
2. **Given** `docker` is installed but the Compose plugin (`docker compose`) is not available,
   **when** `bin/init.sh` is run, **then** it exits non-zero with a message that names Docker
   Compose as the missing dependency, and does not mention the `-f` flag.
3. **Given** either dependency is missing, **when** `bin/init.sh` is run, **then** it creates
   nothing on disk (no `.agent-factory/` directory, no `.env`) and changes no files in the project.
4. **Given** Docker and Docker Compose are both available, **when** `bin/init.sh` is run,
   **then** behaviour is unchanged from today.
5. **Given** the README's setup instructions, **when** read after this change, **then** they list
   Docker with the Compose plugin as a prerequisite.

## Out of scope
- Checking other dependencies (git, bd, etc.) - this story covers Docker and Compose only.
- Supporting the legacy standalone `docker-compose` binary.
- Checks in scripts other than `bin/init.sh`, and checking that the Docker daemon is running.
- Installing the missing dependencies for the user.
