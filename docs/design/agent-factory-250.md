# agent-factory-250: Per-role model tiers, team-lead on the most capable model - design

## Context
`bin/agent-loop.sh:34-35` today resolves `MODEL` purely from an explicit override
(`MODEL_<ROLE>`); if unset, `MODEL` stays empty, no `--model` flag is passed, `claude` falls back
to its own CLI default, and the startup log records the unhelpful literal `model=default`
(`bin/agent-loop.sh:183,300`). This story adds a two-tier default underneath that override:
`team-lead` (coordination/triage) defaults to the most capable tier, the five execution roles
(`po`, `architect`, `engineer`, `qa`, `reviewer`) default to a lower-capability tier, and an
explicit `MODEL_<ROLE>` still wins either way.

`ROLE=team-lead` breaks the existing code before it can even reach the tier logic:
`model_var="MODEL_${ROLE^^}"` produces `MODEL_TEAM-LEAD`, and `-` is not legal inside a bash
variable name, so `${!model_var}` aborts the script (`bash -c 'x="A-B"; echo "${!x}"'` ->
`bash: A-B: invalid variable name`, no `set -e` needed). team-lead itself doesn't exist yet
(`agent-factory-dx0`, unmerged), but per the story this piece is independent of that landing
first and must resolve correctly for `ROLE=team-lead` today, verified by hand-setting `ROLE`
without the rest of team-lead's wiring - so the fix belongs here too, not only in dx0's design
(which independently hit the same two lines for the same reason; whichever change lands second
picks up a two-line, same-shape merge conflict against the other, nothing structural).

## Approach
Replace the two-line resolution at `bin/agent-loop.sh:34-35` with: sanitize `ROLE` into a legal
identifier fragment first, look up the explicit override exactly as today, and if it's empty fall
back to one of two tier constants chosen by role. The tier mapping lives in exactly one place
(the two constants below) so a future model rename or a third tier is a one-line edit, not a
grep-and-replace across call sites.

### Changes to `bin/agent-loop.sh`

Replace lines 34-35 with:
```bash
# ---------- model resolution ----------
# Two tiers: team-lead (coordination/triage) gets the most capable model; the five execution
# roles get a lower-capability default. Change these two values if the mapping drifts - no other
# call site hardcodes a model name. An explicit MODEL_<ROLE> (below) always overrides its tier.
TIER_TEAM_LEAD="${TIER_TEAM_LEAD:-opus}"
TIER_STANDARD="${TIER_STANDARD:-sonnet}"

# ROLE can contain a hyphen (team-lead); "-" is not legal in a bash variable name, so sanitize
# before building the indirect-expansion name (MODEL_TEAM_LEAD, not MODEL_TEAM-LEAD).
model_key="${ROLE^^}"; model_key="${model_key//-/_}"
model_var="MODEL_${model_key}"
MODEL="${!model_var:-}"
if [ -z "$MODEL" ]; then
  if [ "$ROLE" = "team-lead" ]; then MODEL="$TIER_TEAM_LEAD"; else MODEL="$TIER_STANDARD"; fi
fi
```
Placement unchanged (still right after the `CONTAINER_HOME` check, before `mkdir -p
"$LOGDIR" ...` and `source "$KIT_DIR/bin/env.sh"`) - it only needs `ROLE`, which is set at the top
of the file, and must run before `sync_configs`/preflight/the main loop use `$MODEL`.

`TIER_TEAM_LEAD`/`TIER_STANDARD` follow the file's existing `"${VAR:-default}"` convention (same
shape as `MAX_TURNS`, `QUOTA_RETRY_INTERVAL`, etc. just above), so an operator can override the
tier itself for every role at once via `.env` without touching the script - not required by any
acceptance criterion, but free given the existing style and harmless.

Two downstream lines need no code change but now behave differently because `MODEL` is never
empty again:
- `bin/agent-loop.sh:183`: `[ -n "$MODEL" ] && args+=(--model "$MODEL")` - the guard was already
  correct; it now always passes `--model`, which is exactly AC1/AC2/AC3 (the resolved model, tier
  default or explicit override, is what actually runs).
- `bin/agent-loop.sh:300`: `log "started: role=$ROLE model=${MODEL:-default} ..."` - the
  `${MODEL:-default}` fallback is now dead code (MODEL is always set); simplify to
  `log "started: role=$ROLE model=$MODEL max_turns=$MAX_TURNS timeout=$ITERATION_TIMEOUT"` so the
  log line records the actual resolved model (AC4) instead of ever printing the literal string
  `default` again.

No other line in `bin/agent-loop.sh` changes. `docker-compose.yml`'s `agent` service already
passes `.env` through wholesale via `env_file:` (no per-variable listing), so a new
`MODEL_TEAM_LEAD` entry in `.env`/`.env.example` needs no docker-compose.yml change to reach the
container.

### Changes to `.env.example`
Rename the section and add the sixth role, so the file matches the new default behaviour instead
of implying "empty = no model flag at all":
```diff
-# ---- Per-role models (empty = Claude Code default) ----
+# ---- Per-role models (empty = role's tier default; see bin/agent-loop.sh's "model resolution") ----
+# team-lead defaults to the most capable tier (opus); the other five roles default to a
+# lower-capability tier (sonnet). Set MODEL_<ROLE> here to override a single role's tier default.
+MODEL_TEAM_LEAD=
 MODEL_PO=
 MODEL_ARCHITECT=
 MODEL_ENGINEER=
 MODEL_QA=
 MODEL_REVIEWER=
```

### Changes to `README.md`
Add one paragraph to the **Setup** section, directly after the existing `.env` resolution
paragraph (the one that already mentions "model choice" in passing at line ~72) so the tier
default and the override are documented where every other `.env` behaviour already is:

```markdown
**Model tiers**: each role's model comes from a two-tier default - `team-lead` (coordination/
triage) runs on the most capable tier (currently Opus); the five execution roles (`po`,
`architect`, `engineer`, `qa`, `reviewer`) run on a lower-capability tier (currently Sonnet). Set
`MODEL_<ROLE>` in `.env` (e.g. `MODEL_QA=opus`) to override a single role's tier default; leave it
empty to keep the tier default. Every startup logs the model actually resolved for that run
(`role=... model=...`), tier default or override alike.
```
This satisfies AC5: states both tiers explicitly (team-lead vs. the other five) and how
`MODEL_<ROLE>` overrides.

## Acceptance criteria mapping
1. `ROLE=team-lead`, `MODEL_TEAM_LEAD` unset -> sanitized lookup finds nothing -> `MODEL=
   $TIER_TEAM_LEAD` ("opus") -> passed via `--model`.
2. `ROLE` one of the five execution roles, its `MODEL_<ROLE>` unset -> `MODEL=$TIER_STANDARD`
   ("sonnet").
3. Any role, `MODEL_<ROLE>` set (e.g. `MODEL_QA=opus`) -> indirect lookup finds it, non-empty,
   tier branch never runs -> that explicit value is used.
4. `MODEL` is unconditionally non-empty after resolution (tier default or override) -> the
   simplified log line at line 300 always records the real value, never the literal `default`.
5. README's Setup section states both tiers by name (team-lead vs. the other five) and the
   `MODEL_<ROLE>` override mechanism, per the paragraph above.

## Test strategy
Follow `tests/agent-factory-stg_test.sh`'s existing pattern exactly (closest model already in the
suite for `bin/agent-loop.sh` startup behaviour): run the real `bin/agent-loop.sh` with stub
`claude`/`bd`/`sleep` on `PATH`, `PREFLIGHT=0`, a scratch git origin, and `SLEEP_STOP_AFTER=1` so
the otherwise-endless loop exits after one iteration; assert against the `role=... model=...`
startup log line in `$DATA_DIR/logs/$ROLE/loop.log` and/or the stub `claude`'s recorded argv (add
`echo "$@" >> "$W/claude_argv"` to the stub so `--model <value>` is directly observable, not just
inferred from the log line).

Suggested cases (one per AC, plus edge cases):
- `ROLE=team-lead`, no `MODEL_TEAM_LEAD` -> log line shows `model=opus`; stub argv contains
  `--model opus` (AC1). This is the case that would previously have crashed the script outright
  (invalid variable name) - also confirms the hyphen-sanitization fix.
- `ROLE=qa`, no `MODEL_QA` -> `model=sonnet` (AC2; repeat at least once more for a second role,
  e.g. `ROLE=architect`, to confirm it's not team-lead-specific hardcoding).
- `ROLE=qa`, `MODEL_QA=opus` -> `model=opus`, i.e. override beats tier default (AC3).
- `ROLE=team-lead`, `MODEL_TEAM_LEAD=sonnet` -> `model=sonnet`, i.e. override beats the *capable*
  tier too, not just the standard one (AC3, the direction that's easy to get backwards).
- Startup log line never contains the literal string `model=default` in any of the above (AC4).
- `grep` `README.md`'s Setup section for `team-lead`, the other five role names, `MODEL_`, and
  both tier model names (`opus`, `sonnet`) - mirrors the doc-assertion style already used in
  `tests/agent-factory-6k7_test.sh` (AC5).
- `.env.example` contains `MODEL_TEAM_LEAD=` alongside the existing five `MODEL_<ROLE>=` lines
  (regression guard - not an acceptance criterion, but cheap and catches drift).
- `shellcheck bin/agent-loop.sh` clean; full existing regression suite (`tests/*_test.sh`,
  including `agent-factory-stg_test.sh` itself) still passes unchanged - nothing above touches
  `run_agent`'s other args, `handle_outcome`, or any usage-limit/quota logic.

## Out of scope (per story)
- team-lead's own behavior, prompt file, docker-compose wiring, or tmux pane placement
  (`agent-factory-dx0`, `agent-factory-uhc`).
- Switching agents from `needs-human` to `needs-team-lead` labelling (`agent-factory-ulq`).
- Any model tier beyond the current two (Opus/Sonnet), or automatic/complexity-based selection -
  static, role-keyed defaults only.
- `DAILY_BUDGET_USD` or any other cost/budget accounting change.
- `bin/agent-loop.sh:8`'s `ROLE must be set (po|architect|qa|engineer|reviewer)` usage message:
  cosmetic, already covered by `agent-factory-dx0`'s design (adding `team-lead` to the list of
  role names it prints), and unrelated to model resolution itself.
