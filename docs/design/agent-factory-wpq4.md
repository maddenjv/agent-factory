# Design: agent-factory-wpq4 - HOST_USER build-arg interpolation fix

Story: `docs/stories/agent-factory-wpq4.md`. Pure infra change (`bin/lib.sh`, `bin/start.sh`, doc
comments in `docker-compose.yml`, `README.md`, `docs/ARCHITECTURE.md`). No new files besides this
one, no change to `Dockerfile`, `docker-compose.yml`'s interpolation expressions themselves, or
what `bin/init.sh` writes into `.env` (all already correct per `agent-factory-76g`).

## Approach

The bug is entirely about which `.env` Compose reads for its own `${VAR:-default}` interpolation
in `docker-compose.yml` - a different mechanism from the `env_file:` key, which only injects vars
into the *container's* runtime process after the image is already built (see story Context).
Compose defaults that interpolation source to a `.env` next to the compose file (`KIT_DIR/.env`)
unless told otherwise with `--env-file`. `bin/lib.sh` already computes the one correct path,
`AGENT_ENV_FILE` (`agent-factory-jqn`), and exports it - but nothing ever hands it to Compose via
`--env-file`, so interpolation falls through to `KIT_DIR/.env` (almost always absent) and then to
the compose file's own literal defaults (`agent`/`1000`/`1000`).

Fix: pass `--env-file "$AGENT_ENV_FILE"` at every point that invokes `docker compose` against
`docker-compose.yml` - `bin/lib.sh`'s `dc()` wrapper (covers all of `bin/init.sh`, plus
`bin/start.sh`'s `dc up -d dolt`), and the three hand-built `docker compose run` command strings
in `bin/start.sh` (`pane()`, `ops_cmd`, `board_cmd`) that don't go through `dc()`. Same file
already used for `env_file:`, so this introduces no new file, no new parsing format (Compose's
`--env-file` and `env_file:` share the same KEY=VALUE parser - see `.env.example`'s comment on
`DAILY_BUDGET_USD` about that parser's empty-value/comment quirk), and no new place for the value
to drift out of sync.

This is the same fix `agent-factory-76g`'s own test file already leaned on without saying so:
`tests/agent-factory-76g_test.sh`'s `build_and_run()` (line ~143) constructs its own
`docker compose -f ... --env-file "$envf"` command instead of calling `bin/init.sh`'s real `dc()`
path for its docker-backed assertions - which is exactly why those tests pass today despite the
bug: they never actually exercised the broken wiring. Confirms `--env-file` is the correct,
already-proven fix; QA's new tests must exercise the *real* `dc()`/`bin/start.sh` path instead of
reimplementing their own, or they'd repeat that blind spot.

## Changes

### `bin/lib.sh` - `dc()` (lines 34-36)
```bash
dc() {  # dc <docker compose args...> - always targets the kit's compose file, from PROJECT_DIR
  # --env-file feeds AGENT_ENV_FILE's HOST_UID/HOST_GID/HOST_USER/CONTAINER_HOME (and everything
  # else in it) into Compose's own ${VAR:-default} interpolation in docker-compose.yml - build
  # args, mount-path defaults, dolt's `user:`. Separate from the env_file: key on the agent
  # service, which only injects vars into the container's *runtime* process after the image is
  # already built (see docs/design/agent-factory-wpq4.md).
  docker compose -f "$KIT_DIR/docker-compose.yml" --env-file "$AGENT_ENV_FILE" "$@"
}
```
This alone fixes every `bin/init.sh` call (`dc build agent`, `dc up -d dolt`, `dc exec`, `dc run
--rm --entrypoint bash agent ...`) and `bin/start.sh`'s own `dc up -d dolt` (AC1), and also fixes
`dolt`'s `user: "${HOST_UID:-1000}:${HOST_GID:-1000}"` interpolation for free (currently has the
same bug, just not called out by an AC since it happened to match the default on most boxes).

### `bin/start.sh` - `pane()`, `ops_cmd`, `board_cmd` (lines 22, 40-41)
Add `--env-file '$AGENT_ENV_FILE'` right after `-f '$KIT_DIR/docker-compose.yml'` in all three
command strings (they don't call `dc()` - each hand-builds a full `docker compose ...` string for
tmux to run in a fresh shell that never sources `lib.sh`):
```bash
local cmd="PROJECT_DIR='$PROJECT_DIR' KIT_DIR='$KIT_DIR' AGENT_ENV_FILE='$AGENT_ENV_FILE' ROLE=$role docker compose -f '$KIT_DIR/docker-compose.yml' --env-file '$AGENT_ENV_FILE' run --rm --name factory-$title $*"
```
```bash
ops_cmd="PROJECT_DIR='$PROJECT_DIR' KIT_DIR='$KIT_DIR' AGENT_ENV_FILE='$AGENT_ENV_FILE' ROLE=shell docker compose -f '$KIT_DIR/docker-compose.yml' --env-file '$AGENT_ENV_FILE' run --rm --name factory-ops --entrypoint bash agent '$KIT_DIR/bin/ops-shell.sh'"
board_cmd="PROJECT_DIR='$PROJECT_DIR' KIT_DIR='$KIT_DIR' AGENT_ENV_FILE='$AGENT_ENV_FILE' ROLE=shell docker compose -f '$KIT_DIR/docker-compose.yml' --env-file '$AGENT_ENV_FILE' run --rm --name factory-board --entrypoint bash agent '$KIT_DIR/bin/board.sh'"
```
Why this matters beyond AC1's `dc build agent`: `docker compose run` re-resolves the compose
file's own interpolation (mount targets, `${CONTAINER_HOME:-/home/${HOST_USER:-agent}}`) at run
time regardless of what the image was built with. Without `--env-file` here, a correctly-built
`alice`/`1234`/`1234` image would still get its `.claude`/`.ai-dev-kit`/`.agents` volumes mounted
at `/home/agent/...` (the literal default) instead of `/home/alice/...`, and
`agent-factory-76g`'s `agent-loop.sh` guard (`CONTAINER_HOME != $HOME` -> exit 1) would then
correctly refuse to start every role's container - the story's AC2 (fixes this).

### `docker-compose.yml` (comments only, no interpolation expressions change)
- Top-of-file comment (lines 11-16): after "Always invoked via bin/lib.sh's `dc` (docker compose
  -f <this file>)", add: "- `dc()` also passes `--env-file` so `HOST_UID`/`HOST_GID`/`HOST_USER`/
  `CONTAINER_HOME` in that file actually reach the `${VAR:-default}` interpolation below, not just
  the container's runtime env (see docs/design/agent-factory-wpq4.md)."
- Comment above `env_file:` (line 54): no change needed - it already correctly describes that key
  as the container's runtime env, which remains true and unrelated to this fix.
- Comment above the volume mounts (lines 70-72): append one clause noting `CONTAINER_HOME`/
  `HOST_USER` now reach this interpolation via `dc()`'s and `bin/start.sh`'s `--env-file`, not
  just by coincidence of shell-exported defaults.

### `README.md` Setup section (~line 56, after the `CONTAINER_HOME` sentence)
Add: "Compose only resolves `${HOST_USER:-agent}`-style defaults in `docker-compose.yml` from
`--env-file` (or a real host shell export) - `bin/lib.sh`'s `dc()` and `bin/start.sh`'s `run`
commands pass `--env-file` pointing at the resolved `.env` for exactly this, separately from the
`env_file:` key that injects those values into each container's own runtime environment."

### `docs/ARCHITECTURE.md` Stack section (~line 48, end of the `agent` bullet)
Append: "Compose's own `${HOST_USER:-agent}`-style interpolation in `docker-compose.yml` (build
args, mount-path defaults, `dolt`'s `user:`) only sees `.env`'s values because `bin/lib.sh`'s
`dc()` and `bin/start.sh`'s `run` commands pass `--env-file \"$AGENT_ENV_FILE\"`; the `env_file:`
key on the `agent` service is a separate mechanism for the container's own runtime process env
(`docs/design/agent-factory-wpq4.md`)."

No change to `Dockerfile`, `docker-compose.yml`'s `${...}` expressions, `bin/init.sh`, or
`.env.example` - all already correct; only the delivery of `AGENT_ENV_FILE`'s contents to
Compose's interpolation step was missing.

## Acceptance mapping
1. `dc()`'s `--env-file` fixes `bin/init.sh`'s `dc build agent`.
2. Same `--env-file` added to `pane()`/`ops_cmd`/`board_cmd` fixes all three `bin/start.sh` spawn
   paths; re-resolves mount targets under `/home/alice`, satisfying `agent-loop.sh`'s existing
   `CONTAINER_HOME != $HOME` guard instead of tripping it.
3. Unchanged from `agent-factory-76g`: numeric `HOST_UID:HOST_GID` still owns bind-mount writes;
   now actually `1234:1234` instead of always `1000:1000`, because the build arg (AC1) and the
   image account are both correctly `alice`/`1234`/`1234`.
4. `${HOST_USER:-agent}` etc. are untouched - when `AGENT_ENV_FILE` doesn't define a key,
   `--env-file` simply doesn't supply it and Compose's own literal default still applies. No new
   failure mode for a `.env` predating `agent-factory-76g`, as long as `AGENT_ENV_FILE` itself
   resolves to an existing file (see Errors/edge cases below for the one case where it might not).
5. Rebuilding with unchanged `.env` re-supplies the same `--env-file` values -> same build args ->
   `Dockerfile`'s existing `userdel`/`groupdel`-then-`useradd` sequence (`agent-factory-76g`) is
   already idempotent against that.
6. Doc edits above, scoped to the one inaccuracy this fix changes: *how* `.env`'s values reach
   Compose, not *what* they are (README/ARCHITECTURE's existing "host user's name/UID/GID" claims
   were already correct as a description of intent, just previously unimplemented).

## Errors / edge cases
- **`AGENT_ENV_FILE` resolves to a path that doesn't exist at all** (not "exists but missing the
  four keys" - AC4's case, which is fine): only reachable by running `bin/start.sh` (or any `dc()`
  call) without ever having run `bin/init.sh` for that project, and *also* with no `KIT_DIR/.env`
  present (`bin/lib.sh`'s fallback target). Today this already fails loudly the moment `agent` (or
  any service that reads `env_file:`) is actually started, via the `env_file:
  ${AGENT_ENV_FILE:?...}` key. `--env-file` on a nonexistent path fails immediately instead
  (Compose errors before even parsing service definitions), which for `dc()` calls that don't
  touch the `agent` service (`dc up -d dolt`, called first in both `bin/init.sh` and
  `bin/start.sh`) is *earlier* than before - today `dc up -d dolt` succeeds in this scenario since
  `dolt` never reads `env_file:`. This is a strictly-unsupported flow already (per README, always
  run `init.sh` before `start.sh`), and the new failure is clearer (names the missing file) than
  today's later, more confusing failure when a pane's `agent` container won't start - not worth
  the complexity of conditionally omitting `--env-file` to preserve the old, already-broken
  partial-startup behavior. QA should confirm the new error is legible, not that it's avoided.
- Host shell happening to export a variable literally named `HOST_USER`/`HOST_UID`/`HOST_GID`/
  `CONTAINER_HOME` for unrelated reasons: Compose's documented precedence (real shell env wins
  over `--env-file`) would silently override `.env`'s value. Pre-existing Compose behavior, not
  introduced by this fix, and no different from the risk already accepted for every other
  `${VAR:-default}` in this file (`PROJECT_DIR`, `KIT_DIR`, `ROLE`, ...) - out of scope.
- Username invalid for `useradd`, UID/GID collisions: already out of scope per `agent-factory-76g`
  and this story's own Out of scope section.

## Test strategy (QA)
Acceptance-style, per `docs/ARCHITECTURE.md`'s "Test strategy" - and per the Approach section
above, must exercise the *real* `bin/lib.sh dc()` / `bin/start.sh` command-building paths, not a
test-local `docker compose --env-file` invocation (that would repeat `agent-factory-76g`'s blind
spot).
- **Fast, no-daemon-needed (`docker compose config`)**: with a scratch `AGENT_ENV_FILE` setting
  `HOST_USER=alice`/`HOST_UID=1234`/`HOST_GID=1234`, run the *real* `dc config` (sourcing
  `bin/lib.sh` for real, no stubbed `docker compose`) and grep the rendered YAML for
  `HOST_USER: "alice"` under `agent.build.args` and `/home/alice` under the mount targets and
  `dolt`'s `user:`. This renders full interpolation without building an image or needing a docker
  daemon - use it to cover AC1's build-arg half and AC4 (omit the four keys from the scratch file
  entirely, expect `agent`/`1000`/`1000`/`/home/agent` in the rendered config) cheaply.
- **`bin/start.sh`'s three command strings**: source `bin/start.sh` with `tmux` stubbed on `PATH`
  (capture what it's invoked with instead of actually starting a session) to extract the real
  `cmd`/`ops_cmd`/`board_cmd` strings, and assert `--env-file` appears in all three, pointing at
  the same `$AGENT_ENV_FILE` value `bin/lib.sh` resolved. Then actually `eval` one exemplar
  (`ops_cmd` is simplest - no `$*` role args) against a real docker daemon and run the AC2 `id`/
  `$HOME` check, same shape as `agent-factory-76g`'s `test_ac2_image_account_matches_host_user`,
  to confirm end-to-end behavior for at least one of the three, not just their command text.
- **Image level (docker-backed, skip if no daemon - mirrors `agent-factory-76g`'s tests almost
  exactly, but now driving `bin/init.sh` for real instead of a test-local `--env-file`)**: run the
  real `bin/init.sh` against a scratch project with `alice`/`1234`/`1234` (stubbed `id`, as
  `agent-factory-76g`'s tests already do), then the real `bin/lib.sh`-sourced `dc build agent` /
  `dc run --rm --entrypoint bash agent -lc 'id -un; id -u; id -g; echo $HOME'` and check
  `alice`/`1234`/`1234`/`/home/alice` (AC1). Write a file through a bind mount via that same real
  `dc run` and check host ownership `1234:1234` (AC3). Re-run `bin/init.sh` unchanged and rebuild;
  diff `docker inspect`'s config (or re-run the `id`/`$HOME` check) to confirm no drift (AC5).
  Repeat once with `HOST_UID`/`HOST_GID`/`HOST_USER`/`CONTAINER_HOME` absent from a *pre-existing*
  scratch `.env` (not a fresh one - `bin/init.sh` would populate a fresh one) to confirm the AC4
  fallback holds through the real build path too, not just `dc config`.
- **Regression**: `shellcheck bin/lib.sh bin/start.sh`; re-run `tests/agent-factory-76g_test.sh`
  and the rest of `tests/` (per `docs/ARCHITECTURE.md`'s regression-suite rule) to confirm nothing
  else broke, especially `bin/start.sh`'s existing tests if any cover `pane()`'s command string
  shape.
- **Docs (AC6)**: grep `docker-compose.yml`, `README.md`, `docs/ARCHITECTURE.md` for the new
  `--env-file` mentions specified above.
