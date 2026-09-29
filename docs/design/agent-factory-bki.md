# agent-factory-bki: harness-select CLI flag — design

## Approach

Add one new setup-time setting, `HARNESS` (`claude-code` default, or `copilot`), selected via a
`--harness=<value>` flag on `bin/init.sh` and persisted into `.env` exactly the way `HOST_UID`/
`HOST_GID`/`HOST_USER`/`CONTAINER_HOME` already are — no new per-invocation flag on `start.sh` or
`agent-loop.sh` (per the story). `HARNESS` then flows two ways, both already-existing plumbing:

- **Build time**: a new `HARNESS` build arg (parallel to `HOST_UID` etc.) picks which CLI the
  `Dockerfile` installs.
- **Run time**: `HARNESS` arrives in every role's container the same way `MODEL_<ROLE>` already
  does — as a plain `env_file`-sourced variable, no new mechanism — and `agent-loop.sh` branches
  on it at the handful of places that are genuinely CLI-specific (the session invocation, the
  preflight check, cost extraction, quota-text matching). Everything else — `build_prompt()`,
  `agents/<role>.md` content, Beads, git, the outcome/failure/circuit-breaker logic — stays
  exactly as it is today, since none of it is harness-specific (per the story's "Out of scope").

I looked up GitHub Copilot CLI's actual invocation (binary `copilot`, npm package `@github/copilot`)
against current GitHub docs and third-party write-ups (no live CLI available to test against here —
see "Verification needed at implementation time" below, same spirit as README's existing "Things I
could not test"):
- Non-interactive: `copilot -p "<prompt>"` (same `-p` shape as `claude -p`), `-s` for
  quiet/pipe-friendly plain-text output (no decoration/banner), `--no-ask-user` to never block on a
  clarifying question, `--allow-all-tools` for full tool permission with no per-call approval
  prompt — the Copilot equivalent of `--dangerously-skip-permissions` (README already documents
  that Claude Code sessions run with full permissions inside the container; this keeps the same
  security posture, container-as-sandbox, not per-tool prompts).
- Auth: `COPILOT_GITHUB_TOKEN` / `GH_TOKEN` / `GITHUB_TOKEN` env var (fine-grained PAT with the
  "Copilot Requests" permission, or an OAuth/GitHub-App token — classic `ghp_` PATs are rejected),
  checked in that order, OR an interactive/device-code login (`copilot login`) that persists into
  `~/.copilot`. This mirrors `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY` vs. reusing
  `~/.claude` exactly — see "Auth / host-config sync" below.
- There is no documented structured event stream (no `stream-json` equivalent), no documented
  per-session USD cost figure, and no confirmed equivalent of `--max-turns`. Each is called out
  below with the concrete, conservative choice made instead of guessing.

## Files/modules to change

### `bin/init.sh` — flag parsing, validation, persistence

Insert immediately after `source .../lib.sh` (before anything touches the filesystem, so an
invalid flag never creates so much as `$DATA_DIR` — AC6):

```bash
HARNESS_FLAG=""
for arg in "$@"; do
  case "$arg" in
    --harness=*) HARNESS_FLAG="${arg#--harness=}" ;;
    *) echo "error: unrecognized argument: $arg (expected --harness=claude-code or --harness=copilot)" >&2; exit 1 ;;
  esac
done
case "$HARNESS_FLAG" in
  ""|claude-code|copilot) ;;
  *) echo "error: --harness must be 'claude-code' or 'copilot' (got '$HARNESS_FLAG')" >&2; exit 1 ;;
esac
```

Then, in the existing `if [ ! -f "$AGENT_ENV_FILE" ]; then ... fi` first-run branch (today: copy
`.env.example`, print a message, `exit 1` so the operator can edit auth settings before
re-running) — add the persistence *inside* that branch too, since first-run exits before reaching
the `HOST_UID`-style append block below it:

```bash
cp "$KIT_DIR/.env.example" "$DATA_DIR/.env"
echo "HARNESS=${HARNESS_FLAG:-claude-code}" >> "$DATA_DIR/.env"
echo "Created $DATA_DIR/.env - defaults to reusing your host ~/.claude login (no key needed); edit it only if you want a separate CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY instead, then re-run bin/init.sh"
exit 1
```

And alongside the existing `HOST_UID`/`HOST_GID`/`HOST_USER`/`CONTAINER_HOME` append block (for
every run after the first, whether or not `.env` already had a `HARNESS=` line):

```bash
if [ -n "$HARNESS_FLAG" ]; then
  if grep -q '^HARNESS=' "$AGENT_ENV_FILE"; then
    sed -i "s/^HARNESS=.*/HARNESS=$HARNESS_FLAG/" "$AGENT_ENV_FILE"
  else
    echo "HARNESS=$HARNESS_FLAG" >> "$AGENT_ENV_FILE"
  fi
else
  grep -q '^HARNESS=' "$AGENT_ENV_FILE" || echo "HARNESS=claude-code" >> "$AGENT_ENV_FILE"
fi
```

This makes `--harness=copilot` work whether it's given on the very first `init.sh` call or a
later one, makes re-running with a different `--harness` value switch the project (the unconditional
`dc build agent` a few lines later then rebuilds the image with the new value — no extra code
needed for "switch harness later", it falls out of existing behavior), and leaves an
already-configured project's harness untouched when `init.sh` is re-run with no flag (AC1's "no
flag required to keep working exactly as before" applies to re-runs too, not just fresh ones).

Not in scope to add: a `--help` flag. The error message on a bad/missing-value flag already names
the accepted values (AC6).

### `.env.example` — no new line

Deliberately not added here, same reasoning as `HOST_UID`/`CONTAINER_HOME` (which also aren't in
`.env.example` — they're machine/setup facts `init.sh` records, not a knob meant for casual hand
editing). Unlike `MODEL_<ROLE>`, hand-editing `HARNESS=` in an existing `.env` without rebuilding
would desync it from the already-built image (the Dockerfile choice is baked in at build time) —
worth a comment in README rather than inviting hand-edits in `.env.example`.

### `Dockerfile`

```dockerfile
ARG HOST_UID=1000
ARG HOST_GID=1000
ARG HOST_USER=agent
ARG HARNESS=claude-code
```

Replace the single `RUN npm install -g @anthropic-ai/claude-code` with:

```dockerfile
RUN case "$HARNESS" in \
      claude-code) npm install -g @anthropic-ai/claude-code ;; \
      copilot) npm install -g @github/copilot ;; \
      *) echo "error: unknown HARNESS '$HARNESS' (expected claude-code or copilot)" >&2; exit 1 ;; \
    esac
```

`bd`/`beads`, `git`, `jq`, `curl`, `shellcheck` installs are unaffected — harness-independent.
Base image (`node:bookworm-slim`) already satisfies Copilot CLI's Node 22+ requirement per
`docs/ARCHITECTURE.md`'s existing note that it tracks the `node:22-bookworm-slim` family.

### `docker-compose.yml`

Add the build arg (parallel to the three already there):

```yaml
    build:
      context: .
      args:
        HOST_UID: ${HOST_UID:-1000}
        HOST_GID: ${HOST_GID:-1000}
        HOST_USER: ${HOST_USER:-agent}
        HARNESS: ${HARNESS:-claude-code}
```

Auth / host-config sync — add a `.copilot` mount pair parallel to the existing `.claude` one (same
per-role-live-volume + shared-host-readonly-mount pattern `agent-loop.sh`'s `sync_configs()`
already reproduces for `.claude`, `.ai-dev-kit`, `.agents`):

```yaml
      - ${PROJECT_DIR}/.agent-factory/copilot/${ROLE:-shell}:${CONTAINER_HOME:-/home/${HOST_USER:-agent}}/.copilot
      - ${HOME}/.copilot:${CONTAINER_HOME:-/home/${HOST_USER:-agent}}/.copilot-host:ro
```

(placed next to the existing `.claude`/`.claude-host` lines). This lets a project configured for
`copilot` reuse a host `copilot login` session the same zero-config way Claude Code reuses
`~/.claude` today; setting `COPILOT_GITHUB_TOKEN`/`GH_TOKEN`/`GITHUB_TOKEN` in `.env` (documented
in README next to `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`) works too, same as today's
API-key escape hatch. Mounting/syncing both `.claude*` and `.copilot*` unconditionally regardless
of `HARNESS` is deliberate — simpler than conditional volumes, and harmless (the unused one is
just an empty synced directory).

### `bin/init.sh` — mkdir for the new per-role config dir

Alongside the existing `for r in po architect qa engineer reviewer; do mkdir -p
"$DATA_DIR/workspaces/$r" "$DATA_DIR/claude/$r"; done`, add `"$DATA_DIR/copilot/$r"` to the same
mkdir. (Note: this loop doesn't include `team-lead`, so `team-lead`'s own `.claude`/`.copilot` dir
is never pre-created and Docker auto-vivifies the bind-mount source instead — that's a
pre-existing gap unrelated to this story; file a `discovered-from` issue rather than fixing it
here, per CLAUDE.md.)

### `bin/init-project.sh` — `bd setup <recipe>`

Line 70, `bd setup claude >/dev/null 2>&1 || true`, becomes harness-aware (`bd`'s built-in recipes
include both `claude` and `copilot` — confirmed via `bd setup --help`):

```bash
case "${HARNESS:-claude-code}" in
  copilot) bd setup copilot >/dev/null 2>&1 || true ;;
  *) bd setup claude >/dev/null 2>&1 || true ;;
esac
```

`HARNESS` is already present in this script's environment by the time it runs — `init.sh` writes
it into `$AGENT_ENV_FILE` before calling `dc run --rm --entrypoint bash agent
"$KIT_DIR/bin/init-project.sh"`, and that `run` picks up the `agent` service's `env_file:`
exactly like every other role's session does.

### `bin/agent-loop.sh` — the harness dispatch itself

Read and validate near the top, with the other `${VAR:-default}` settings (after `ROLE`):

```bash
HARNESS="${HARNESS:-claude-code}"
case "$HARNESS" in
  claude-code|copilot) ;;
  *) echo "error: HARNESS=$HARNESS not recognized (expected claude-code or copilot) - re-run bin/init.sh --harness=<value>" >&2; exit 1 ;;
esac
```

**Model-tier defaults** (lines 35-49 today): Claude Code's tier defaults (`sonnet`/`opus`) are not
valid Copilot CLI model identifiers. Rather than hardcode Copilot model IDs I can't confirm are
current (models/IDs change; I found no single authoritative current list — see "Verification
needed" below), make the *defaults* harness-conditional and leave Copilot's empty unless the
operator sets one:

```bash
if [ "$HARNESS" = "copilot" ]; then
  TIER_TEAM_LEAD="${TIER_TEAM_LEAD:-}"
  TIER_STANDARD="${TIER_STANDARD:-}"
else
  TIER_TEAM_LEAD="${TIER_TEAM_LEAD:-opus}"
  TIER_STANDARD="${TIER_STANDARD:-sonnet}"
fi
```

The rest of the resolution block (`MODEL_<ROLE>` override, falling back to the tier) is unchanged.
`MODEL` can now legitimately end up empty under `copilot` (no override, no tier default) — the
existing `[ -n "$MODEL" ] && args+=(--model "$MODEL")` pattern (see below) already handles that by
omitting `--model` entirely, which means Copilot CLI's own built-in default model applies. Update
the startup log line to show which harness is active:

```bash
log "started: role=$ROLE harness=$HARNESS model=${MODEL:-<harness default>} max_turns=$MAX_TURNS timeout=$ITERATION_TIMEOUT"
```

**Session invocation** (`run_claude_session()`, lines 236-253): split into a harness dispatch.
Keep the function name `run_claude_session` unchanged is misleading now — rename to
`run_harness_session()` (only two call sites, `run_agent()`/`run_throttle_assessment()`, both in
this same file):

```bash
run_harness_session() {
  local logname=$1 prompt=$2 logfile errfile outfile cost
  errfile=$(mktemp); outfile=$(mktemp)
  if [ "$HARNESS" = "copilot" ]; then
    logfile="$LOGDIR/$(date +%F).$logname.log"   # plain text, not stream-json - see below
    local args=(-p "$prompt" --allow-all-tools --no-ask-user -s)
    [ -n "$MODEL" ] && args+=(--model "$MODEL")
    ( cd "$REPO" && timeout "$ITERATION_TIMEOUT" copilot "${args[@]}" 2>"$errfile" ) \
      | tee -a "$logfile" "$outfile"
    cost=0   # see "Cost tracking" below
    LAST_RUN_QUOTA_MSG=$(quota_hit_message "$errfile")
  else
    logfile="$LOGDIR/$(date +%F).$logname.jsonl"
    local args=(-p "$prompt" --dangerously-skip-permissions --max-turns "$MAX_TURNS"
                --output-format stream-json --verbose)
    [ -n "$MODEL" ] && args+=(--model "$MODEL")
    ( cd "$REPO" && timeout "$ITERATION_TIMEOUT" claude "${args[@]}" 2>"$errfile" ) \
      | tee -a "$logfile" "$outfile" | jq -R -r --unbuffered "$RENDER" 2>/dev/null
    cost=$(jq -rs '[.[] | select(.type=="result")] | last | .total_cost_usd // 0' "$logfile" 2>/dev/null)
    LAST_RUN_QUOTA_MSG=$(quota_hit_message "$errfile")
    [ -n "$LAST_RUN_QUOTA_MSG" ] || LAST_RUN_QUOTA_MSG=$(quota_hit_from_stream "$outfile")
  fi
  echo "${cost:-0}" >> "$CONTROL/cost/$ROLE.$(date +%F)"
  cat "$errfile" >> "$LOGDIR/claude-err.log"
  rm -f "$errfile" "$outfile"
}
run_agent() { run_harness_session "$1" "$(build_prompt "$1")"; }
run_throttle_assessment() { run_harness_session throttle "$(build_throttle_prompt)"; }
```

(`$LOGDIR/claude-err.log` filename left as-is rather than renamed — it's an internal log path, no
observable behavior depends on its name, and renaming it is pure churn.)

**`MAX_TURNS`**: no confirmed Copilot CLI equivalent (candidate flags like
`--max-autopilot-continues` turned up in secondary sources, not primary docs, with unconfirmed
semantics). Deliberately **not** wired up — passing a guessed flag name risks Copilot rejecting
every single invocation outright, which is worse than not capping turn count. `timeout
"$ITERATION_TIMEOUT"` (already wraps the invocation regardless of harness) remains the hard stop
that guarantees a session cannot run forever; it's the primary safety property, not a Claude-only
backstop, so this is not a safety regression. Engineer: confirm against `copilot --help` at
implementation time — if a real turn/continuation cap flag exists, wire it in and note it in the
handoff comment; if not, say so explicitly rather than leaving it ambiguous.

**Cost tracking**: Copilot CLI has no documented per-session USD figure in headless text output
(GitHub bills/meters Copilot via subscription premium-request quota, not a `$`-denominated
CLI-reported cost per call, unlike Claude Code's `total_cost_usd` stream-json field). Recording
`0` per session means `DAILY_BUDGET_USD` is **not a real spend cap under `HARNESS=copilot`** —
document this explicitly (README "Guardrails built in" and "Security notes" — see below) rather
than fabricate a number. Operators who need a hard Copilot spend cap should use GitHub's own
Copilot Premium Requests budget setting (account-level, independent of this repo).

**Quota/usage-limit detection**: `quota_hit_message()` (lines 167-170) gets a harness-conditional
pattern instead of one fixed regex — call sites (`quota_hit_message "$errfile"` /
`quota_hit_message <(printf '%s' "$preflight_out")`) are unchanged:

```bash
quota_hit_message() {  # quota_hit_message FILE... -> first matching line (bounded, single-line), or empty
  local pattern
  if [ "$HARNESS" = "copilot" ]; then
    pattern='quota_exceeded|you have no quota[^"]{0,200}|exceeded your [a-z]+ rate limit[^"]{0,200}|reached the rate limit[^"]{0,200}'
  else
    pattern='hit your [a-z]+ limit[^"]{0,200}|usage limit[^"]{0,200}|limit reached[^"]{0,200}|rate limit exceeded[^"]{0,200}'
  fi
  grep -ihEo "$pattern" "$@" 2>/dev/null \
    | head -1 | tr -d '\r' | tr '\n\t' '  ' | cut -c1-200
}
```

`quota_hit_from_stream()` stays Claude-only (only called from the `else` branch above) — it exists
specifically because Claude Code's stream-json gives a *structured* boundary (the final
`is_error:true` `result` event) that safely distinguishes "this session ended on a real quota
error" from "the agent's own transcript/tool output happens to contain that wording" (see this
function's existing comment about the false-positive that motivated it). Copilot CLI has no
documented equivalent structured event, so there is no safe way to also scan its stdout for quota
text without risking that exact false-positive class — `quota_hit_message` therefore only scans
**stderr** for Copilot (never `$outfile`/stdout), same restriction Claude's own primary check
already applies before falling back to its stdout-safe secondary check. If QA/engineer discover in
practice that Copilot CLI does report session-ending quota errors via stdout, that's a follow-up
issue (a safe stdout check would need its own structural anchor, not raw text matching), not
something to bolt on here by relaxing this to scan `$outfile`.

`usage_limit_wait_seconds()` (lines 182-204) needs no change — it already operates purely on
message text (any `H:MMam/pm` clock time, harness-agnostic), falling back to
`QUOTA_RETRY_INTERVAL` when it can't parse one, which is the expected outcome for Copilot's
"weekly rate limit" wording (a rolling window, not a fixed daily reset clock time).

**Preflight** (lines 347-362):

```bash
if [ "$PREFLIGHT" = 1 ]; then
  bd ready --json >/dev/null 2>&1 || { alert "preflight: bd cannot reach the Beads database"; exit 3; }
  while :; do
    if [ "$HARNESS" = "copilot" ]; then
      preflight_out=$(timeout 180 copilot -p "Reply with the single word OK." --allow-all-tools --no-ask-user -s 2>&1)
    else
      preflight_out=$(timeout 180 claude -p "Reply with the single word OK." --dangerously-skip-permissions --max-turns 1 2>&1)
    fi
    [ $? -eq 0 ] && break
    preflight_hit=$(quota_hit_message <(printf '%s' "$preflight_out"))
    if [ -n "$preflight_hit" ]; then
      wait_s=$(usage_limit_wait_seconds "$preflight_hit")
      alert "preflight: usage limit hit ($preflight_hit); waiting ${wait_s}s before retrying startup"
      sleep "$wait_s"
      continue
    fi
    alert "preflight: harness failed to run (check auth): ${preflight_out:0:200}"
    exit 3
  done
fi
```

Only change beyond the harness branch: the failure alert text becomes harness-neutral
(`"harness failed to run"`, not `"claude failed to run"`) — `bin/board.sh` pattern-matches this
exact substring (see next section), and a fixed neutral phrase is simpler than growing an
alternation for every future harness.

### `bin/board.sh`

Three spots reference the literal string `claude failed to run` (comments at lines 38, 47, and the
regexes at lines 68 and 86). Update all of them to `harness failed to run`, matching the new
`agent-loop.sh` alert text above. This is the one place outside `agent-loop.sh` itself that
observably depends on that exact wording — grepped for `claude` across `bin/`, `docker-compose.yml`,
`Dockerfile`, `agents/` to confirm nothing else does (`bin/init-project.sh`'s `bd setup claude` is
handled above; `bin/lib.sh`'s only hit is a comment).

### `docs/ARCHITECTURE.md`

"Stack" section, the `agent` bullet: currently states the image "Contains: `claude`
(`@anthropic-ai/claude-code`, npm) ...". Update to say the image contains *either* `claude` or
`copilot` (`@github/copilot`, npm), chosen at build time by the `HARNESS` build arg
(`bin/init.sh --harness=<claude-code|copilot>`, default `claude-code`) — `bd`/`beads`, `git`,
`jq`, `curl`, `shellcheck` are installed regardless.

### `README.md`

- **Setup**: document the flag in the `bin/init.sh` line of the quick-start snippet
  (`bin/init.sh [--harness=claude-code|copilot]   # first run creates ...`), and add a short
  paragraph next to the existing `HOST_USER`/`HOST_UID`/... paragraph explaining `HARNESS` is
  recorded the same way, defaults to `claude-code`, and requires a re-run of `init.sh` (which
  always rebuilds the image) to switch later.
- **Security notes**: the line "Agents run with `--dangerously-skip-permissions` inside their
  container" (also in the doc header, line 4) should become harness-neutral: "...with full tool
  permissions inside their container (`--dangerously-skip-permissions` for Claude Code,
  `--allow-all-tools --no-ask-user` for GitHub Copilot CLI)". Add
  `COPILOT_GITHUB_TOKEN`/`GH_TOKEN`/`GITHUB_TOKEN` next to the existing
  `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY` mention (same "put no other credentials in `.env`"
  caveat applies).
- **Guardrails built in**: add a line noting `DAILY_BUDGET_USD` is enforced for Claude Code only —
  Copilot CLI sessions record `$0` cost (no CLI-reported USD figure available) — so it is not a
  real spend cap under `HARNESS=copilot`.
- **Day to day** table, "Watch an agent" row: "raw stream in
  `<project>/.agent-factory/logs/<role>/*.jsonl`" → "...`*.jsonl` (Claude Code) or `*.log`
  (Copilot CLI, plain text)".
- **"Things I could not test"**: add items for this story specifically (see next section) — same
  spirit as the existing list, which already covers exact `claude`/`bd` flags the kit relies on
  without a live environment to verify against.

## Data shapes / interfaces

One new setting, `HARNESS` (string enum: `claude-code` | `copilot`), threaded through:
`bin/init.sh` (flag → `.env`) → `docker-compose.yml` build arg (image choice) and `env_file`
(runtime, read directly by `bin/agent-loop.sh` and `bin/init-project.sh`, no new export needed
from `bin/env.sh`). No other new data shapes — `agents/<role>.md` prompt content and its delivery
via `-p "$prompt"` are identical across both harnesses.

## Error cases

- Invalid `--harness` value: `init.sh` exits 1 before touching the filesystem, naming the accepted
  values (AC6).
- `HARNESS` in `.env` somehow ends up neither value (hand-edited, or a stale/corrupted file):
  `agent-loop.sh` fails fast at startup (`exit 1`) rather than guessing — same philosophy as its
  existing `CONTAINER_HOME` check just above where this is added.
- `Dockerfile`'s `HARNESS` build arg is likewise validated inside the image build itself
  (`case ... *) exit 1`), so a build invoked outside `init.sh`'s validation (e.g. `docker compose
  build agent` run directly with a bad `--build-arg`) still fails loudly, not silently defaulting.
- Copilot CLI auth missing/invalid: surfaces through the existing preflight loop exactly like a
  bad Claude Code credential does today — `alert "preflight: harness failed to run (check auth):
  ..."`, `exit 3` (AC7).
- Copilot CLI usage-limit/quota hit: detected via `quota_hit_message`'s Copilot-pattern branch,
  same wait/retry path as Claude Code's (never counted as a failed attempt) — AC5's last clause.
- `DAILY_BUDGET_USD` under `HARNESS=copilot`: not a real cap (cost always recorded as 0) —
  documented limitation, not silently pretended to work (see "Cost tracking" above and the README
  update).

## How each acceptance criterion is satisfied

1. No `--harness` flag → `HARNESS_FLAG` empty → `.env` gets `HARNESS=claude-code` (or keeps
   whatever's already there) → `Dockerfile`/`docker-compose.yml` build arg defaults to
   `claude-code` → `agent-loop.sh` defaults `HARNESS` to `claude-code` too. Three independent
   defaults, all `claude-code`, so a project with no flag ever passed behaves exactly as today.
2. `--harness=copilot` → `init.sh` writes `HARNESS=copilot` into `.env` (project- or kit-level,
   whichever `AGENT_ENV_FILE` resolves to) → every later `start.sh`/`agent-loop.sh` run for that
   project loads it via the existing `env_file:` mechanism, no flag repetition needed.
3. `agent-loop.sh`'s harness dispatch in `run_harness_session()` invokes `copilot`, not `claude`,
   when `HARNESS=copilot`; `build_prompt()` (unchanged) feeds it the same `agents/<role>.md`
   content via the same `-p "$prompt"` shape.
4. `HARNESS` build arg picks the Dockerfile's `npm install -g @github/copilot` branch;
   `docker compose build agent` installs it into the image, usable via `copilot -p ...` inside a
   container.
5. tmux pane: Copilot's plain-text (`-s`) stdout is teed straight into the pane, human-readable by
   construction — no render step needed the way Claude's stream-json requires one. Cost: recorded
   (as 0, documented difference — see above). Usage-limit/quota: detected and handled via the same
   wait/retry path, Copilot-specific text patterns.
6. Unrecognized `--harness` value: `init.sh` exits 1 before any filesystem write, error names
   `claude-code`/`copilot` as the accepted values.
7. Preflight branches on `HARNESS` the same way the main session invocation does; failure (bad/
   missing auth) alerts and exits 3 exactly as today, just with harness-neutral wording.

## Verification needed at implementation time (no live Copilot CLI available while designing)

Everything above about GitHub Copilot CLI's exact flags/behavior comes from current GitHub docs
and secondary write-ups, not from running it. Before considering this done, the engineer should
confirm against `copilot --help` (and a real session, auth permitting) inside a built image:
1. `-p`/`--prompt`, `-s`, `--no-ask-user`, `--allow-all-tools`, `--model` — flag names and that
   `-s` output is clean enough to tee directly into a tmux pane / log file with no rendering step.
2. Whether a real turn/continuation cap flag exists (candidate: `--max-autopilot-continues`) — see
   "MAX_TURNS" above; wire it in if confirmed, otherwise leave as documented above.
3. The exact wording/exit behavior of a quota/rate-limit hit (candidates matched above:
   `quota_exceeded`, "you have no quota", "exceeded your ... rate limit", "reached the rate
   limit") — adjust `quota_hit_message`'s Copilot pattern if real wording differs.
4. Whether `~/.copilot` (populated by `copilot login`) is sufficient on its own for
   non-interactive reuse the way `~/.claude` is, or always needs a token env var in a headless
   container (no browser) — if the latter, the `.copilot`/`.copilot-host` mount pair is still
   harmless to keep (future-proofing, matches the `.claude` pattern) but README should say a token
   is effectively required for Copilot today, not "optional like the API key escape hatch".

## Test strategy (for QA)

Acceptance-style per `docs/ARCHITECTURE.md`'s "Test strategy" — no unit-test framework. At minimum,
`tests/agent-factory-bki_test.sh`, run from a scratch `PROJECT_DIR`:

- **AC1**: `bin/init.sh` with no flag on a fresh project → `.agent-factory/.env` (after the
  documented "created, re-run" first pass) ends up containing `HARNESS=claude-code`.
- **AC2**: `bin/init.sh --harness=copilot` → `.env` contains `HARNESS=copilot`; assert via `docker
  compose config` (or `dc config`) that the resolved `agent` service's build args include
  `HARNESS: copilot` without needing to actually build.
- **AC4**: `docker compose build agent` with `HARNESS=copilot` in `.env` succeeds, and `dc run
  --rm --entrypoint bash agent -lc 'which copilot'` finds it (and `which claude` does *not*, since
  only one is installed); the mirror image check with `HARNESS=claude-code` (today's default).
- **AC6**: `bin/init.sh --harness=bogus` exits non-zero, stderr names `claude-code`/`copilot`, and
  neither creates a new `.env` (fresh project) nor modifies an existing one (pre-existing project)
  — diff `.env`'s content/mtime before and after.
- **AC3/AC5/AC7**: can't exercise for real without live GitHub Copilot credentials in the QA
  sandbox. Recommend stubbing: put fake `copilot`/`claude` scripts earlier in `$PATH` that read
  their `-p` argument and either echo a fixed "OK"/short reply (happy path) or print one of the
  quota-pattern strings above to stderr and exit non-zero (quota path), then run
  `bin/agent-loop.sh` against them directly (short `MAX_ATTEMPTS_PER_ISSUE`/`IDLE_SLEEP`,
  `PREFLIGHT=1`) and assert: (a) the preflight loop's `alert`/`sleep`/retry behavior on the quota
  stub, (b) `$CONTROL/cost/$ROLE.<date>` gets a `0` line under the copilot stub, (c) the tmux-pane
  side (stdout of `run_harness_session`) is the stub's plain text, unmodified.
- `shellcheck` the diff on `bin/init.sh`, `bin/init-project.sh`, `bin/agent-loop.sh`, `bin/board.sh`.
- Regression: every existing `tests/*_test.sh`/`tests/acceptance/*.sh` must still pass with
  `HARNESS` unset/`claude-code` (default path) — this story must not change Claude Code behavior
  when no flag is used.

## Out of scope reminders (carried from the story)

No host-side detection of installed CLIs. No per-role harness mixing (one `HARNESS` per project,
full stop). No harness beyond these two. `agents/<role>.md` content itself is untouched — only
delivery mechanics changed. No interactive picker.
