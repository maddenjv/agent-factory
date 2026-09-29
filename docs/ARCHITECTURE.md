# Architecture

agent-factory is an orchestration kit, not an application: bash scripts drive Docker Compose to
run five Claude Code agents (`po`, `architect`, `engineer`, `qa`, `reviewer`) against a real
project, coordinated through Beads (`bd`) and git. There is no application source tree of its own
to compile; "the code" is the `bin/*.sh` scripts, `docker-compose.yml`, the `Dockerfile` for the
`agent` image, and the per-role prompts under `agents/`.

A sixth role, `team-lead`, triages four kinds of work: issues explicitly labelled
`needs-team-lead` (a stuck piece of work another role flagged); open issues that carry no
`role:*` label at all and aren't `needs-human`/`needs-team-lead` (since `agent-factory-m7af`),
i.e. work that reached the board outside the normal `feature.sh` intake path; and - since
`agent-factory-x8wj` - a `needs-chain` issue po files for every new story right after writing
`docs/stories/<id>.md`, asking team-lead to decide which of the five stages that story's chain
actually needs (favoring inclusion whenever it's unsure) and build it with `bin/new-story.sh` -
po itself no longer calls that script. `agent-loop.sh` finds all three directly via `bd list`
(not a `role:team-lead` label the other five use, and not `bd ready`, since the whole point is
investigating issues that may be blocked, unrouted, or not built yet). It reroutes stuck work to
the correct role/stage, fixes it directly, routes a no-story-context issue to `role:po`, sizes a
new story's chain, or escalates to `needs-human` - see `agents/team-lead.md`. It runs on the most
capable model tier (`agent-factory-250`) and has its own pane in `bin/start.sh`'s tmux layout
(`agent-factory-uhc`). Since `agent-factory-q4tj`, it also runs a fourth, issue-less kind of session
on a timer (`THROTTLE_STALE_SECS`, default 900s): it judges whether `po`/`architect` should keep
starting new top-of-funnel work, based on how deep the `engineer`/`qa`/`reviewer` backlog has grown
(including stories that only have a `needs-chain` issue open) and how much usage quota/budget
remains, and records that judgment - with a reason - in `.agent-factory/control/throttle.json`
(`bin/set-throttle.sh`). `bin/agent-loop.sh`'s `throttle_ok()` reads it for `po`/`architect` only;
`engineer`/`qa`/`reviewer` are never throttled by it, and a missing/stale file fails open (see
`docs/design/agent-factory-q4tj.md`'s Error cases) rather than wedging the whole factory.

## Stack
- **Orchestration**: `bash` scripts under `bin/` (`lib.sh` holds shared helpers; every other
  script sources it). No other scripting language is introduced without a strong reason.
- **Containers**: Docker Compose (`docker-compose.yml`), two services:
  - `dolt` - `dolthub/dolt-sql-server`, the shared Beads database (server mode, concurrent
    writers).
  - `agent` - the image every role runs, built from this repo's own `Dockerfile` (Debian
    bookworm base, matching the `node:22-bookworm-slim` family already used for the Claude Code
    CLI). Contains either `claude` (`@anthropic-ai/claude-code`, npm) or `copilot`
    (`@github/copilot`, npm) - chosen at build time by the `HARNESS` build arg
    (`bin/init.sh --harness=<claude-code|copilot>`, default `claude-code`; see README) - plus
    `bd`/`beads`
    (`github.com/steveyegge/beads/cmd/bd`, go install, copied out of a throwaway builder stage),
    `git`, `jq`, `curl`, `shellcheck`, `bash`. The `Dockerfile` creates the account from the host user: name, UID and
    GID from `HOST_USER`/`HOST_UID`/`HOST_GID` build args (so files it writes into host bind mounts
    are owned by the invoking host user), home `/home/$HOST_USER`. `CONTAINER_HOME` (env var,
    auto-populated into `.env` by `bin/init.sh` as `/home/<host user>`) is a separate, dependent setting - used only as
    the mount-path prefix for the `.claude`/`.copilot`/`.ai-dev-kit`/`.agents` volumes in
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

## Getting work to main
Two paths reach `main`, chosen by how much the work actually needs - see CLAUDE.md's "Storyless
fix work" for the mechanics an agent follows, and `agents/reviewer.md` for how each is reviewed:
- **Story path** (default; required whenever the work needs a new design decision or new tests):
  `story/<story-id>`, cut from `main` by po, runs design (architect) -> tests (qa) -> implement
  (engineer) -> verify (qa) -> review (reviewer) - design and/or tests can be skipped for simple
  work (`agent-factory-x8wj`: team-lead decides per story, favoring inclusion whenever unsure;
  implement/verify/review are never skipped). `bin/new-story.sh` builds whichever of those stages
  team-lead decided the story needs.
- **Storyless fix path** (small, self-contained `discovered-from` follow-ups only - a stale doc
  line, a one-line test fix, anything already fully scoped by the issue that found it, needing no
  new design decision and no new test): a `fix/<issue-id>` branch cut directly from `main`,
  reviewed and merged by the reviewer the same way as a story review - same bar, scaled to the
  size of the change - but skipping the tests/implement/verify stages entirely.

## Conventions
- Scripts are POSIX-ish bash, `set -euo pipefail` (or the narrower `set -uo pipefail` where a
  script must survive individual command failures, e.g. `agent-loop.sh`'s long-running loop).
  `shellcheck` cleanliness is expected even though it isn't wired into CI yet.
- Every `bin/*.sh` script takes `PROJECT_DIR` from the caller's current directory, never from
  `KIT_DIR` - see README "Setup".
- Docker image changes: prefer boring, pinned-where-it-matters base images over cleverness. The
  `agent` image is rebuilt with `docker compose build agent`; there is no registry push step.
- Errors inside `agent-loop.sh` are handled by the loop itself (attempt caps, circuit breaker,
  `needs-team-lead` escalation with a note for the five build roles, `needs-human` for team-lead's
  own escalations) rather than by scripts crashing silently - see README "Guardrails built in".

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
