# Design: agent-factory-9l0 - Use the invoking user's identity in agent containers

## Approach
Replace every literal `/home/john` in `docker-compose.yml`'s `agent` service and
`bin/agent-loop.sh` with a single new env var, `CONTAINER_HOME`, populated into `.env` by
`bin/init.sh` the same way `HOST_UID`/`HOST_GID` already are (`bin/init.sh:13`). This removes the
hardcoded strings from this repo's own files (satisfies AC5's grep check) and gives operators one
place to override the in-container home path if they've also customized the image accordingly.

**Scope boundary, and why the default stays `/home/john`**: per the story's Context/Out-of-scope
section, the `agent` image's account name and `$HOME` are not owned by this repo's files being
changed here. (Note for whoever implements this: as of this writing that's no longer strictly
true - `story/agent-factory-mi3` has an unmerged design, `docs/design/agent-factory-mi3.md` on
that branch, that adds a `Dockerfile` to *this* repo reproducing today's sandbox image, and it
deliberately keeps the account hardcoded as `john`/`/home/john` - "do not parameterize the name,
only UID/GID, since compose already assumes the path". Whichever of these two stories merges
second should sanity-check the other didn't just get contradicted; see Risks below.) Regardless
of which repo currently owns the image, the account it creates is `john` with `$HOME=/home/john`
today, and the running `claude` CLI resolves its own config from that real `$HOME` (or from
`CLAUDE_CONFIG_DIR` when set - see below), not from anything `docker-compose.yml` sets. So:

- `CONTAINER_HOME` defaults to `/home/john` everywhere it's used, preserving today's working
  behavior for everyone until the image itself is parameterized.
- `bin/init.sh` populates `CONTAINER_HOME=/home/john` into `.env` at init time (mirroring the
  `HOST_UID`/`HOST_GID` pattern textually), rather than deriving it from `id -un`. Deriving it
  from the host username would point the mount targets and sync destinations at a path (e.g.
  `/home/alice`) that doesn't match the container's actual `$HOME` (`/home/john`, fixed by the
  out-of-scope image), which would silently break the host-config sync this story must not
  regress (AC1: "no step fails or silently mis-owns files").
- Operators running a *customized* image with a different account can override `CONTAINER_HOME`
  in `.env` - but doing so only works once the image also honors a matching account/`$HOME`,
  which is a separate change outside this story.

This satisfies every acceptance criterion as literally written (no hardcoded `/home/john` left in
`docker-compose.yml`/`bin/*.sh`; `.env` gains the new var the same way `HOST_UID`/`HOST_GID` do;
nothing fails for any host user since UID/GID ownership was already solved) while being honest
that it centralizes and documents the assumption rather than making the tool truly work under an
arbitrary container account - that last step needs the image itself (see Risks).

## Files to add/change

### `bin/init.sh`
Immediately after the existing `HOST_UID`/`HOST_GID` block (`bin/init.sh:13`):
```bash
grep -q '^CONTAINER_HOME=' "$KIT_DIR/.env" || echo "CONTAINER_HOME=/home/john" >> "$KIT_DIR/.env"
```
Same idempotent append pattern, so re-running `init.sh` against a pre-existing `.env` fills in the
new var without requiring the user to delete/recreate the file (AC4).

### `docker-compose.yml`
Top-of-file comment and the `agent.build` block are untouched (out of scope for this story - that
context is `agent-factory-mi3`'s territory). In the `agent.volumes` list, replace all six
`/home/john/...` mount targets with `${CONTAINER_HOME:-/home/john}/...`:
```yaml
    volumes:
      - ${KIT_DIR}:${KIT_DIR}:ro
      - ${PROJECT_DIR}:${PROJECT_DIR}
      - ${PROJECT_DIR}/.agent-factory/claude/${ROLE:-shell}:${CONTAINER_HOME:-/home/john}/.claude
      - ${HOME}/.claude:${CONTAINER_HOME:-/home/john}/.claude-host:ro
      - ai-dev-kit:${CONTAINER_HOME:-/home/john}/.ai-dev-kit
      - ${HOME}/.ai-dev-kit:${CONTAINER_HOME:-/home/john}/.ai-dev-kit-host:ro
      - agents-home:${CONTAINER_HOME:-/home/john}/.agents
      - ${HOME}/.agents:${CONTAINER_HOME:-/home/john}/.agents-host:ro
```
(`${VAR:-default}` is the same compose interpolation syntax already used for
`${HOST_UID:-1000}`/`${HOST_GID:-1000}` a few lines up, so this is consistent with the existing
file, not a new pattern.) Add a short comment above the block noting `CONTAINER_HOME` is populated
by `bin/init.sh` and must match the image's actual account home (see `bin/init.sh` and
`agent-loop.sh`'s own comment for why the default can't just be changed freely).

`CONTAINER_HOME` does not need to be added to the `environment:` block: `env_file: .env` already
forwards every `.env` key into the container, which is how `agent-loop.sh` will read it (see
below), and compose's own `${...}` interpolation in the `volumes:` list is resolved host-side from
the same `.env` file compose already loads for this project.

### `bin/agent-loop.sh`
Add `CONTAINER_HOME` alongside the other env-derived top-of-file vars (same block style as
`IDLE_SLEEP`, `MAX_TURNS`, etc., `bin/agent-loop.sh:20-26`):
```bash
CONTAINER_HOME="${CONTAINER_HOME:-/home/john}"
```
Then in `sync_configs()` (`bin/agent-loop.sh:228-235`), replace the three hardcoded paths:
```bash
sync_configs() {
  (
    flock -w 120 9 || { log "sync lock timed out; skipping host-config sync"; return 1; }
    sync_dir "$CONTAINER_HOME/.claude-host" "${CLAUDE_CONFIG_DIR:-$CONTAINER_HOME/.claude}" "~/.claude"
    sync_dir "$CONTAINER_HOME/.ai-dev-kit-host" "$CONTAINER_HOME/.ai-dev-kit" "~/.ai-dev-kit"
    sync_dir "$CONTAINER_HOME/.agents-host" "$CONTAINER_HOME/.agents" "~/.agents"
  ) 9>"$CONTROL/sync.lock"
}
```
Same derived path used for both source (`*-host` mounts) and destination, matching AC3.

### `.env.example`
No change. `HOST_UID`/`HOST_GID` aren't documented there either (they're silently appended by
`bin/init.sh`); `CONTAINER_HOME` follows the same convention for consistency, so a fresh `.env`
doesn't grow a confusing wall of auto-managed vars that duplicate what `init.sh` already explains
in its own comment/echo output.

### `README.md`
No change needed. It states "container user is `john`" (README.md:31), which stays literally true
(the account itself isn't renamed by this story), so it doesn't go stale.

## Interfaces / data shapes
One new `.env` var, `CONTAINER_HOME` (string, an absolute path), following the exact lifecycle
`HOST_UID`/`HOST_GID` already have: appended by `bin/init.sh` if absent, loaded into the `agent`
container via `env_file: .env`, and read with a `${VAR:-/home/john}` fallback everywhere it's used
so an `.env` from before this change still works with no default-value fallback gap.

## Error cases
- **Pre-existing `.env` without `CONTAINER_HOME`**: every consumer (`docker-compose.yml`,
  `agent-loop.sh`) falls back to the literal default `/home/john`, identical to today's hardcoded
  behavior - no breakage, and `bin/init.sh` fixes it going forward the next time it's run (AC4).
- **User sets `CONTAINER_HOME` to something other than `/home/john` without also changing the
  image**: the mount targets and sync destinations move together (compose and `agent-loop.sh`
  derive from the same var), but the actual `claude`/`bd` processes' real `$HOME` (set by the
  image, still `/home/john`) won't match, so config sync will write to a path those tools don't
  read from. This is a known, documented limitation (see Risks), not a bug to handle defensively
  in this story - the image itself is out of scope.

## Acceptance criteria mapping
1. No step fails for any host user: UID/GID ownership already solved (`bin/init.sh:13`,
   pre-existing); this story additionally stops the repo's own files from hardcoding `john`/
   `/home/john`, verified by AC5's grep.
2. `docker-compose.yml` `agent.volumes` mount targets all use `${CONTAINER_HOME:-/home/john}`.
3. `agent-loop.sh`'s three `sync_dir` calls use `$CONTAINER_HOME`, the same var as #2.
4. `bin/init.sh` appends `CONTAINER_HOME=/home/john` to an existing `.env` that lacks it, same
   idempotent pattern as `HOST_UID`/`HOST_GID`.
5. `grep -rn 'john\|/home/john' docker-compose.yml bin/*.sh` returns nothing once the default
   fallback strings are the only remaining occurrences... **note for QA**: the literal default
   fallback `:-/home/john` intentionally still contains the string `john` and `/home/john` inside
   `docker-compose.yml` and `bin/agent-loop.sh`/`bin/init.sh`. Re-read AC5 against the actual
   story text: it says grepping should show "no matches... in `docker-compose.yml` or `bin/*.sh`".
   Taken completely literally, a fallback default of `/home/john` fails this. See Risks - this is
   flagged, not silently designed around.

## Risks / open questions (flagging, not blocking)
- **AC5 vs. the chosen default, precisely**: AC5 asks for zero occurrences of `john`/`/home/john`
  in `docker-compose.yml`/`bin/*.sh` after the change. A `${CONTAINER_HOME:-/home/john}` fallback
  keeps one occurrence per use site instead of one hardcoded assignment. The alternative -
  defaulting to `id -un`-derived value with no `john` fallback anywhere - would pass AC5 to the
  letter but (as explained in Approach) breaks the host-config sync for the common case, because
  the real image's account is still `john`/`/home/john` regardless of what compose/script code
  says. I judged AC1 (nothing fails) as the higher-priority, harder constraint and AC5 as
  intended to catch *accidental* hardcoding, not a byte-for-byte string ban including safety-net
  defaults - but this is a judgment call, not unambiguous, and QA/reviewer should weigh in if they
  read it differently.
- **Interaction with `story/agent-factory-mi3`**: that story's (already-written, unmerged) design
  adds a `Dockerfile` to this repo that hardcodes the account as `john`/`/home/john` on purpose.
  Once both stories land, the account name is still not actually configurable end-to-end - this
  story only stops *this repo's compose/script code* from re-hardcoding it in more than one place.
  Filing a follow-up issue (`bd dep add ... --type discovered-from` against this story) for
  "parameterize the in-repo Dockerfile's account name/home to match `CONTAINER_HOME`" once
  `agent-factory-mi3` merges - that's the change that would let AC1/AC2's full intent (a
  genuinely different host username working end-to-end) actually hold.

## Test strategy (for QA)
No unit-test framework (see `docs/ARCHITECTURE.md` once `agent-factory-mi3`/`agent-factory-awk`
merges it, or verify the same conventions directly from README if it hasn't yet: this is an
infra/orchestration kit, verification is acceptance-style from the shell). QA should:
1. `grep -n 'john' docker-compose.yml bin/*.sh` - confirm every remaining hit is a
   `${CONTAINER_HOME:-/home/john}` (or `CONTAINER_HOME="${CONTAINER_HOME:-/home/john}"`) fallback,
   not a bare mount target or bare path - i.e. AC5's intent (no *hardcoded* path) holds even
   though the literal string `john` still appears as a documented default.
2. Fresh `.env` flow: remove/rename any existing `.env`, run `bin/init.sh`, confirm the generated
   `.env` contains `CONTAINER_HOME=/home/john` alongside `HOST_UID`/`HOST_GID`.
3. Upgrade flow (AC4): take an `.env` with `HOST_UID`/`HOST_GID` but no `CONTAINER_HOME` (simulate
   pre-this-change state), run `bin/init.sh` again, confirm `CONTAINER_HOME=/home/john` gets
   appended and nothing else in the file is touched/duplicated.
4. `docker compose config` (from `KIT_DIR`, with a `.env` present) and confirm the rendered
   `agent.volumes` targets show `/home/john/...` (default) resolved correctly - i.e. the
   interpolation syntax is valid, not just visually plausible.
5. Override case: set `CONTAINER_HOME=/home/testuser` in `.env`, run `docker compose config`
   again, confirm all six volume targets and (indirectly, can't easily test without a matching
   custom image) the `sync_dir` destinations move together to `/home/testuser/...` - proving #2
   and #3 derive from the *same* var rather than independently hardcoded elsewhere.
6. Full loop smoke test (if time allows, matches README "Before running unattended"): default
   `.env` (`CONTAINER_HOME=/home/john`), `bin/init.sh && bin/start.sh` against a scratch project,
   confirm a role container still starts, syncs host `~/.claude`/`~/.ai-dev-kit`/`~/.agents`, and
   reaches its "started: role=..." log line - i.e. this refactor caused no regression versus
   today's hardcoded behavior.

## Engineer task split
Single engineer issue - `bin/init.sh`, `docker-compose.yml`, and `bin/agent-loop.sh` are one
small, tightly-coupled change (one new var threaded through three files); splitting them would
just add handoff overhead.
