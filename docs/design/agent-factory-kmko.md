# Design: agent-factory-kmko - bin/init.sh without a git identity

## Root cause
`bin/init-project.sh` runs inside a throwaway `agent` container (`dc run --rm ... init-project.sh`
from `bin/init.sh`) and makes the scaffolding commit there. The container mounts only
`~/.claude`, `~/.copilot`, `~/.ai-dev-kit`, `~/.agents` - never the host's `~/.gitconfig` - and
`init-project.sh` sets only `safe.directory`. So the container has *no* identity ever; the commit
aborts with "Author identity unknown" regardless of whether the user has configured one on the
host (AC3 therefore also needs the host identity carried in).

## Approach
Resolve the identity host-side, hand it to the container as git's own environment variables, and
fall back to a factory default per missing field. Env vars (`GIT_AUTHOR_*`, `GIT_COMMITTER_*`)
affect only that process, so no git config at any level is written (AC2). Do NOT use
`git config` (global or local) or `git commit -c user.name=...` workarounds that persist anything,
and do not mount the host `~/.gitconfig` (keeps the container-hardening stance in
docker-compose.yml).

### `bin/init.sh` (host side)
Just before the `dc run ... init-project.sh` line:

```bash
# Identity for init-project.sh's scaffolding commit. The container can't see your ~/.gitconfig,
# so resolve it here (git's own lookup, all levels, from PROJECT_DIR) and pass it in as env vars
# - which, unlike `git config`, never write anything to your git configuration. Each half falls
# back on its own, so having only user.name or only user.email set still works.
git_name=$(git -C "$PROJECT_DIR" config user.name 2>/dev/null || true)
git_email=$(git -C "$PROJECT_DIR" config user.email 2>/dev/null || true)
git_name=${git_name:-${GIT_AUTHOR_NAME:-agent-factory}}
git_email=${git_email:-${GIT_AUTHOR_EMAIL:-agent-factory@factory.local}}

dc run --rm \
  -e GIT_AUTHOR_NAME="$git_name" -e GIT_AUTHOR_EMAIL="$git_email" \
  -e GIT_COMMITTER_NAME="$git_name" -e GIT_COMMITTER_EMAIL="$git_email" \
  --entrypoint bash agent "$KIT_DIR/bin/init-project.sh"
```

Notes:
- `git config user.name` with no value exits 1 -> `|| true` keeps `set -e` happy (check that
  init.sh runs with `set -e`; the idiom is safe either way).
- Precedence: configured identity (any level) > host `GIT_AUTHOR_*` env > factory default.
  The default only ever fills a *missing* half, so a user's identity is never overridden (AC3, AC4).
- Committer is set equal to author; fine for a one-off scaffolding commit.
- `-e` goes before the service name (docker compose `run` option position). Place it adjacent to
  `--rm`.

### `bin/init-project.sh` (container side)
No identity logic needed; env vars are inherited by `git commit`. Make it robust when run without
them (e.g. someone invoking it directly, tests) by defaulting only if unset, still via env, not config:

```bash
# Identity comes from bin/init.sh (host's own, or a factory default). Defaults here only cover a
# direct invocation; env vars, never `git config`, so nothing is persisted.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-agent-factory}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-agent-factory@factory.local}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"
```
placed right after `cd "$PROJECT_DIR"`. Leave the `git config --global --add safe.directory '*'`
line as is (container-local HOME, not the user's config). Leave the commit / "already present"
logic untouched (AC5).

## Acceptance criteria mapping
1. No identity anywhere -> defaults supplied via env -> commit succeeds, exit 0.
2. Only env vars are used; no `git config` writes beyond the existing container-local
   safe.directory. Global/system/local config files byte-identical before/after.
3. Configured identity read by `git config user.name/user.email` (effective value incl. includeIf,
   local, global, system) -> author and committer of the commit.
4. Per-field fallback -> either one alone works, and the configured half is kept.
5. Unchanged `git diff --cached --quiet` branch.

## Error cases
- Empty-string user.name configured: `${var:-default}` treats as unset -> default (git would reject
  empty anyway).
- Host env `GIT_AUTHOR_NAME` set but no config: honoured by the fallback chain.

## Test strategy
Per ARCHITECTURE.md: shell test `tests/agent-factory-kmko_test.sh`, no Docker required.
- Static/grep level: init.sh passes the four `GIT_*` vars into the `dc run` that invokes
  init-project.sh, and neither script contains `git config` writes of user.name/user.email
  (only the safe.directory one).
- Behavioural: run `bin/init-project.sh` directly (stub `bd` on PATH, `KIT_DIR` = repo, tmp
  git repo on `main`) with `HOME`/`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`
  and no identity: exit 0, commit on main exists with author `agent-factory`. Re-run: exit 0 and
  prints "already present". Checksum `.git/config` before/after (AC2).
- Identity cases: pass `GIT_AUTHOR_*` env as init.sh would (and set a local identity in the
  tmp repo for the host-resolution snippet, extracted/tested via a function or by stubbing `dc`
  to capture its args) -> commit author equals the configured one; only-name and only-email cases.
- Stubbing `dc` and running init.sh's resolution part is the way to cover AC3/AC4 end to end;
  if init.sh is hard to run under test, factor the four resolution lines into `resolve_git_identity`
  in `bin/lib.sh` (prints `name<TAB>email`) so it can be sourced and tested directly - engineer's
  call.
