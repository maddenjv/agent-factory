# Design: agent-factory-mi3 - Remove claude-code-sandbox dependency

## Approach
Add a `Dockerfile` to this repo that reproduces exactly what `docker-compose.yml`'s `agent`
service actually needs from `claude-code-sandbox` - the toolchain (`claude`, `bd`, `git`, `jq`,
`curl`, `bash`) and a non-root `john` user with configurable UID/GID - and nothing else (not its
`entrypoint.sh`, which every real invocation already overrides; see story Context). Point
`docker-compose.yml`'s `agent.build` at this repo instead of `../claude-code-sandbox`. Update
README's Setup section to match.

This was verified against the architect's own running container (itself built from the sandbox
image), which confirmed the exact toolchain: Debian bookworm, `node:22-bookworm-slim`-family base
(`node`/`npm` present), `@anthropic-ai/claude-code` installed globally via npm, `bd` a
~150MB statically-linked Go binary at `/usr/local/bin/bd` with a `beads -> bd` convenience
symlink (matches `github.com/steveyegge/beads/cmd/bd`'s embedded build string:
`CGO_ENABLED=0 go install -tags gms_pure_go github.com/steveyegge/beads/cmd/bd@latest`), user
`john` uid/gid 1000, `HOME=/home/john`, no `go` toolchain present at runtime (so `bd` must be
built in a throwaway builder stage and copied out, not built in the final image).

## Files to add/change

### `Dockerfile` (new, repo root)
Multi-stage build:

1. **Builder stage** `FROM golang:1.23-bookworm AS bd-builder`
   `RUN CGO_ENABLED=0 go install -tags gms_pure_go github.com/steveyegge/beads/cmd/bd@latest`
   (binary lands at `/root/go/bin/bd`).

2. **Final stage** `FROM node:22-bookworm-slim`
   - `ARG HOST_UID=1000` / `ARG HOST_GID=1000` (matches docker-compose.yml's existing
     `HOST_UID:-1000`/`HOST_GID:-1000` defaults - do not change those defaults).
   - `apt-get update && apt-get install -y --no-install-recommends git jq curl ca-certificates
     && rm -rf /var/lib/apt/lists/*` (bash is already present in the `node` image; do not
     install `sudo`, `tmux`, or anything else `agent-loop.sh`/`board.sh` don't call - `board.sh`
     runs its loop from `bd`/`jq` only, tmux itself runs on the host, not in this container).
   - `RUN npm install -g @anthropic-ai/claude-code` (unpinned - see ARCHITECTURE.md dependency
     policy).
   - `COPY --from=bd-builder /root/go/bin/bd /usr/local/bin/bd`
     `RUN ln -s bd /usr/local/bin/beads`
   - Create the user: `RUN groupadd -g "$HOST_GID" john && useradd -u "$HOST_UID" -g "$HOST_GID"
     -m -s /bin/bash john` (group/user name literally `john`, matching the volumes in
     docker-compose.yml that hardcode `/home/john/...` - do not parameterize the name, only
     UID/GID, since compose already assumes the path).
   - `USER john`
   - `ENV HOME=/home/john`
   - No `ENTRYPOINT`/`CMD` beyond a plain `CMD ["bash"]` - every real caller (docker-compose.yml,
     `bin/init.sh`, `bin/start.sh`) already overrides it (story Context); don't reimplement the
     sandbox's own sync-on-entrypoint behavior, that's `agent-loop.sh`'s `sync_configs()` job
     already (out of scope).

   UID/GID note: if `HOST_UID`/`HOST_GID` collide with an existing entry in the base image's
   `/etc/passwd` or `/etc/group` (uncommon on `node:22-bookworm-slim`, but check when
   implementing), `useradd`/`groupadd` fail loudly - that's fine, no special-casing needed; the
   existing docker-compose.yml defaults (1000/1000) are the common case and already work today
   against the sandbox image built the same way.

### `docker-compose.yml`
- Change the `agent.build` block from:
  ```yaml
  build:
    context: ../claude-code-sandbox
    args:
      HOST_UID: ${HOST_UID:-1000}
      HOST_GID: ${HOST_GID:-1000}
  ```
  to:
  ```yaml
  build:
    context: .
    args:
      HOST_UID: ${HOST_UID:-1000}
      HOST_GID: ${HOST_GID:-1000}
  ```
  (`context: .` resolves relative to this compose file, i.e. `KIT_DIR` - correct since
  `bin/lib.sh`'s `dc` always invokes compose with `-f` pointed at this file, not via `cd`.)
- Update the top-of-file comment block (currently: "Built from the sibling claude-code-sandbox/
  repo (../claude-code-sandbox) so the Claude Code / beads toolchain lives in one place instead
  of a second Dockerfile here.") to describe the self-contained build instead - it should say the
  toolchain is now built from this repo's own `Dockerfile`, and keep the existing explanation of
  why `entrypoint:` overrides it (`agent-loop.sh`, not the image's own entrypoint).
- No other service, volume, or network needs to change.

### `README.md`
In "Setup":
- Replace the "**Requires the sibling repo `../claude-code-sandbox`**..." paragraph - drop the
  sibling-checkout requirement, state that `docker-compose.yml` builds the `agent` image from
  this repo's own `Dockerfile` (self-contained), and keep the rest of that paragraph's point
  (container user is `john`; `agent-loop.sh` overrides the image's default entrypoint and does
  its own host-`~/.claude` sync) since that's still true and unrelated to where the image is
  built from.
- No other section references `claude-code-sandbox` (confirmed - only "Setup" mentions it); leave
  the rest of README unchanged.

## Interfaces / data shapes
None - this story only changes build configuration and docs, no runtime code paths, no new env
vars beyond the already-existing `HOST_UID`/`HOST_GID` build args.

## Error cases
- **Build fails because `golang:1.23-bookworm` or `node:22-bookworm-slim` tags don't exist /
  are deprecated by the time this is implemented**: use whatever current Debian-bookworm-based
  tags are available for Go and Node 22 at implementation time; the specific tag strings above
  are a starting point, not a hard requirement - the constraint that matters is Debian bookworm
  (to match what's already proven to work) and Node 22 (matches the currently-running toolchain,
  verified above).
- **`go install ...@latest` pulls a `bd` that no longer matches the CLI flags `agent-loop.sh`
  uses** (`bd ready --label --limit --json`, `bd update --claim`, etc. - see README "Things I
  could not test" #3): out of scope for this story (pre-existing risk, unrelated to where the
  binary is built), but worth a one-line note in the `Dockerfile` pointing at that README section
  so a future reader knows where to look if `bd` breaks after a rebuild.
- **UID/GID collision** during `useradd`/`groupadd`: let the build fail (see UID/GID note above)
  - do not silently reuse/rename an existing user.

## Acceptance criteria mapping
1. Clean-checkout build succeeds, no external path → `context: .` in docker-compose.yml +
   Dockerfile self-contained (no `COPY --from=` of anything outside the build context, no
   references to `claude-code-sandbox`).
2. `claude --version`, `bd --version`, `git --version`, `jq --version` succeed in container →
   all four installed explicitly in the final stage; verify manually with
   `docker compose run --rm --entrypoint bash agent -lc 'claude --version && bd --version && git --version && jq --version'`.
3. Non-root user, home `/home/john`, UID/GID match build args → `useradd -u "$HOST_UID" -g
   "$HOST_GID" -m ... john`; verify with `docker compose run --rm --entrypoint bash agent -lc 'id; echo $HOME'`.
4. `agent-loop.sh` entrypoint override + host-config sync mounts keep working unchanged → no
   changes to `bin/agent-loop.sh`, `docker-compose.yml`'s `entrypoint:`/`volumes:` for `agent`
   (only `build:` changes), or the `*-host` mount paths.
5. README no longer requires `../claude-code-sandbox` → Setup section rewritten as above.

## Test strategy (for QA)
No unit-test framework applies (see ARCHITECTURE.md). QA should verify at the shell, from a
clean checkout with no `../claude-code-sandbox` sibling present:
1. `cd` to KIT_DIR, confirm `.env` has `HOST_UID`/`HOST_GID` set (or let `bin/init.sh` set them
   from `id -u`/`id -g`), then `docker compose build agent` (or `bin/init.sh`) - must succeed,
   and `docker history`/build log must show no `COPY --from=` or build context outside this repo.
2. `docker compose run --rm --entrypoint bash agent -lc 'claude --version && bd --version &&
   git --version && jq --version'` - all four must print a version and exit 0.
3. `docker compose run --rm --entrypoint bash agent -lc 'id -u; id -g; id -un; echo $HOME'` -
   uid/gid must equal `HOST_UID`/`HOST_GID` (default 1000/1000), username `john`, home
   `/home/john`.
4. Run the existing flow once (`bin/init.sh` then `bin/start.sh` against a scratch test project,
   or at minimum `docker compose run --rm agent` with `ROLE` set) and confirm
   `agent-loop.sh` still starts, syncs host `~/.claude`/`~/.ai-dev-kit`/`~/.agents`, and reaches
   its "started: role=..." log line - i.e. nothing about the sync-and-run flow broke.
5. `grep -r claude-code-sandbox README.md` returns nothing.

## Engineer task split
Single engineer issue - the Dockerfile, docker-compose.yml edit, and README edit are one small,
tightly-coupled change; splitting them would just add handoff overhead.
