# Design: agent-factory-hr7o - move throttling from team-lead to PO

Story: `docs/stories/agent-factory-hr7o.md`. Removes the team-lead-judged po/architect throttle
(`agent-factory-q4tj`, `whtf`) and replaces it with a deterministic PO-only gate in
`bin/agent-loop.sh`: PO idles while the count of ready `role:engineer` issues >= `MAX_READY_ENGINEER_ISSUES`.

## Approach
A pure-bash gate, no model judgment. Config arrives via `.env` -> `env_file` in docker-compose (all
`.env` vars already reach the container; no compose/init change needed).

### bin/agent-loop.sh
1. Delete: `THROTTLE_STALE_SECS`, `THROTTLE_ALERT_STALE_SECS` (lines ~26-27), the whole
   `# ---------- throttles ----------` block (`THROTTLE_FILE`, `throttle_age`, `throttle_ok`,
   `throttle_stale_alert`), `build_throttle_prompt`, `run_throttle_assessment`, the
   `throttle_idle_logged` / `throttle_stale_alerted` vars, the `throttle_stale_alert` call, the old
   `if ! throttle_ok` block, and the whole `if [ "$ROLE" = "team-lead" ] && throttle_age...` branch in the
   empty-queue path (team-lead then falls through to the plain `queue empty; idling`). Fix the comment on
   `run_harness_session` (no longer shared with a throttle run; keep the function and its `LOGNAME` param).
2. Add (same place as the old throttle block, under `# ---------- WIP gate ----------`):
```bash
MAX_READY_ENGINEER_ISSUES="${MAX_READY_ENGINEER_ISSUES-5}"   # note "-": set-but-empty stays empty = no limit
ready_engineer_count() {  # prints N, or returns 1 if it cannot be determined
  local json
  json=$(bd ready --label role:engineer --limit 1000 --json 2>>"$LOGDIR/bd-err.log") || return 1
  printf '%s' "$json" | bd_unwrap | jq -e 'if type=="array" then length else error("not array") end' 2>/dev/null
}
po_gate_ok() {  # false only for ROLE=po with a positive limit and count >= limit. Sets GATE_COUNT.
  [ "$ROLE" = po ] || return 0
  case "$MAX_READY_ENGINEER_ISSUES" in ''|0) return 0 ;; *[!0-9]*) return 0 ;; esac  # unset-to-0/empty/garbage: no limit
  GATE_COUNT=$(ready_engineer_count) || return 0          # fail OPEN (AC7)
  [ "$GATE_COUNT" -lt "$MAX_READY_ENGINEER_ISSUES" ]
}
```
   `bd ready` already excludes blocked, claimed (in_progress) and `needs-*`-deferred issues exactly as the
   story defines "ready"; do not reimplement it. Non-numeric values fail open (log nothing special; the
   `init`/README document integers).
3. Main loop, replacing the old throttle block (position: right after `budget_ok`, before `next_issue`):
```bash
if ! po_gate_ok; then
  if [ "$gate_idle_logged" != 1 ]; then
    log "idle: engineering queue full ($GATE_COUNT ready role:engineer issues >= MAX_READY_ENGINEER_ISSUES=$MAX_READY_ENGINEER_ISSUES)"
    gate_idle_logged=1
  fi
  sleep "$IDLE_SLEEP"; continue
fi
gate_idle_logged=0
```
   Logs once per idle episode (AC3); re-evaluated every poll so it resumes without restart (AC5). The gate
   holds PO's whole poll (including any PO rework issue) - accepted: PO work is top-of-funnel and the
   gate clears as soon as engineering drains. Only `ROLE=po` is ever affected (AC8; every other role
   returns 0 before any `bd` call).
4. Also write the idle state for the board (AC9): on entering idle, `printf '%s %s\n' "$GATE_COUNT"
   "$MAX_READY_ENGINEER_ISSUES" > "$CONTROL/state/po-gate"` (create `$CONTROL/state` if missing); on leaving
   idle (`gate_idle_logged=0` transition) `rm -f` it. Write it each time the count is re-read while idle so
   the numbers stay current (cheap).

### bin/board.sh
Remove `throttle_section()` and its block in `render()`. Add `gate_section()`: if
`$DATA_DIR/control/state/po-gate` exists print
```

-- po gate (engineering queue full) --
idle: <count> ready role:engineer issues >= MAX_READY_ENGINEER_ISSUES=<limit>
```
and nothing otherwise (board stays quiet when PO is not held back, as `whtf` intended).

### Deletions
- `bin/set-throttle.sh` (delete); `.agent-factory/control/throttle.json` is no longer read (stale files are
  ignored; nothing to migrate).
- `agents/team-lead.md`: remove the whole `## Assess the po/architect throttle` section, the "record a
  throttle decision" / "judge whether po and architect should keep starting new work" phrases, the
  "one of four kinds of session"/"no bd issue at all" text (now three kinds; delete the "No bd issue this
  session" sentence), and the System-1 note's "only runs for the throttle session" (with SYSTEM1_ENABLED=1
  that prompt now never runs for issue-less sessions; say it only runs for fallback/non-System-1 mode).
- `.env.example`: remove the two THROTTLE_* lines; add
  `MAX_READY_ENGINEER_ISSUES=5   # PO idles while this many ready role:engineer issues exist; 0 or empty = no limit`.
- `README.md` (lines ~126, 153, 165-167) and `docs/ARCHITECTURE.md` (the q4tj paragraph ~28-34, the
  "Throttle assessment still uses the capable model" sentences in the 73cw paragraph and "System 1
  team-lead" section): delete throttle text; add one sentence documenting the PO gate and the env var in
  README's resilience list and ARCHITECTURE's agent-loop description.
- Historical docs (`docs/stories/*`, `docs/design/*`) are left untouched.

## Error cases
| Case | Behaviour |
|---|---|
| `bd ready` errors / bad JSON | `ready_engineer_count` fails -> gate open, PO proceeds (AC7) |
| var unset | default 5 (AC6) |
| var `0`, empty, non-numeric | no limit |
| count == limit | idle (AC3 "at least N") |

## Acceptance criteria mapping
1: team-lead branch deleted, prompt section deleted. 2: deletions above (+ grep for `throttle`/`THROTTLE`
in `bin agents README.md .env.example docs/ARCHITECTURE.md` must be empty). 3,4,5,6,7,8: `po_gate_ok` +
main-loop block. 9: log line + board `po gate` section.

## Test strategy (QA)
- Unit, bash, sourcing/ stubbing `bd` on PATH (pattern as in `tests/agent-factory-q4tj_test.sh`):
  `po_gate_ok` with stub `bd ready` returning N items: N<limit true, N==limit and N>limit false;
  unset -> limit 5; `0`/empty/`abc` -> true; `bd` exits 1 or prints garbage -> true; ROLE in
  architect|engineer|qa|reviewer|team-lead -> true with count far above limit and **bd never invoked**.
  Stub must assert the call used `--label role:engineer`.
- Loop-level (pattern of `tests/agent-factory-8j3y_test.sh`): ROLE=po with full queue stub: log contains the
  idle line exactly once across several polls with count and limit; no `claim`; then flip the stub below the
  limit and see PO claim without restart. ROLE=team-lead with empty queue never runs a harness session
  (no `throttle` log dir / no harness invoked).
- Board: with `control/state/po-gate` present output contains the count/limit; absent -> no `po gate` text.
- Static: `bin/set-throttle.sh` absent; grep for `THROTTLE_`, `set-throttle`, `throttle.json`, `-- throttle`
  in the live files (not docs/stories|design) finds nothing.
- Retire obsolete tests: `tests/agent-factory-q4tj_test.sh` and `tests/agent-factory-whtf_test.sh` test
  removed behaviour and must be deleted (or reduced to the static absence checks) by QA/engineer;
  `tests/agent-factory-8j3y_test.sh` and `-73cw_test.sh` only set `THROTTLE_STALE_SECS=0`/mention
  throttle in comments - drop that env var and re-check they still pass. Check `tests/acceptance/` too.
