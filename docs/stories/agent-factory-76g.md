# agent-factory-76g: Use the host username, UID/GID and home in the agent image

## Story
As an agent-factory operator on any machine, I want the agent container's account to take its
username, UID/GID and home directory from the host user who runs `bin/init.sh`, so that the kit
works unchanged for users not called `john` and nothing in the repo hardcodes one person's name.

## Context
UID/GID already come from the host (`HOST_UID`/`HOST_GID`, populated into `.env` by
`bin/init.sh`, passed as build args and as compose `user:`). The account *name* and home are still
fixed: the `Dockerfile` creates user `john` with home `/home/john`, `CONTAINER_HOME` defaults to
`/home/john` in `bin/init.sh`, `bin/agent-loop.sh` and `docker-compose.yml`, and `README.md` and
`docs/ARCHITECTURE.md` describe the account as `john`. Compose volume mounts and agent-loop's
host-config sync depend on the home path, so it must stay consistent with the account.

## Acceptance criteria

1. **Given** a host user named `alice` (uid 1234, gid 1234) with no existing `.env`, **when**
   `bin/init.sh` runs, **then** `.env` records the host username, UID and GID (`alice`, 1234, 1234)
   and a container home derived from that username (`/home/alice`).
2. **Given** `.env` from criterion 1, **when** `docker compose build agent` runs and then
   `docker compose run --rm --entrypoint bash agent -lc 'id -un; id -u; id -g; echo $HOME'`,
   **then** the output is `alice`, `1234`, `1234`, `/home/alice`.
3. **Given** that running container, **when** the agent writes a file into a host bind mount,
   **then** the file on the host is owned by the invoking host user.
4. **Given** the built image, **when** the agent starts, **then** the `.claude`, `.ai-dev-kit` and
   `.agents` volumes are mounted under the derived home and `bin/agent-loop.sh`'s host-config sync
   copies into that same home (no reference to `/home/john`).
5. **Given** the host user is `john` with uid/gid 1000 (the previous behaviour), **when** the same
   steps run, **then** the results are identical to before this change.
6. **Given** an existing `.env` that already has `HOST_UID`/`HOST_GID` and `CONTAINER_HOME` but no
   username, **when** `bin/init.sh` runs, **then** it adds the username without overwriting
   existing values.
7. **Given** the repository after this change, **when** searching `Dockerfile`, `docker-compose.yml`,
   `bin/`, `README.md` and `docs/ARCHITECTURE.md` for the literal `john` or `/home/john`, **then**
   there are no matches, and the docs describe the account as derived from the host user.

## Out of scope
- Changing how UID/GID are obtained or passed (already host-derived).
- Supporting users whose host username is invalid as a Linux account name (e.g. containing
  characters `useradd` rejects); no special handling required.
- Historical story/design docs under `docs/stories/` and `docs/design/`, and git history.
- Any Windows/macOS-specific behaviour beyond what `id -un`/`id -u`/`id -g` already give.
