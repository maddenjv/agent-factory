# Design: agent-factory-1aq - shellcheck in the agent image

## Approach
Install Debian's `shellcheck` package (bookworm, ~0.9.0) via apt in the existing runtime-stage
`apt-get install` line. No pinning, no extra repos, no new layers.

## Changes
1. `Dockerfile` (runtime stage, line ~18): add `shellcheck` to the package list:
   `git jq curl ca-certificates shellcheck \`. Keep `--no-install-recommends` and the apt list cleanup.
2. `docs/ARCHITECTURE.md` (~line 19): add `shellcheck` to the image tool list (done in this design commit).

Nothing else changes: user/UID/GID setup, claude, bd, entrypoint untouched.

## Errors / risks
- apt package unavailable -> build fails (AC1 catches it). Unlikely on bookworm.
- `--no-install-recommends` keeps size small; shellcheck's deps are installed as hard depends.

## Acceptance criteria mapping
- AC1: build succeeds with the one-word change.
- AC2: `shellcheck --version` present on PATH for the `john` user (installed to /usr/bin).
- AC3: `shellcheck bin/lib.sh` runs; exit code reflects lint result (0/1), not 127.
- AC4: no other lines touched; existing tools/user unchanged.

## Test strategy (QA)
Docker-level checks, matching ACs: build the image; run `shellcheck --version` via
`docker compose run --rm --entrypoint bash agent -lc`; run shellcheck on `bin/lib.sh` and assert
exit code is not 127 and output/exit is a lint result; check `claude --version`, `bd --version`,
`git --version`, `jq --version`, `curl --version`, and `id -u`/`id -g`/`id -un` match pre-change values.
Tests must skip cleanly when docker is unavailable. Do not assert lint cleanliness of bin/*.sh (out of scope).
