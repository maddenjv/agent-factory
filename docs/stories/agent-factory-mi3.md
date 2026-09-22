# agent-factory-mi3: Remove claude-code-sandbox dependency

## Story
As an agent-factory operator, I want the `agent` container image built entirely from within this
repo, so that I no longer need to clone and maintain a separate sibling repo (`../claude-code-sandbox`)
just to run the kit.

## Context
`docker-compose.yml` currently builds the `agent` service with `context: ../claude-code-sandbox`
(docker-compose.yml:45), relying on that sibling repo for the Claude Code CLI, the `bd` (beads) CLI,
and other toolchain pieces, plus a non-root user (`john`, home `/home/john`) built with matching
`HOST_UID`/`HOST_GID` build args.

Every place agent-factory actually runs this image already overrides its `ENTRYPOINT`
(`docker-compose.yml`'s `entrypoint: ["bash", "${KIT_DIR}/bin/agent-loop.sh"]`, and ad hoc
`--entrypoint bash` in `bin/init.sh`/`bin/start.sh`) rather than relying on the sandbox's own
entrypoint.sh. `agent-loop.sh` (bin/agent-loop.sh:220-225) already does its own sync of
`~/.claude`, `~/.ai-dev-kit` and `~/.agents` from read-only host mounts into each role's writable
config. So the only things this story needs to reproduce locally are: the installed toolchain
(Claude Code CLI, `bd`, git, jq, bash, and whatever else the agents invoke) and the non-root
`john` user with configurable UID/GID — not the sandbox's own entrypoint behavior.

README.md ("Setup" section) documents `../claude-code-sandbox` as a hard prerequisite and will
need updating once it's no longer required.

## Acceptance criteria

1. **Given** a clean checkout of agent-factory with no sibling `claude-code-sandbox` repo present,
   **when** `docker compose build agent` (or the equivalent `bin/init.sh`/`bin/start.sh` flow) is
   run, **then** the build succeeds without referencing any path outside this repo.
2. **Given** the built `agent` image, **when** a container is started from it, **then** `claude
   --version`, `bd --version`, `git --version` and `jq --version` all succeed inside the container.
3. **Given** the built `agent` image, **when** inspected, **then** the container's default user is
   non-root, has home directory `/home/john`, and its UID/GID match the `HOST_UID`/`HOST_GID`
   build args (same contract docker-compose.yml already sets for `HOST_UID:-1000`/`HOST_GID:-1000`).
4. **Given** the existing `agent-loop.sh` entrypoint override and the `~/.claude`,
   `~/.ai-dev-kit`, `~/.agents` host-sync mounts, **when** a role container starts, **then** the
   sync-and-run flow described in README.md's "Setup" section continues to work unchanged (no
   changes required to `bin/agent-loop.sh`'s sync logic itself).
5. **Given** the new build no longer depends on an external repo, **when** README.md's "Setup"
   section is read, **then** it no longer states `../claude-code-sandbox` as a required sibling
   checkout, and instead describes the self-contained build.

## Out of scope
- Changing agent-loop.sh's host-config sync logic, or any of the runtime polling/claim/session
  behavior of the agents themselves.
- Adding new agent capabilities/tools beyond what claude-code-sandbox already provided.
- Any change to how the `dolt` service is built or run.
- Publishing or vendoring the new Dockerfile as a reusable base image outside this repo.
