# Design: agent-factory-dja8 - team-lead startup log shows the wrong model under System 1

## Problem
`bin/agent-loop.sh` (~line 543) logs `started: role=$ROLE harness=$HARNESS model=${MODEL:-<harness default>} ...`.
`$MODEL` is the harness tier model (`TIER_TEAM_LEAD`, default `opus`). With `ROLE=team-lead` and
`SYSTEM1_ENABLED=1`, `run_agent` (~line 404) never starts a harness session: `bin/system1.sh` makes the
decision with `$SYSTEM1_MODEL` (default `ggml-org/vllm-d3-mini-GGUF`, same default as system1.sh:15).
So the log claims `harness=claude-code model=opus` while neither is used. This applies even if
`MODEL_TEAM_LEAD` is pinned: the System 1 branch ignores it too.

## Change (one file: `bin/agent-loop.sh`)
Just before the `log "started: ..."` line, compute the description of what will actually run:

```bash
if [ "$ROLE" = team-lead ] && [ "${SYSTEM1_ENABLED:-}" = 1 ]; then
  start_harness=system1
  start_model="${SYSTEM1_MODEL:-ggml-org/vllm-d3-mini-GGUF}"
else
  start_harness=$HARNESS
  start_model=${MODEL:-<harness default>}
fi
log "started: role=$ROLE harness=$start_harness model=$start_model max_turns=$MAX_TURNS timeout=$ITERATION_TIMEOUT"
```

- Keep the prefix `started: role=<role> ` and the key order unchanged (`bin/board.sh` greps
  `"[$agent_id] started: role="`; tests parse `model=[^ ]*` so the value must contain no spaces).
- Use the same expression/default as `system1.sh` (do not invent a second default; if convenient
  add a comment pointing at system1.sh:15). Do not change `$MODEL`, `HARNESS`, or any other use of them.
- All other roles, and team-lead with SYSTEM1_ENABLED unset/0/other, log exactly as today.
- Do not touch the `preflight` section: out of scope.

## Acceptance criteria
Single vague AC ("what Context describes is resolved"), interpreted as:
1. team-lead + `SYSTEM1_ENABLED=1`, `SYSTEM1_MODEL=foo/bar` -> line contains `harness=system1 model=foo/bar` and not `model=opus`.
2. Same with `SYSTEM1_MODEL` unset -> `model=ggml-org/vllm-d3-mini-GGUF`.
3. team-lead without SYSTEM1_ENABLED -> unchanged (`harness=claude-code model=opus`, or `MODEL_TEAM_LEAD` / TIER override).
4. Non-team-lead roles with `SYSTEM1_ENABLED=1` -> unchanged (`model=sonnet`, etc.).
5. Line still matches `board.sh`'s `started: role=` grep.

## Test strategy (QA)
Shell test `tests/agent-factory-dja8_test.sh`, modelled on `tests/agent-factory-250_test.sh`
(runs real agent-loop.sh to the "started:" line; its `started_model()` helper) and hermetic per
`tests/agent-factory-73cw_test.sh` (unset operator `SYSTEM1_*` env first, stub curl/harness).
Cover AC1-4 via the log line; AC5 by grepping `started: role=team-lead`. Also re-run existing 250/dx0/wzg tests
to confirm no regression. Docs: no ARCHITECTURE.md change needed.
