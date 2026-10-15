# Design: agent-factory-mgq7 - reuse the project's `.venv` inside the containers

Story: `docs/stories/agent-factory-mgq7.md`. Depends on `agent-factory-ncij` (python3 + venv + pip
in the image; still in flight when this was designed - see "Missing toolchain").

## Approach
At container startup, `bin/agent-loop.sh` runs a new helper, `bin/project-venv.sh`, that
**recreates** the host `PROJECT_DIR/.venv` as a container-local venv and then activates it
(PATH/VIRTUAL_ENV) for every harness session the loop starts. The host `.venv` is only read.

Design choices (and why):
- **Learn the package set without running host code.** The host `bin/python` is a dangling symlink
  in the container, so we never execute it. We read
  `PROJECT_DIR/.venv/lib/python*/site-packages/*.dist-info` directory names (`<name>-<version>.dist-info`;
  `name=${n%-*}`, `version=${n##*-}`). No interpreter, no pip, nothing written there (AC3).
- **Location: `$DATA_DIR/venv`** (`PROJECT_DIR/.agent-factory/venv`). It is shared by all roles (one
  build, "all roles get the same venv"), survives `docker compose run --rm` restarts (AC4), is already
  git-ignored by `init-project.sh`, and lies outside every clone under `.agent-factory/workspaces/<role>`
  so it never shows in a clone's `git status` (AC8). Its `bin/python` symlinks to the image's
  `/usr/bin/python3`, so it is only usable in the container - intended. Never create it under
  `PROJECT_DIR/.venv` or inside a clone.
- **Rebuild, don't patch.** The venv is keyed by a stamp; any difference in the stamp wipes
  `$DATA_DIR/venv` and rebuilds from scratch. This makes removals and version changes exact (AC5)
  with no uninstall logic.
- **Concurrency.** All five containers start together. The helper is run by agent-loop.sh under
  `flock -w 900 9 ... 9>"$CONTROL/venv.lock"` (same pattern as `sync_configs`); the first container
  builds, the rest block, then see a matching stamp and return immediately. Lock timeout -> log and
  continue without a venv (never block startup indefinitely).

## Files
- **new `bin/project-venv.sh`** - executable bash, `set -uo pipefail`, always exits 0 (startup must
  never fail because of this feature). Env inputs (all defaulted, overridable so QA can drive it
  with a fake project): `PROJECT_DIR` (required), `DATA_DIR` (default `$PROJECT_DIR/.agent-factory`),
  `VENV_DIR` (default `$DATA_DIR/venv`), `PYTHON` (default `python3`). Logs with a local
  `log()` printing `venv: ...` lines to stdout (agent-loop's stdout is the startup output; the call
  site pipes it through `log`, see below). pip config is not hard-coded: `PIP_INDEX_URL`,
  `PIP_FIND_LINKS`, `PIP_NO_INDEX` etc. pass through natively.
- **`bin/agent-loop.sh`** - after `sync_configs`, before the clone:
  ```bash
  VENV_DIR="$DATA_DIR/venv"
  (
    flock -w 900 9 || { log "venv: lock timed out; continuing without project venv"; exit 0; }
    PROJECT_DIR="$PROJECT_DIR" DATA_DIR="$DATA_DIR" VENV_DIR="$VENV_DIR" bash "$KIT_DIR/bin/project-venv.sh" 2>&1 | while IFS= read -r l; do log "$l"; done
  ) 9>"$CONTROL/venv.lock"
  if [ -x "$VENV_DIR/bin/python" ] && [ -f "$VENV_DIR/.af-ready" ] && [ -d "$PROJECT_DIR/.venv" ]; then
    export VIRTUAL_ENV="$VENV_DIR"; export PATH="$VENV_DIR/bin:$PATH"
  fi
  ```
  (the `.af-ready` marker is written by the helper when a venv exists, even with partial install
  failures; it is removed at the start of a rebuild). Exports happen in the main shell, after the
  subshell, so the claude/copilot child processes inherit them. `python` (no path) then resolves to
  `$VENV_DIR/bin/python` (AC1). Without a host `.venv` nothing is exported and the helper logs nothing (AC6).
- **`docs/ARCHITECTURE.md`** - add the "Project venv" bullet (done in this design branch).
- No Dockerfile or compose change (volume is under the existing `PROJECT_DIR` bind mount).

## `project-venv.sh` algorithm
1. `[ -d "$PROJECT_DIR/.venv" ] || exit 0` - silent (AC6).
2. `sp=$(ls -d "$PROJECT_DIR"/.venv/lib/python*/site-packages 2>/dev/null | sort | head -1)`; none -> log
   `venv: host .venv has no site-packages; skipping`, exit 0.
3. Build the list of `name==version` from `$sp/*.dist-info`, sorted. If a dist-info has a
   `direct_url.json` (editable / local path / VCS install) it cannot be reproduced by version: record it
   as a failure `name (direct-URL/editable install; not reproducible)` and leave it out of the install list.
4. `command -v "$PYTHON"` and `$PYTHON -c 'import venv, ensurepip'` must work; otherwise log
   `venv: python3/venv not available in this image (agent-factory-ncij); skipping` and exit 0.
5. stamp = `sha256sum` of `"$($PYTHON -V 2>&1)"` + the sorted list. If `$VENV_DIR/.af-stamp` equals it and
   `$VENV_DIR/bin/python` runs -> log `venv: up to date (N packages)`, exit 0 (AC4; no pip run).
6. Otherwise `rm -rf "$VENV_DIR"`, `$PYTHON -m venv "$VENV_DIR"` (no system-site-packages). If creating
   fails: log the error, remove the partial dir, exit 0.
7. Install with `PIP_CERT=${PIP_CERT:-/etc/ssl/certs/ca-certificates.crt}` (pip's bundled certifi would
   otherwise ignore the extra CAs baked into the image) and `PIP_DISABLE_PIP_VERSION_CHECK=1`:
   first one bulk `"$VENV_DIR/bin/pip" install --no-deps -q "${list[@]}"`; if it fails, fall back to one
   `pip install --no-deps name==ver` per package, recording each failing `name==ver` with the last line
   of pip's error. `--no-deps` is deliberate: the host set is already the complete resolved set, so the
   container set equals it exactly rather than being re-resolved (AC2, AC5). Pinning `pip`,
   `setuptools`, `wheel` is treated like any other package.
8. Report: each failure -> `venv: FAILED to install <name>==<ver>: <reason>`; summary
   `venv: N installed, M failed`. Startup continues regardless (AC7).
9. Write `.af-ready`; write `.af-stamp` **only if there were zero failures**, so a transient or fixed
   failure is retried at the next start rather than frozen in (cost: a failing package is retried each
   restart - acceptable).

## Error cases
| Case | Behaviour |
|---|---|
| no `.venv` | silent no-op, nothing exported (AC6) |
| no python/venv in image | one `venv:` log line, continue |
| venv creation fails | log, remove partial, continue |
| package fails (no wheel, editable, network) | named in output, others still installed, startup continues (AC7) |
| lock timeout (another container still building) | log, continue without activation |
| host `.venv` changes while running | picked up at next start only |

## Acceptance criteria mapping
1. `python` -> `$VENV_DIR/bin/python` via PATH export; QA: `command -v python` equals that path and runs.
2. pinned `name==version` of every host dist-info; QA imports/`pip show` versions.
3. helper only reads `.venv`; QA snapshots `find .venv -printf '%p %T@ %s\n'` before/after.
4. stamp match skips `pip`; QA: second run logs `up to date` and pip is not invoked (e.g. `PIP_*` pointing at a
   failing index still succeeds / a `pip` shim counts calls).
5. stamp covers the sorted list -> rebuild; QA adds, removes and bumps a package.
6. step 1.
7. step 7-8; QA: include a package absent from the (local) index; others install, output names it, exit 0.
8. location outside clones; QA: `git -C workspaces/<role> status --porcelain` is empty.

## Test strategy (QA)
`tests/agent-factory-mgq7_test.sh`, matching the existing `tests/*_test.sh` style. The helper is directly
runnable, so no Docker is needed: build a fake `PROJECT_DIR` whose `.venv/lib/python3.X/site-packages`
holds hand-made `<name>-<ver>.dist-info` dirs, and serve real tiny wheels offline via
`PIP_NO_INDEX=1 PIP_FIND_LINKS=<dir of locally built wheels>` (build them with `pip wheel` of trivial
generated packages, or skip with a clear message if `python3 -m venv` is unavailable on the test host).
Cover ACs 2-7 and the `direct_url.json` case at this level. AC1/AC8 and the `agent-loop.sh` wiring:
static check that agent-loop.sh calls the helper under `flock` and exports `VIRTUAL_ENV`/`PATH` only when
`$PROJECT_DIR/.venv` exists, plus one optional container check
(`docker compose run --rm --entrypoint bash agent -lc 'command -v python'` after exercising the helper)
once `agent-factory-ncij` has landed.

## Missing toolchain
`agent-factory-ncij` (image gets python3/venv) was not on `main` at design time. The helper degrades
gracefully (step 4), so implementation and host-level tests do not wait on it; only the final in-container
check does.
