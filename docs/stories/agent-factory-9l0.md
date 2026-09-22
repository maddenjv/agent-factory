# agent-factory-9l0: Use the invoking user's identity in agent containers

**Story**: As the person running agent-factory on my own machine, I want the containers it
builds and runs to use my actual username, UID and GID instead of a hardcoded `john`/`1000`
identity, so that file ownership on my host, HOME-relative paths inside the container, and the
tool's usability for anyone other than the original author all work correctly out of the box.

**Context**: `bin/init.sh` already derives `HOST_UID`/`HOST_GID` from `id -u`/`id -g` and writes
them into `.env` (`bin/init.sh:13`), and `docker-compose.yml` already passes them as build args
and runs the `dolt` service as `${HOST_UID:-1000}:${HOST_GID:-1000}`. What's still hardcoded is
the *username and home directory path* used for the `agent` service:

- `docker-compose.yml` (`agent` service volumes): five bind/named-volume mounts targeting
  `/home/john/.claude`, `/home/john/.claude-host`, `/home/john/.ai-dev-kit`,
  `/home/john/.ai-dev-kit-host`, `/home/john/.agents`, `/home/john/.agents-host`.
- `bin/agent-loop.sh` (`sync_dir` calls, around lines 231-233): the same `/home/john/...` paths
  used as sync sources/destinations inside the container.

These are the only hardcoded `/home/john` references inside this repository (agent-factory
itself); confirmed by repo-wide search excluding generated workspaces/data/snapshot dirs.

**Out of scope**: The container image itself (its `Dockerfile`, `useradd`, and default `HOME`)
lives in the sibling `claude-code-sandbox` repo, which is not part of this repository and was
not available to inspect while writing this story. If that image also hardcodes a `john`
username or `/home/john` home directory for the account it creates, that's a separate story in
that repo, out of this one's scope. This story only fixes agent-factory's own compose file and
scripts to stop assuming that path.

## Acceptance criteria

1. **Given** a host user whose username is not `john` (e.g. UID 1000 but a different login name,
   or a different UID/GID entirely), **when** they run `bin/init.sh` and start an agent
   container, **then** no step fails or silently mis-owns files due to a hardcoded `john`
   username or `/home/john` path.
2. **Given** `docker-compose.yml`'s `agent` service, **when** its volumes are defined, **then**
   none of the mount targets hardcode `/home/john/...`; the in-container home path is derived
   from the invoking host user (e.g. via an env var populated at init time, consistent with how
   `HOST_UID`/`HOST_GID` are already populated in `.env`).
3. **Given** `bin/agent-loop.sh`'s `sync_dir` calls for `.claude`, `.ai-dev-kit`, and `.agents`,
   **when** they run inside the container, **then** they use the same derived home path as the
   volume mounts in criterion 2, not a literal `/home/john`.
4. **Given** an existing project that already has a `.env` file from before this change,
   **when** `bin/init.sh` is re-run, **then** it fills in whatever new identity value(s) this
   story introduces (the same pattern used for `HOST_UID`/`HOST_GID` at `bin/init.sh:13`),
   without requiring the user to delete and recreate `.env`.
5. **Given** the change is complete, **when** grepping this repository (excluding
   `.agent-factory/`, `data/`, and other generated/runtime directories) for `john` or
   `/home/john`, **then** no matches remain in `docker-compose.yml` or `bin/*.sh`.
