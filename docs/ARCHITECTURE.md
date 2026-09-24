# Architecture

agent-factory is an orchestration kit, not an application: bash scripts drive Docker Compose to
run five Claude Code agents (`po`, `architect`, `engineer`, `qa`, `reviewer`) against a real
project, coordinated through Beads (`bd`) and git. There is no application source tree of its own
to compile; "the code" is the `bin/*.sh` scripts, `docker-compose.yml`, the `Dockerfile` for the
`agent` image, and the per-role prompts under `agents/`.

## Stack
- **Orchestration**: `bash` scripts under `bin/` (`lib.sh` holds shared helpers; every other
  script sources it). No other scripting language is introduced without a strong reason.
- **Containers**: Docker Compose (`docker-compose.yml`), two services:
  - `dolt` - `dolthub/dolt-sql-server`, the shared Beads database (server mode, concurrent
    writers).
  - `agent` - the image every role runs, built from this repo's own `Dockerfile` (Debian
    bookworm base, matching the `node:22-bookworm-slim` family already used for the Claude Code
    CLI). Contains: `claude` (`@anthropic-ai/claude-code`, npm), `bd`/`beads`
    (`github.com/steveyegge/beads/cmd/bd`, go install, copied out of a throwaway builder stage),
    `git`, `jq`, `curl`, `shellcheck`, `bash`. The `Dockerfile` creates the account from the host user: name, UID and
    GID from `HOST_USER`/`HOST_UID`/`HOST_GID` build args (so files it writes into host bind mounts
    are owned by the invoking host user), home `/home/$HOST_USER`. `CONTAINER_HOME` (env var,
    auto-populated into `.env` by `bin/init.sh` as `/home/<host user>`) is a separate, dependent setting - used only as
    the mount-path prefix for the `.claude`/`.ai-dev-kit`/`.agents` volumes in
    `docker-compose.yml` and as the base path `agent-loop.sh`'s host-config sync copies into at
    startup. It is not an independent way to relocate the account's home: it must equal
    `/home/$HOST_USER`, and `agent-loop.sh` refuses to start otherwise.
- **Tracker**: Beads (`bd`), Dolt-backed, shared across all five containers.

## Layout
```
bin/              orchestration scripts (init.sh, start.sh, stop.sh, agent-loop.sh, lib.sh, env.sh, ...)
agents/           one prompt file per role (po.md, architect.md, engineer.md, qa.md, reviewer.md)
docker-compose.yml
Dockerfile        the agent image (this repo owns it - see below)
docs/stories/     PO-authored user stories, one per story id
docs/design/      architect-authored design docs, one per story id
docs/ARCHITECTURE.md   this file
```
Two directories outside this repo matter at runtime and must not be confused (see `bin/lib.sh`):
**KIT_DIR** (this repo) and **PROJECT_DIR** (the project being worked on, which gets its own
`.agent-factory/` runtime state - workspaces, logs, Dolt data, Claude config).

## Conventions
- Scripts are POSIX-ish bash, `set -euo pipefail` (or the narrower `set -uo pipefail` where a
  script must survive individual command failures, e.g. `agent-loop.sh`'s long-running loop).
  `shellcheck` cleanliness is expected even though it isn't wired into CI yet.
- Every `bin/*.sh` script takes `PROJECT_DIR` from the caller's current directory, never from
  `KIT_DIR` - see README "Setup".
- Docker image changes: prefer boring, pinned-where-it-matters base images over cleverness. The
  `agent` image is rebuilt with `docker compose build agent`; there is no registry push step.
- Errors inside `agent-loop.sh` are handled by the loop itself (attempt caps, circuit breaker,
  `needs-human` escalation with a note) rather than by scripts crashing silently - see README
  "Guardrails built in".

## Test strategy
This is an infra/orchestration kit: there is no unit-test framework and none should be added for
its own sake. Verification is acceptance-style, run from the host shell:
- **Docker image / toolchain changes** (e.g. the `Dockerfile`): `docker compose build agent`
  must succeed from a clean checkout with no paths outside this repo, then
  `docker compose run --rm --entrypoint bash agent -lc '<checks>'` to assert tool versions, user,
  and UID/GID inside a running container. `smoke-test.sh` (see README "Before running
  unattended") is the closest thing to an integration test for the multi-agent flow itself
  (concurrent Beads writes under server mode).
- **Regression suite**: QA's verify stage runs every script under `tests/` (both `tests/<story-id>_test.sh`
  and the older `tests/acceptance/<story-id>.sh`); a failing older-story script is a regression. New stories
  should use `tests/<story-id>_test.sh`.
- **bash script changes**: exercise the script directly (most are idempotent and safe to run
  against a scratch `PROJECT_DIR`); `shellcheck` the diff.
- **Regression suite**: QA's verify stage runs every script under `tests/` (both `tests/<story-id>_test.sh`,
  the convention for new stories, and the older `tests/acceptance/<story-id>.sh`), not just the current
  story's; a failing older script is a regression bug (see `agents/qa.md`).
- QA should specify, per story, the exact shell commands and expected output/exit codes an
  engineer's change must satisfy - there's no `make test` to fall back on.

## Dependency policy
Pin what breaks quietly (base image major versions); leave `claude`/`bd` unpinned (`@latest` /
`go install ...@latest`) as this repo already relied on the sandbox image doing, since agents
need to track current CLI releases - revisit if reproducibility becomes a real problem.
