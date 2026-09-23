# Design: agent-factory-stg - wait out usage-limit hits

## Root cause
`run_agent` in `bin/agent-loop.sh` sets `LAST_RUN_QUOTA_MSG` from `quota_hit_message "$errfile"`
(stderr only). The CLI reports a session limit only in its stream-json stdout: a synthetic
assistant message with the limit text, then a `result` event with `is_error: true`,
`terminal_reason: "api_error"` and (expected) the same text in `.result`. Stderr is empty, so the
message is never seen, the run is treated as an ordinary failure, and `record_failure` burns
attempts. The wait/release branch in the main loop (AC1-3, 5, 6) is already correct once
`LAST_RUN_QUOTA_MSG` is populated; only detection is broken.

## Approach
Add a second, *structured* detector over this run's stream-json output, and OR it with the
existing stderr detector. Never grep the raw transcript (the false-positive history described in
the comment above `quota_hit_message` still applies): inspect only the terminal `result` event,
and only when it is an error.

### Changes (all in `bin/agent-loop.sh`)
1. `run_agent`: capture this run's stdout separately from the cumulative `$logfile` (which is
   appended across attempts and would let an earlier attempt's limit hit leak into a later run):
   `outfile=$(mktemp)`, pipe `tee -a "$logfile" "$outfile"`, `rm -f "$outfile"` at the end.
2. New function next to `quota_hit_message`:
   ```bash
   quota_hit_from_stream() {  # quota_hit_from_stream FILE -> limit message from the final error result event, or empty
     jq -rs '[.[] | select(type=="object" and .type=="result")] | last
             | select(.is_error==true) | (.result // "")' "$1" 2>/dev/null \
       | grep -ihEo 'hit your [a-z]+ limit[^"]{0,200}' | head -1 | tr -d '\r' | tr '\n\t' '  ' | cut -c1-200
   }
   ```
   Only "hit your ... limit" wording is matched here (not the broader `usage limit` /
   `limit reached` alternatives), because this text comes from the agent-visible stream. Use
   `jq -R 'fromjson? // empty'`-style tolerance if the file may contain non-JSON lines
   (`jq -Rs`/`fromjson?` is fine; the engineer picks whichever passes the tests).
3. `run_agent`: `LAST_RUN_QUOTA_MSG=$(quota_hit_message "$errfile")`; if empty,
   `LAST_RUN_QUOTA_MSG=$(quota_hit_from_stream "$outfile")`. Update the comment above
   `quota_hit_message` to say stderr *and* the final error `result` event are the only trusted
   sources, and why the jsonl is still never grepped as text.
4. `usage_limit_wait_seconds`: small hardening - if the parsed reset time is in the past by
   less than 10 minutes (clock skew / the CLI printing the just-passed reset), return 60 instead
   of rolling to tomorrow. Otherwise unchanged (past -> tomorrow, +60s buffer, fallback
   `QUOTA_RETRY_INTERVAL` when unparseable).
5. Main loop branch (`if [ -n "$LAST_RUN_QUOTA_MSG" ]`) is unchanged: releases the issue, alerts
   with message and wait, sleeps, `continue`s without touching `attempts.$id`, `fails`, or
   `needs-human`. AC5 falls out because the retry re-enters the same branch.

## Acceptance criteria mapping
1. Limit in stream, empty stderr -> `quota_hit_from_stream` returns message -> branch waits until reset+60s.
2. Branch never calls `record_failure`/`handle_outcome`; issue set `open`.
3. No parseable time -> `usage_limit_wait_seconds` echoes `QUOTA_RETRY_INTERVAL`.
4. Agent merely read/quoted the words: not an error `result` event with that text (a normal
   `result` has `is_error:false`; an ordinary failure's `.result` won't contain "hit your ... limit"
   unless the CLI itself said so) -> empty -> normal accounting.
5. Second hit re-enters the branch; nothing persistent is counted.
6. The existing `alert` line already states the limit and wait seconds; unchanged.

## Test strategy (QA)
Shell-level, no real `claude` needed: source/extract the functions or run `agent-loop.sh` with a
stub `claude` on `PATH` (as other stories' acceptance tests do) emitting canned stream-json:
- Fixture A: synthetic assistant message + `result` `is_error:true`, `terminal_reason:"api_error"`,
  text "You've hit your session limit · resets 1:50pm (UTC)", empty stderr -> function returns the
  message; loop path: attempts file absent, no needs-human, alert emitted, sleep called with
  the computed value (stub `sleep`).
- Fixture B: same but "resets" clause removed -> sleep == `QUOTA_RETRY_INTERVAL`.
- Fixture C: normal session (`is_error:false`) whose assistant/tool-result text contains
  "usage limit" and "hit your session limit" -> empty; ordinary failure path counts an attempt.
- Fixture D: `is_error:true` failure (e.g. max_turns) with unrelated text -> empty.
- Fixture E: two consecutive runs both limited, then success -> two waits, zero failures counted;
  also a limited run appended to a `$logfile` that already holds an earlier limited run followed
  by a clean run must not be misdetected (per-run capture).
- `usage_limit_wait_seconds`: past-by-<10min -> 60; parseable future time -> within [delta, delta+60]; 12am/12pm handling.
- `shellcheck bin/agent-loop.sh` on the diff.
Real-evidence check: if `logs/architect/2026-09-23.agent-factory-5l0.jsonl` exists, run
`quota_hit_from_stream` on it and confirm it yields the limit text (verifies the `.result` field
assumption; if the text lives only in the synthetic assistant message, match on the last
assistant message's text when the final `result` has `is_error:true` instead).

## Out of scope
As in the story: `DAILY_BUDGET_USD`, attempt caps/breaker thresholds, pausing other roles.
