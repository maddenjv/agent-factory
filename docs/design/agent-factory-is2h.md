# Design: agent-factory-is2h - model hierarchy System 1 > MODEL_<ROLE> > MODEL_MEDIUM > role default

Story: `docs/stories/agent-factory-is2h.md`. Builds on `agent-factory-hcql.md` (choose_model) and
`agent-factory-250.md` (role tier defaults). No new env vars, no change to `bin/system1-class.sh`.

## Approach
Rewrite `choose_model` in `bin/agent-loop.sh` as a first-match resolver. Precedence:
1. System 1 class model: `SYSTEM1_ENABLED=1`, classifier exits 0 with a class, `MODEL_<CLASS>` non-empty.
2. `MODEL_<ROLE>` (the `MODEL_PINNED=1` case).
3. `MODEL_MEDIUM`.
4. Role tier default.

## Changes
### `bin/agent-loop.sh`
- Model resolution block (lines ~57-62): `MODEL` currently holds `MODEL_<ROLE>` else the tier default, so
  the two cannot be told apart later. Add `ROLE_DEFAULT_MODEL` set to the tier default
  (`$TIER_TEAM_LEAD` for team-lead, else `$TIER_STANDARD`), and keep `MODEL` as today
  (`MODEL_<ROLE>` if set else `ROLE_DEFAULT_MODEL`) so the throttle path and `MODEL_PINNED` keep working
  unchanged. Rename the comment on `MODEL_PINNED` (no longer "wins, System 1 not consulted"): it now
  means "`MODEL_<ROLE>` is set; used at priority 2".
- `choose_model ID` (sets `SESSION_MODEL`, logs one line via `log`):
  ```
  tried=""            # reason System 1 gave no model, for the log
  if SYSTEM1_ENABLED != 1:                tried="system1 disabled"
  elif MODEL_HIGH, MODEL_MEDIUM, MODEL_LOW all empty: tried="no class models set"   # skip the request
  else
    run classifier as today (cd "$REPO"; stderr to tmp file)
    ok + non-empty class -> ckey=MODEL_${class^^}; m=${!ckey}
         m non-empty -> SESSION_MODEL=$m; log "model: $id source=system1 class=$class model=$m"; return 0
         else        -> tried="system1 class=$class but $ckey empty"
    failure            -> tried="system1 failed: <one_line first 300 bytes of stderr, or 'no reason'>"
  fi
  if MODEL_PINNED=1:    SESSION_MODEL=$MODEL;  log "model: $id source=MODEL_<ROLE> (<model_var>) model=$MODEL fallback=($tried)"
  elif MODEL_MEDIUM set: SESSION_MODEL=$MODEL_MEDIUM; log "model: $id source=MODEL_MEDIUM model=... fallback=($tried)"
  else                   SESSION_MODEL=$ROLE_DEFAULT_MODEL; log "model: $id source=role-default model=${...:-<harness default>} fallback=($tried)"
  ```
  Use the literal variable name (`$model_var`) in the log. An invalid class answer already makes the
  classifier exit non-zero (existing behaviour), so it lands in the failure branch.
  Remove the old "class=medium" pseudo-fallback and the early pinned / all-empty returns. With S1 off and
  everything unset, `SESSION_MODEL=$ROLE_DEFAULT_MODEL` equals today's `$MODEL`, so `--model` argv is
  unchanged. The `${SESSION_MODEL-$MODEL}` expansion in `run_harness_session` and `unset SESSION_MODEL` in
  `run_agent` stay as is. team-lead with `SYSTEM1_ENABLED=1` still bypasses `choose_model` (system1.sh).

### Docs (AC7) - replace every "MODEL_<ROLE> wins / skips System 1" statement with the order above
- `README.md` "Per-task model class" paragraph (~l.169-174) and l.100 / l.138 role-override lines
  (state that a role pin applies only when System 1 gives no usable model).
- `.env.example` lines 24 and 31-35: new order; `MODEL_MEDIUM` is now the fallback after `MODEL_<ROLE>`,
  and is also used by System 1 when it answers `medium`.
- `docs/ARCHITECTURE.md` System 1 paragraph (done in this commit).

## Acceptance criteria mapping
1. enabled + valid class + class var set + `MODEL_<ROLE>` set -> branch 1 returns class model.
2. failure / timeout / invalid / empty class var + role set -> `MODEL_PINNED` branch, log has reason.
3. disabled + role set -> classifier never invoked (no curl), pinned branch.
4. no S1 model, role unset, `MODEL_MEDIUM` set -> MEDIUM branch.
5. nothing yields -> `ROLE_DEFAULT_MODEL`.
6. every path logs exactly one `model:` line with `source=` and, for non-System-1 sources, `fallback=(reason)`.
7. docs as listed.

## Edge cases
- S1 answers `high`, `MODEL_HIGH` empty -> falls to role, MEDIUM, default (not to MEDIUM-first).
- S1 enabled but all class vars empty: no request is made (nothing could use the answer); reason logged.
- The throttle assessment path never calls `choose_model`; keeps `$MODEL` (role pin else tier default).

## Test strategy (QA)
Extend the style of `tests/agent-factory-hcql_test.sh` (stub `curl`, `bd`, `claude`; record argv; curl stub
logs invocations). Matrix over {S1 off / ok / curl fail / timeout / invalid class / class var empty} x
{`MODEL_<ROLE>` set/unset} x {`MODEL_MEDIUM` set/unset}: assert `--model` argv and the `source=` / `fallback=`
fields in `loop.log`; AC3 asserts the curl stub is never run. Update existing hcql/250 tests that assert
"pinned wins" or class=medium fallback wording. Docs (AC7): grep the three files for the new order and
absence of "wins" / "skips System 1" phrasing.
