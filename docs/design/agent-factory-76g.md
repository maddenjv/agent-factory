# Design: agent-factory-76g - host username/UID/GID/home in the agent image

Story: `docs/stories/agent-factory-76g.md`. Pure infra change (Dockerfile, compose, two scripts,
two docs). No new files besides this one.

## Approach
Add `HOST_USER` (from `id -un`) alongside `HOST_UID`/`HOST_GID` as a `.env` value and image build
arg. The image's account is `HOST_USER` with home `/home/$HOST_USER`. `CONTAINER_HOME` stays the
dependent mount-path setting, now derived as `/home/$HOST_USER` and never hardcoded. Nowhere in the
in-scope files may the literal `john` remain (AC7), so fallback defaults use the neutral name `agent`.

## Changes

### `bin/init.sh` (lines 18-19)
Make each key independent so a partial `.env` is topped up without overwriting (AC1, AC6):
```bash
grep -q '^HOST_UID=' "$AGENT_ENV_FILE" || echo "HOST_UID=$(id -u)" >> "$AGENT_ENV_FILE"
grep -q '^HOST_GID=' "$AGENT_ENV_FILE" || echo "HOST_GID=$(id -g)" >> "$AGENT_ENV_FILE"
grep -q '^HOST_USER=' "$AGENT_ENV_FILE" || echo "HOST_USER=$(id -un)" >> "$AGENT_ENV_FILE"
grep -q '^CONTAINER_HOME=' "$AGENT_ENV_FILE" || echo "CONTAINER_HOME=/home/$(id -un)" >> "$AGENT_ENV_FILE"
```
(Splitting UID/GID is harmless: existing files have both or neither.) Do not derive `CONTAINER_HOME`
from an existing `HOST_USER` line; `id -un` is the source of truth on a fresh file, and an
existing `CONTAINER_HOME` is never touched.

### `Dockerfile`
- Add `ARG HOST_USER=agent` next to the UID/GID args (default only matters for a bare
  `docker build`; compose always passes it).
- Account creation:
  ```
  RUN userdel -r node 2>/dev/null; groupdel node 2>/dev/null; \
      groupadd -g "$HOST_GID" "$HOST_USER" && useradd -u "$HOST_UID" -g "$HOST_GID" -m -s /bin/bash "$HOST_USER"
  USER ${HOST_USER}
  ENV HOME=/home/${HOST_USER}
  ```
  `USER`/`ENV` accept build args (ARG is in scope after FROM). Update the comment above the RUN to
  say "the account we create below" instead of naming a user. Keep the `node` removal (host user
  may itself be `node`, or uid 1000).
- `ENV HOME` stays set explicitly because compose's `user: uid:gid` bypasses `USER`, but HOME from
  ENV still applies; `bash -lc 'echo $HOME'` then yields `/home/alice` (AC2).

### `docker-compose.yml`
- `agent.build.args`: add `HOST_USER: ${HOST_USER:-agent}`.
- Replace every `${CONTAINER_HOME:-/home/john}` (6 volume lines) with
  `${CONTAINER_HOME:-/home/${HOST_USER:-agent}}` - compose supports nested defaults, so the
  fallback is always consistent with the build arg. Update the comment above them to say
  CONTAINER_HOME/HOST_USER are populated by `bin/init.sh` and must agree with the image account.
- `agent` service gets no `user:` change (numeric uid:gid already; AC3 is satisfied by the
  existing mapping since files are written as `HOST_UID:HOST_GID`).

### `bin/agent-loop.sh` (line 29)
`CONTAINER_HOME="${CONTAINER_HOME:-$HOME}"` - no literal; `$HOME` is the image's `ENV HOME`.
Add a fail-fast guard right after it, protecting operators whose `.env` predates this change
(`CONTAINER_HOME=/home/john` but image rebuilt with a different/absent `HOST_USER`, so mounts and
home disagree):
```bash
if [ "$CONTAINER_HOME" != "$HOME" ]; then
  echo "error: CONTAINER_HOME ($CONTAINER_HOME) != image HOME ($HOME). Set HOST_USER (and CONTAINER_HOME=/home/<HOST_USER>) in .env - re-run bin/init.sh after removing a stale CONTAINER_HOME line - then rebuild: docker compose build agent" >&2
  exit 1
fi
```
Sync code at lines 232-234 already uses `$CONTAINER_HOME`; no change (AC4).

### Docs
- `README.md` Setup paragraph (lines ~49-56): describe the container user as taking the host
  user's name/UID/GID, home `/home/<host user>`; `init.sh` records `HOST_USER`, `HOST_UID`,
  `HOST_GID`, `CONTAINER_HOME` into `.env`. Remove `john`/`/home/john`.
- `docs/ARCHITECTURE.md` Stack/`agent` bullet: replace the "fixes the account: ... `john`" text
  with: account name, UID/GID from `HOST_USER`/`HOST_UID`/`HOST_GID` build args (host user), home
  `/home/$HOST_USER`; `CONTAINER_HOME` stays a dependent mount-path setting that must equal that
  home (agent-loop.sh refuses to start otherwise).
- `.env.example` needs no change (these keys are auto-populated, like HOST_UID today).

## Acceptance mapping
1. init.sh lines above on a fresh `.env`. 2. Build arg -> useradd -> `ENV HOME`. 3. Unchanged numeric
uid:gid. 4. Compose mounts + agent-loop use `CONTAINER_HOME` = `/home/$HOST_USER`. 5. For `john`/1000
every value equals the old one. 6. Independent greps. 7. `grep -rniE 'john' Dockerfile
docker-compose.yml bin README.md docs/ARCHITECTURE.md` returns nothing (also check comments in
those files, e.g. `bin/` scripts).

## Errors / edge cases
- Host username invalid for `useradd`, or gid colliding with an existing image group: out of scope.
- Stale `.env` (has CONTAINER_HOME, no HOST_USER): `init.sh` adds HOST_USER; if the operator skips
  it, the agent-loop guard fails loudly instead of mounting into the wrong home.

## Test strategy (QA)
All acceptance-style from the host shell, per ARCHITECTURE.md "Test strategy":
- Script level: run `bin/init.sh`-equivalent env-file logic against scratch `.env` files: fresh
  (AC1, stub `id` via a PATH shim returning alice/1234/1234), partial `.env` with UID/GID/HOME but
  no user (AC6, existing values byte-identical, HOST_USER appended once, re-run idempotent).
- Image level: build with `HOST_USER=alice HOST_UID=1234 HOST_GID=1234`, run the AC2 `id`/`$HOME`
  command; write a file to a bind mount and check host ownership (AC3); confirm the three volume
  targets under `/home/alice` via `docker compose config` (AC4); repeat for john/1000 (AC5).
- Guard: run agent-loop with mismatching `CONTAINER_HOME` and expect exit 1 and the message.
- Static: the AC7 grep, plus `shellcheck bin/init.sh bin/agent-loop.sh`.
