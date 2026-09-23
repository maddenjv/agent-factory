# agent-factory-6k7: Document CONTAINER_HOME and correct the container-identity description

## Story
As an agent-factory operator reading README.md's "Setup" section or docs/ARCHITECTURE.md's
"Stack" section, I want an accurate, complete description of how the agent container's user
identity and home directory are determined, so that I understand what `HOST_UID`/`HOST_GID`/
`CONTAINER_HOME` actually control before I try to change any of them.

## Context
`docs/ARCHITECTURE.md`'s Stack section (line 19) currently states the agent container "Runs as a
non-root user `john`, home `/home/john`" as a flat, unconditional fact. As of this review that's
still accurate for the account the `Dockerfile` actually creates (`Dockerfile:30`,
`groupadd`/`useradd john`, home `/home/john`, `ENV HOME=/home/john`) — the Dockerfile is
self-contained per its own header comment and does not read `CONTAINER_HOME` at all, only
`HOST_UID`/`HOST_GID` build args.

Separately, `docker-compose.yml` (lines ~69-77), `bin/init.sh` (line 19), and
`bin/agent-loop.sh` (line 29) all reference a `CONTAINER_HOME` env var, defaulting to
`/home/john`, auto-populated into `.env` by `init.sh` alongside `HOST_UID`/`HOST_GID`. It is used
in two places: as the mount target prefix for the `.claude`/`.ai-dev-kit`/`.agents` volumes in
`docker-compose.yml`, and as the base path `agent-loop.sh` syncs those host configs into at
startup. `docker-compose.yml`'s own comment on the mount block is explicit that this isn't a
free-standing "change the container's home" knob: "`CONTAINER_HOME` ... must match the image's
actual account home" — i.e. changing it without also editing the `Dockerfile`'s hardcoded `john`/
`/home/john` account would break the mounts.

Today's docs describe none of this: README's "Setup" section states the container user is
`john` with no mention of `CONTAINER_HOME` at all, and ARCHITECTURE.md's Stack section states the
home path as an unconditional fact rather than "the Dockerfile-created account's home, which
`CONTAINER_HOME` must be kept in sync with if ever changed." A reader who notices the
`CONTAINER_HOME` variable in `.env` (created by `init.sh`) has no documented reason to believe
it's constrained rather than freely overridable.

## Acceptance criteria

1. **Given** docs/ARCHITECTURE.md's Stack section, **when** it describes the agent container's
   user, **then** it states that the account (`john`, UID/GID from `HOST_UID`/`HOST_GID` build
   args, home `/home/john`) is fixed by the `Dockerfile`, and that `CONTAINER_HOME` (env var,
   default `/home/john`) is a separate, dependent setting used only for the `docker-compose.yml`
   mount paths and `agent-loop.sh`'s host-config sync — not an independent way to relocate the
   account's home without also editing the `Dockerfile`.
2. **Given** README.md's "Setup" section, **when** it describes the container user, **then** it
   mentions `CONTAINER_HOME`'s existence, its default, and that `bin/init.sh` auto-populates it
   into `.env` alongside `HOST_UID`/`HOST_GID` — consistent with what ARCHITECTURE.md now says.
3. **Given** the corrected docs, **when** compared against the current `Dockerfile`,
   `docker-compose.yml`, `bin/init.sh`, and `bin/agent-loop.sh`, **then** no other statement in
   README.md's "Setup" section or ARCHITECTURE.md's Stack section contradicts current behavior in
   those four files (a full read-through of both sections against the four files, correcting any
   other drift found, not just the `CONTAINER_HOME`/user-identity item above).
4. **Given** the corrected docs, **when** read on their own, **then** they do not claim or imply
   that `CONTAINER_HOME` can be changed safely on its own without touching the `Dockerfile`.

## Out of scope
- Changing any actual runtime behavior, defaults, or the `Dockerfile`/`docker-compose.yml`
  themselves — this story is documentation-only.
- Making `CONTAINER_HOME` independently configurable (e.g. templating the `Dockerfile`'s
  `useradd` off of it). That would be a separate feature request if wanted.
- Auditing any other section of README.md or ARCHITECTURE.md beyond "Setup" and "Stack".
