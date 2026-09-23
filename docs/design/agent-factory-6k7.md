# Design: agent-factory-6k7 - Document CONTAINER_HOME and fix container-identity docs

## Approach
Documentation-only change to two sections: `docs/ARCHITECTURE.md`'s "Stack" bullet on the `agent`
container, and README.md's "Setup" section. No runtime files change.

Verified against current source (all four files read in full for this design):
- `Dockerfile:28-31` hardcodes the account: `groupadd -g "$HOST_GID" john && useradd -u
  "$HOST_UID" -g "$HOST_GID" -m -s /bin/bash john`, then `USER john` / `ENV HOME=/home/john`. It
  never reads `CONTAINER_HOME` - confirmed by `grep CONTAINER_HOME Dockerfile` (no matches).
- `docker-compose.yml:69-77` uses `${CONTAINER_HOME:-/home/john}` as the mount-target prefix for
  three pairs of volumes (`.claude`, `.ai-dev-kit`, `.agents`, each with a `-host:ro` sibling).
  Its own comment (lines 69-71) already states the constraint accurately: "must match the image's
  actual account home."
- `bin/init.sh:20` auto-populates `CONTAINER_HOME=/home/john` into `.env` (project-level
  `AGENT_ENV_FILE`) if not already set, immediately after doing the same for `HOST_UID`/
  `HOST_GID` on the line above.
- `bin/agent-loop.sh:29` defaults `CONTAINER_HOME="${CONTAINER_HOME:-/home/john}"` and uses it at
  lines 232-234 in `sync_configs()` as the base path for copying `~/.claude`, `~/.ai-dev-kit`,
  `~/.agents` from their `-host` read-only mounts into the role's writable config, at startup.

No other drift found in these two sections against the four files during this read-through (AC
3): README's "Setup" section's other claims (self-contained image build, `KIT_DIR`/`PROJECT_DIR`
split, `.env` resolution, `init.sh`'s `receive.denyCurrentBranch=updateInstead` and initial-commit
behavior, `HOST_UID`/`HOST_GID` build args) all match current `bin/init.sh` and
`docker-compose.yml`. ARCHITECTURE.md's "Stack" bullet's other claims (image base, installed
tools, `bd` build provenance, `HOST_UID`/`HOST_GID` build args) also match the `Dockerfile`.

## Files to change

### `docs/ARCHITECTURE.md` - "Stack" section, `agent` bullet (currently line 19)
Replace the clause "Runs as a non-root user `john`, home `/home/john`, with `HOST_UID`/
`HOST_GID` build args so files it writes into host bind mounts are owned by the invoking host
user." with two sentences that separate the fixed account from `CONTAINER_HOME`:

- State the account is fixed by the `Dockerfile`: non-root user `john`, UID/GID from
  `HOST_UID`/`HOST_GID` build args (so files written into host bind mounts are owned by the
  invoking host user), home `/home/john`.
- State that `CONTAINER_HOME` (env var, default `/home/john`, auto-populated into `.env` by
  `bin/init.sh`) is a separate, dependent setting: used only as the mount-path prefix for the
  `.claude`/`.ai-dev-kit`/`.agents` volumes in `docker-compose.yml` and as the base path
  `agent-loop.sh`'s `sync_configs()` syncs host configs into at startup - not an independent way
  to relocate the account's home. Changing it without also editing the `Dockerfile`'s hardcoded
  `john`/`/home/john` account breaks those mounts.

Satisfies AC1.

### `README.md` - "Setup" section, opening paragraph (currently lines 29-33)
The paragraph already says "Its container user is `john`" with no mention of `CONTAINER_HOME`.
Add a sentence (or extend the existing one) stating: `CONTAINER_HOME` (default `/home/john`,
matching the account `john`'s home) also exists as an env var; `bin/init.sh` auto-populates it
into `.env` alongside `HOST_UID`/`HOST_GID` on first run. Keep the wording consistent with the
new ARCHITECTURE.md text - point there (or restate briefly) that it is a dependent setting, not
an independently changeable one.

Satisfies AC2.

### Consistency pass (AC3, AC4)
When writing both edits, re-read the full "Setup" section and the full "Stack" bullet once more
against `Dockerfile`, `docker-compose.yml`, `bin/init.sh`, `bin/agent-loop.sh` to confirm no other
statement contradicts current behavior, and that neither edited passage claims or implies
`CONTAINER_HOME` can be changed safely on its own. (This design's own read-through above found no
other drift; QA should re-verify against the actual committed wording, since it's possible the
engineer's phrasing accidentally reintroduces an unconditional-sounding claim.)

## Test strategy
Doc-only story - no `make test`/script to run (see ARCHITECTURE.md "Test strategy"). QA should
verify by inspection:
1. `docs/ARCHITECTURE.md`'s Stack bullet, read on its own, distinguishes the fixed `Dockerfile`
   account from `CONTAINER_HOME`, and doesn't claim `CONTAINER_HOME` relocates the home
   independently (AC1, AC4).
2. README's Setup section mentions `CONTAINER_HOME`, its default, and that `init.sh`
   auto-populates it into `.env` alongside `HOST_UID`/`HOST_GID` (AC2).
3. Diff both sections line-by-line against `Dockerfile`, `docker-compose.yml:69-77`,
   `bin/init.sh`, `bin/agent-loop.sh:29,229-234` - every factual claim in the two sections should
   trace to one of these four files (AC3).
4. Grep both edited passages for phrasing like "change `CONTAINER_HOME` to relocate" or similar
   that would violate AC4.
