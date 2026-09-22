# agent-factory-jqn: .env per project — design

## Approach

Resolve a single effective `.env` path per invocation — `PROJECT_DIR/.agent-factory/.env` if it
exists, else `KIT_DIR/.env` — and thread that one path through to every place Compose currently
hardcodes `.env`. No merging: whichever file is picked is the only one loaded, satisfying AC3.

The resolution lives in one place, `bin/lib.sh` (already sourced by every host-side script), as a
new exported variable `AGENT_ENV_FILE`. Everything downstream (docker-compose.yml's `env_file:`,
`start.sh`'s per-pane `docker compose run` invocations) reads that variable instead of a literal
`.env`.

## Files/modules to change

### `bin/lib.sh`
After `DATA_DIR` is computed, add:
```bash
AGENT_ENV_FILE="$DATA_DIR/.env"
[ -f "$AGENT_ENV_FILE" ] || AGENT_ENV_FILE="$KIT_DIR/.env"
export AGENT_ENV_FILE
```
Both `DATA_DIR` and `KIT_DIR` are already absolute at this point, so `AGENT_ENV_FILE` is always
absolute — no reliance on Compose's relative-path resolution rules. This is a plain existence
check computed once per script invocation; nothing here creates the file (that stays init.sh's
job, see below), so a script run before `init.sh` has ever created *either* file simply resolves
to the (not-yet-existing) `KIT_DIR/.env`, same as `dc()` already tolerates today for other
not-yet-created paths.

Add a one-line comment above it explaining the precedence, matching this file's existing comment
density (it already explains KIT_DIR vs PROJECT_DIR at length).

### `bin/init.sh`
Today: creates `$KIT_DIR/.env` unconditionally as the only location. Change to:
```bash
mkdir -p "$DATA_DIR"   # moved up: AGENT_ENV_FILE's project-level candidate must exist to test for
if [ ! -f "$AGENT_ENV_FILE" ]; then
  # AGENT_ENV_FILE only falls back to $KIT_DIR/.env when that file already exists (see lib.sh),
  # so reaching this branch means NEITHER exists yet - starter goes at the project-level path,
  # the location new projects should use going forward.
  cp "$KIT_DIR/.env.example" "$DATA_DIR/.env"
  echo "Created $DATA_DIR/.env - defaults to reusing your host ~/.claude login (no key needed); edit it only if you want a separate CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY instead, then re-run bin/init.sh"
  exit 1
fi
grep -q '^HOST_UID=' "$AGENT_ENV_FILE" || { echo "HOST_UID=$(id -u)" >> "$AGENT_ENV_FILE"; echo "HOST_GID=$(id -g)" >> "$AGENT_ENV_FILE"; }
```
Notes:
- `mkdir -p "$DATA_DIR"` is idempotent and harmless to run this early; the rest of init.sh's
  `mkdir -p "$DATA_DIR/workspaces/$r" ...` block later is unaffected (still needed for the
  per-role subdirectories).
- The existing "repo must be clean" check further down in init.sh runs *after* this, same as
  today — creating `$DATA_DIR` itself doesn't dirty `git status` because `.agent-factory/` is
  gitignored (`bin/init-project.sh:36`), so ordering here doesn't reintroduce the problem that
  comment warns about.
- `AGENT_ENV_FILE` is resolved once when `lib.sh` is sourced at the top of `init.sh`. On a truly
  first run (neither file exists) it resolves to `$KIT_DIR/.env` (the fallback branch, per
  `lib.sh`'s logic), so the `[ ! -f "$AGENT_ENV_FILE" ]` check above correctly reads as "neither
  the project's own `.env` nor the kit's exists" - it does not need to be re-resolved after the
  `cp`, because that branch always `exit 1`s immediately after, telling the operator to edit and
  re-run. On the re-run, `lib.sh` resolves `AGENT_ENV_FILE` fresh and finds the project-level file
  that now exists.
- AC5 (pre-existing `KIT_DIR/.env` from before this change): on re-running `init.sh` against an
  established project that has only ever had a kit-level `.env`, `lib.sh` resolves
  `AGENT_ENV_FILE` to `$KIT_DIR/.env` (no project-level file exists), so the `[ ! -f ... ]` guard
  is false, the `HOST_UID` grep/append targets the kit file as before, and nothing about that
  project's setup changes. No migration step, per AC5.

### `docker-compose.yml`
Change the `agent` service's:
```yaml
    env_file: .env
```
to:
```yaml
    env_file: ${AGENT_ENV_FILE:?run via bin/lib.sh's dc() or export AGENT_ENV_FILE yourself}
```
Using Compose's `${VAR:?msg}` interpolation (fails fast with `msg` if unset) rather than a silent
default — this service is documented as "always invoked via bin/lib.sh's dc()" already (see the
file's own header comment), so an unset `AGENT_ENV_FILE` means something bypassed that contract
and should fail loudly rather than silently pick up whatever relative `.env` happens to sit next
to the compose file (the exact bug this story removes).

### `bin/start.sh`
`pane()` builds each `docker compose run` command as a literal string for tmux, and already
spells out `PROJECT_DIR`/`KIT_DIR` explicitly in that string rather than relying on tmux to
inherit the calling shell's exported environment (see its existing comment). `AGENT_ENV_FILE`
needs the same treatment - add it alongside the other two:
```bash
local cmd="PROJECT_DIR='$PROJECT_DIR' KIT_DIR='$KIT_DIR' AGENT_ENV_FILE='$AGENT_ENV_FILE' ROLE=$role docker compose -f '$KIT_DIR/docker-compose.yml' run --rm --name factory-$title $*"
```
The `ops_cmd` string later in the same file (used for the `ops` window) needs the identical
addition.

### `bin/lib.sh`'s `dc()`
No change needed - it's a thin wrapper around `docker compose -f ...`, and `AGENT_ENV_FILE` is
already exported into the environment by the time `dc()` runs, so Compose picks it up for
interpolation automatically (unlike `start.sh`'s tmux case, `dc()` calls run as direct children of
the sourcing shell).

### `README.md`
Update the "Setup" section (AC6):
- Line 36 (`**KIT_DIR** ... .env lives here.`): drop the `.env` claim from the KIT_DIR bullet.
- Line 41-42 (PROJECT_DIR bullet, "All of agent-factory's own runtime state ... lives under
  `<project>/.agent-factory/`"): add that a project's own `.env` lives there too, alongside a new
  short paragraph explaining the precedence: project `.env` if present, else the kit-level one,
  no merging - point at this story's AC3 behavior in plain language (two files, never both).
- Line 46 (`# first run creates KIT_DIR/.env; ...`): update to say the starter `.env` is created
  at the project-level path (`<project>/.agent-factory/.env`) on first run, kit-level only
  persists for projects that already had one before this change.
- Security notes section (~line 88, "put no other credentials in `.env`"): no behavior change
  needed there, just confirm it still reads correctly once "which .env" is ambiguous - probably
  fine as-is since it's talking about contents, not location, but worth a glance when implementing
  in case it needs "whichever `.env` is in effect for a project" wording.

## Data shapes / interfaces

No new data shapes. One new convention: `AGENT_ENV_FILE` (absolute path, exported by `lib.sh`,
consumed by `docker-compose.yml` and `start.sh`).

## Error cases

- Neither project nor kit `.env` exists, first run: handled by existing `init.sh` "created .env,
  edit and re-run" flow, now pointed at the project-level path (AC4).
- `AGENT_ENV_FILE` unset because something invoked `docker compose -f docker-compose.yml ...`
  directly without sourcing `lib.sh`: Compose's `${AGENT_ENV_FILE:?...}` fails immediately with an
  explanatory message rather than silently reading an unintended file.
- Project `.env` present but incomplete (only sets some vars): by design, no fallback merge -
  Compose loads exactly that file into the container; variables it doesn't set are simply absent
  in the container (or fall back to whatever default the *consuming code* has, e.g.
  `${HOST_UID:-1000}` in `docker-compose.yml` itself, which is a Compose-file-level default, not a
  cross-`.env`-file merge, so it doesn't violate AC3).

## How each acceptance criterion is satisfied

1. Project `.env` present → `lib.sh` resolves `AGENT_ENV_FILE` to it → `docker-compose.yml`'s
   `env_file:` loads exactly that file into the container.
2. No project `.env` → `lib.sh` falls back to `$KIT_DIR/.env`, unchanged from today's single-file
   behavior.
3. Resolution picks exactly one file (`if/else`, never both); Compose's `env_file:` here is a
   single scalar path, not a list, so there's no code path that could merge two files.
4. `init.sh` creates the starter at `$DATA_DIR/.env` (project-level) when neither file exists yet.
5. `init.sh`/`lib.sh` only prefer the project-level file when it exists; an established project
   with only a kit-level `.env` keeps resolving to it, untouched, with zero migration steps.
6. README's Setup section updated to describe both locations and the precedence/no-merge rule.

## Test strategy (for QA)

This is the infra kit's usual acceptance-style verification (`docs/ARCHITECTURE.md`'s "Test
strategy" - no unit-test framework). QA should specify exact host-shell commands and expected
output, at minimum:

- **Fallback (AC2, AC5)**: with only `$KIT_DIR/.env` present (containing a distinctive
  `MODEL_ENGINEER` value) and no project-level `.env`, start a container (`dc run --rm
  --entrypoint bash agent -lc 'echo $MODEL_ENGINEER'`) and assert the kit-level value comes
  through.
- **Override (AC1)**: create `$DATA_DIR/.env` with a *different* `MODEL_ENGINEER` value than the
  kit-level file, run the same probe, assert the project-level value wins.
- **No partial merge (AC3)**: project `.env` sets `MODEL_ENGINEER` only; kit `.env` separately
  sets some other var, e.g. `NOTIFY_URL`, to a distinctive value; assert `NOTIFY_URL` is *absent*
  (not the kit's value) inside a container started against that project.
- **Fresh init (AC4)**: run `init.sh` from a scratch project directory with neither `.env` present
  (temp `KIT_DIR` copy or a `.env`-less checkout); assert it creates `$DATA_DIR/.env` (not
  `$KIT_DIR/.env`), exits 1, and prints a message naming that path.
- **start.sh path (AC1/AC2 via tmux)**: since `pane()`/`ops_cmd` build command strings by hand,
  specifically verify `bin/start.sh`'s spawned panes also see the right value (not just `dc()`
  invocations) - e.g. probe via a pane's container the same way, or `tmux capture-pane`.
- **README**: no executable check; QA can eyeball that Setup describes both paths and the
  precedence rule (AC6 has no shell-verifiable behavior of its own beyond what AC1/AC2/AC3 already
  cover).
- `shellcheck` the diff on `bin/lib.sh`, `bin/init.sh`, `bin/start.sh` per
  `docs/ARCHITECTURE.md`'s conventions.

## Out of scope reminders (carried from the story)

No changes to `.env`/`.env.example` contents, no third env-file layer, no change to any other
`DATA_DIR` subdirectory's location, no secrets handling changes.
