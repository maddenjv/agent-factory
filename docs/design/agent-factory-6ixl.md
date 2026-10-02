# agent-factory-6ixl: bin/init.sh completes setup in one run - design

## Approach
Only `bin/init.sh` changes. Three edits, no change to `.env.example`, `init-project.sh`, or the kit `.gitignore`.

### 1. Don't stop after creating the starter `.env` (AC1, AC2, AC6)
In the `[ ! -f "$AGENT_ENV_FILE" ]` branch:
- keep the `cp` and the "append HARNESS only when it differs from claude-code" logic untouched (jqn AC4 still
  holds: the file is byte-identical to `.env.example` at creation time on the no-flag path).
- delete the `exit 1`.
- **re-point the variable**: `lib.sh` resolved `AGENT_ENV_FILE` to the not-yet-existing `$KIT_DIR/.env` fallback.
  After the `cp`, add `AGENT_ENV_FILE="$DATA_DIR/.env"; export AGENT_ENV_FILE`. Without this, the HOST_UID/GID/
  HARNESS appends below write to (and create) a stray `$KIT_DIR/.env`, and `dc build agent` / `dc run` use the wrong
  env file. This is the one non-obvious step; the engineer must not skip it.
- replace the message with a non-blocking notice, e.g.:
  `Created $DATA_DIR/.env with defaults (reuses your host ~/.claude login - no edits needed). Optional settings (CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY, models, budget) can be edited there; if you change any, re-run bin/init.sh afterwards. Continuing setup...`
  It must contain the file path, the word "optional", and "re-run bin/init.sh".

The code after the branch (HOST_* appends, HARNESS record/sed) already runs against `$AGENT_ENV_FILE`, so `--harness`
is recorded in `.env` before `dc build agent`; AC6 needs no further change (build reads HARNESS via the env file).

### 2. Dirty check ignores `.agent-factory/` (AC3, AC4)
Replace the check's status call with a pathspec that excludes the kit's data dir:
```bash
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain -- . ':(exclude).agent-factory')" ]; then
```
(`.agent-factory` is the literal `$DATA_DIR` basename in lib.sh; use `${DATA_DIR#$PROJECT_DIR/}` if that is how lib.sh
derives it, so the two cannot drift.) Pathspec excludes apply to untracked directories, so an untracked
`.agent-factory/` no longer appears; any other change (tracked modification, other untracked file) still does, and
the existing error text and `exit 1` are unchanged, so no scaffolding commit happens (AC4). Update the comment above
the check: it currently claims the check runs before `.agent-factory/` is created - that is no longer true or needed.
The check stays after `.env` creation (the `.env` is harmless to keep if the user then has to commit/stash; the re-run
sees it, skips creation, and proceeds).

### 3. Idempotence (AC5)
Second-run path is the existing one: `.env` exists -> skipped; HOST_*/HARNESS use grep-guards; `mkdir -p`, `git config`,
`dc build` (cached), `dc up -d`, and `init-project.sh` (already idempotent, uses `grep -qxF` guards) all re-run safely.
With the exclusion in (2), the post-first-run state (`.agent-factory/` untracked or now gitignored plus the scaffolding
commit made by init-project.sh) passes the clean check.

## Interaction with existing tests
`tests/acceptance/agent-factory-jqn.sh` (and any test asserting "first run exits 1 / message says edit then re-run")
encodes the old behaviour. QA must update those assertions: first run now exits 0 and proceeds. The AC4 byte-diff vs
`.env.example` must be taken from the `.env` content *before* the HOST_*/HARNESS appends, or compare via `grep -v` of
the appended keys / stub `dc` and inspect at the point of creation.

## Test strategy (QA)
Bash acceptance tests in the existing style, with `dc` stubbed (PATH-stub `docker` recording calls) and a temp git
project + temp kit copy:
- AC1: clean project, no `.agent-factory/` -> exit 0, `docker compose build agent`, `up -d dolt`, init-project run, output ends with "Done. Next:".
  Also assert no `$KIT_DIR/.env` was created (guards the re-point step).
- AC2: stdout contains the `.env` path, "optional", "re-run bin/init.sh".
- AC3: after a first run that stopped before init-project (e.g. stub failing) or with `.agent-factory/` manually present untracked and not gitignored -> re-run passes the dirty check.
- AC4: add `touch other.txt` (and separately modify a tracked file) -> exit 1 with the existing error, `git log` unchanged.
- AC5: run twice; `.env` values (edit a value between runs) preserved, second exit 0.
- AC6: `--harness=copilot` first run -> `.env` has `HARNESS=copilot` before/when `build` is invoked.
Existing tests for `--harness` validation and bad-arg errors remain valid.

## Error cases
Bad args/harness: unchanged (fail before filesystem is touched). Dirty tree: unchanged message. Docker failures: `set -e` aborts as before; re-run is safe.
