# agent-factory-47q: Time-based expiry for recent alerts - design

## Approach
Change only `recent_alerts` in `bin/board.sh` (structure from 2do: functions + guarded main loop,
already in place). Add one more rule to the existing per-line classifier: any line that falls
through both 2do rules (needs-human family, usage-limit family) is dropped if its timestamp is
older than the max age. `alert()`, `alerts.log`, and the other sections are untouched; the log is
never rewritten (AC7).

## Changes to `bin/board.sh`
1. Near the top of `recent_alerts`, compute the cutoff once per refresh:
```bash
local max_min="${ALERT_MAX_AGE_MINUTES:-60}"
[[ $max_min =~ ^[1-9][0-9]*$ ]] || max_min=60   # invalid/zero/negative/non-numeric -> default
local max_age_s=$(( max_min * 60 ))
```
2. Replace the final unconditional `echo "$line"` (the "not needs-human or usage-limit" fallthrough) with:
```bash
alert_epoch=$(date -d "$ts" +%s 2>/dev/null) || { echo "$line"; continue; }   # AC6: fail visible
(( now - alert_epoch <= max_age_s )) && echo "$line"
```
(`alert_epoch` is already declared `local`.) Keep the existing `tail -n 6` first, then filter, so
the 6-line window still applies (AC7). The malformed-line branch (regex on `^ts [agent] msg` doesn't
match) stays first and still prints the line (AC6). Future-dated timestamps give a negative age and
are kept.
3. Update the comment above `recent_alerts` to mention the age cutoff and the env var.

Do not touch the needs-human or usage-limit branches: they `continue` before reaching the new
rule, so a still-flagged needs-human alert is never hidden by age (AC5).

## Config
`ALERT_MAX_AGE_MINUTES` (default 60), read from the environment of the board process. Invalid values
(empty, 0, negative, non-integer) silently fall back to 60 rather than erroring, since a crashing
board is worse than a default. Add one line documenting it in the README's env/config section if
one lists board or alert settings (and `.env.example` if it exists and lists similar knobs); note
that `docker-compose.yml` only forwards it to the `board` process if that is launched inside a
container with the var passed - the engineer should check how `board.sh` is started (tmux window
in `bin/start.sh`) and make sure a value set in `.env` actually reaches it, adding it to
`docker-compose.yml`'s `environment:` only if the board runs via compose.

## Behavioural note (for reviewer/QA, no action)
Alerts not matched by the 2do patterns age out after the cutoff, including
`"<id>: restart-story.sh failed (...); needs a human"` and `"...merge-conflict rework failed"`
(agent-loop.sh:198-199), which say needs-human but aren't the labelled-issue formats 2do governs.
Story scope says only 2do's types are exempt, so these expire by age; the issue itself still shows
in the board's needs-human section if labelled.

## AC mapping
1. Old, unmatched-type line -> `now - epoch > max_age_s` -> dropped.
2. Recent line -> kept byte-for-byte.
3. Unset var -> 60 min.
4. `ALERT_MAX_AGE_MINUTES=N` -> `N*60` seconds.
5. Needs-human / usage-limit lines never reach the new rule.
6. Unparseable timestamp (regex mismatch, or `date -d` failure) -> printed.
7. No writes to `alerts.log`; `tail -n 6` unchanged.

## Test strategy (QA; `tests/agent-factory-47q_test.sh`, model on `tests/agent-factory-2do_test.sh`)
Source `bin/board.sh` with a scratch `DATA_DIR`, write `alerts.log` with timestamps generated via
`date -u -d '-N minutes' +%FT%TZ`, stub `bd` on PATH as the 2do test does. Cases:
- circuit-breaker line 2h old -> absent; 10 min old -> present unchanged (AC1, AC2).
- Same with daily budget / git sync / clone / preflight-claude lines.
- Unset var: 59 min old kept, 61 min old dropped (AC3).
- `ALERT_MAX_AGE_MINUTES=5`: 6 min dropped, 4 min kept; `=180`: 2h kept (AC4).
- Invalid values (`0`, `abc`, `-3`, empty) behave as 60.
- needs-human line 3 days old with stub bd reporting label still present -> kept; usage-limit line
  with wait still running but older than max age -> kept; elapsed -> dropped as in 2do (AC5).
- Garbage line and a `Z`-less/invalid timestamp (`9999-99-99T99:99:99Z [x] boom`) -> shown (AC6).
- `alerts.log` checksum unchanged after call; 8 fresh lines -> only last 6 shown; old lines within
  the tail window are dropped without pulling in earlier lines (AC7).
- `shellcheck bin/board.sh` clean; full regression suite (2do test) still passes.
