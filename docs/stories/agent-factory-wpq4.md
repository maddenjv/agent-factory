# agent-factory-wpq4: `.env`'s `HOST_USER` (and friends) must actually reach the image build

**Story**: As an operator running agent-factory against a project whose `.env` records a
`HOST_USER` different from the literal string `agent`, I want `bin/init.sh`/`bin/start.sh` to
build and run the `agent` image with *that* username (and its `HOST_UID`/`HOST_GID`/
`CONTAINER_HOME`), so that the container account, its home directory, and host-bind-mount file
ownership match what `.env` says instead of silently falling back to defaults.

## Context

Story `agent-factory-76g` added `HOST_USER` (plus `HOST_UID`/`HOST_GID`/`CONTAINER_HOME`) to
`.env`, `Dockerfile` and `docker-compose.yml` so the container account mirrors the host user
instead of a hardcoded name. `docker-compose.yml`'s `agent.build.args` and volume mount defaults
reference these as Compose-file variable interpolation: `${HOST_USER:-agent}`,
`${HOST_UID:-1000}`, `${HOST_GID:-1000}`, `${CONTAINER_HOME:-/home/${HOST_USER:-agent}}`.

Compose resolves `${VAR}` interpolation in the compose file itself from the *host shell's actual
exported environment* (plus, separately, a `.env` file Compose auto-discovers next to the compose
file - i.e. `KIT_DIR/.env` - unless overridden with `--env-file`/`--project-directory`). This is a
different mechanism from the `env_file:` key on the `agent` service, which only injects variables
into the *container's* runtime process environment after the image is already built.

`bin/lib.sh` resolves a per-project `AGENT_ENV_FILE` (`docs/design/agent-factory-jqn.md`) and
exports the *path* to it, consumed by `docker-compose.yml`'s `env_file: ${AGENT_ENV_FILE:?...}`.
`bin/init.sh` writes `HOST_UID`/`HOST_GID`/`HOST_USER`/`CONTAINER_HOME` into that file, then calls
`dc build agent` (`bin/lib.sh`'s `dc()`, a thin `docker compose -f $KIT_DIR/docker-compose.yml`
wrapper) - but nothing ever loads those key/value pairs from `AGENT_ENV_FILE` into the actual host
shell environment, or passes `--env-file "$AGENT_ENV_FILE"` to Compose. `bin/start.sh`'s `pane()`,
`ops_cmd` and `board_cmd` have the same gap: each hand-builds a `docker compose run` command
string prefixed with `PROJECT_DIR=... KIT_DIR=... AGENT_ENV_FILE=... ROLE=...` (so tmux's child
process gets exactly those), but `HOST_UID`/`HOST_GID`/`HOST_USER`/`CONTAINER_HOME` are absent
from that prefix list too.

Net effect: Compose's `${HOST_USER:-agent}` etc. interpolation never sees the project's `.env`
values at all - it falls back to the compose file's own literal defaults (`agent`, `1000`,
`1000`) every time, regardless of what `bin/init.sh` wrote. `HOST_UID`/`HOST_GID` defaulting to
`1000`/`1000` happens to match many single-user Linux dev boxes, which is why this has gone
unnoticed; `HOST_USER` defaulting to the literal `agent` does not match almost anyone's actual
username, which is how this bug was noticed (`docs/design/agent-factory-76g.md`'s own AC7 wanted
no hardcoded name left anywhere, and one still is, functionally).

This is infra-only: `bin/lib.sh`, `bin/init.sh`, `bin/start.sh`, and whichever of
`docker-compose.yml`/docs need updating to describe the corrected flow. No new file, no new
service, no change to what `.env` *contains* - only to how its `HOST_UID`/`HOST_GID`/`HOST_USER`/
`CONTAINER_HOME` values actually reach Compose's own variable interpolation.

## Acceptance criteria

1. Given a project `.env` (`AGENT_ENV_FILE`) with `HOST_USER=alice`, `HOST_UID=1234`,
   `HOST_GID=1234` (no matching host user need actually exist), when `bin/init.sh` runs `dc build
   agent`, then the built image's account is `alice`, uid `1234`, gid `1234`, home `/home/alice`
   (verified the same way `agent-factory-76g`'s AC2 did: `id`/`echo $HOME` inside the image).
2. Given the same `.env`, when `bin/start.sh` spawns any of its three command strings (`pane()`'s
   per-role panes, `ops_cmd`, `board_cmd`), then the container each one starts also has account
   `alice`/`1234`/`1234`/`/home/alice` - not just the plain `dc build`/`dc run` path from AC1.
3. Given the same `.env`, when a role container writes a file into a host-bind-mounted path (e.g.
   `PROJECT_DIR`), then that file is owned by uid:gid `1234:1234` on the host (mirrors
   `agent-factory-76g`'s AC3, now with the value actually sourced from `.env` rather than
   coincidentally matching a default).
4. Given a project `.env` with no `HOST_USER`/`HOST_UID`/`HOST_GID`/`CONTAINER_HOME` set at all
   (a file predating `agent-factory-76g`, or one Compose is invoked against directly, bypassing
   `bin/lib.sh`), building/running `agent` still falls back to today's literal defaults (`agent`,
   `1000`, `1000`, `/home/agent`) rather than erroring - no regression for setups that never
   adopted these keys.
5. Given `HOST_USER=alice` etc. already applied to a running image (AC1), when `bin/init.sh` is
   re-run with no changes to `.env`, the rebuilt image is unchanged (idempotent - no new user
   created on top of the existing one, no ownership drift).
6. `README.md`'s Setup section and `docs/ARCHITECTURE.md`'s Stack section, which both currently
   describe `HOST_USER`/`HOST_UID`/`HOST_GID`/`CONTAINER_HOME` as flowing from `.env` into the
   image, are corrected if their description of *how* that happens turns out to be inaccurate
   given the fix (e.g. if lib.sh's `dc()` or start.sh's command strings change in a way that
   affects how an operator is expected to set/override these values).

## Out of scope

- Changing what `bin/init.sh` writes into `.env`, or the key names themselves (`HOST_UID`/
  `HOST_GID`/`HOST_USER`/`CONTAINER_HOME` stay as-is).
- Any change to `env_file:`/`AGENT_ENV_FILE` resolution precedence (`docs/design/
  agent-factory-jqn.md`'s project-vs-kit-level `.env` fallback) - that mechanism is correct for
  the container's *runtime* environment; this story is only about Compose's own build-time/
  mount-default variable interpolation.
- Handling a host username that's invalid for `useradd`, or a UID/GID that collides with an
  existing image group/user (already called out as out of scope in `agent-factory-76g`'s design).
- Any other `.env` key (`MODEL_*`, `NOTIFY_URL`, etc.) - those are only ever consumed via
  `env_file:` inside the container and are unaffected by this bug.
