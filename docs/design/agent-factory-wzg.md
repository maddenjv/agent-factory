# agent-factory-wzg: Preflight recent alerts - design

## Approach

Two small, independent changes, no new files:

1. **`bin/agent-loop.sh`** starts recording *when this process started* - one timestamp per
   `AGENT_ID`, overwritten every run, written as early as possible (before preflight even runs).
2. **`bin/board.sh`**'s `recent_alerts` (structure from agent-factory-2do/47q, already in place)
   gains one more pre-check, specific to lines whose message starts with `preflight:`: if the
   *same agent* has a recorded start later than the alert's own timestamp, the alert is from a
   superseded start and is dropped outright - before it ever reaches the existing needs-human /
   usage-limit / age-cutoff classification. If it isn't superseded, it falls through to that
   existing classification completely unchanged (this is what gives AC2/AC6 - no regression - for
   free: nothing about today's behavior changes for a preflight alert from the agent's current
   start).

Why "process started" rather than "preflight passed": AC3 requires that when the *same agent*
fails preflight twice in a row (two successive starts, neither of which necessarily succeeds),
only the newer failure is shown - the older one is dropped as soon as the second start begins,
independent of whether that second start's preflight itself passes or fails. So the signal has to
be "a new `agent-loop.sh` process began" (checked in against the alert's timestamp), not "preflight
most recently succeeded." One consequence, intentional: a preflight alert from the agent's *own,
current, still-in-progress* start is never superseded by itself - only a **later** start's
existence (a strictly greater start timestamp) drops an alert, and that can't happen until the
process starts again.

## Changes to `bin/agent-loop.sh`

Immediately after the existing `mkdir -p "$LOGDIR" "$STATE" "$CONTROL/cost"` (line 37, so the
directory exists first) and before `sync_configs`/preflight, add one line:

```bash
date -u +%FT%TZ > "$STATE/started_at"
```

Notes:
- `$STATE` is already `$CONTROL/state/$AGENT_ID` - per-agent, matching the existing
  `attempts.<issue-id>` files in the same directory.
- Written unconditionally, every run, regardless of `PREFLIGHT` - it means "this process started
  running," not "preflight passed." The existing `log "started: role=$ROLE ..."` line further
  down (after preflight succeeds) is unrelated and untouched: it's an operator-facing log line for
  "past preflight, entering the main loop," not the machine-readable signal board.sh needs, and
  its timing is deliberately *not* what we key off (see Approach).
- Plain overwrite (`>`, not append) - only the most recent start matters, and this mirrors the
  existing `echo "$n" > "$f"` style already used for `attempts.<id>` in the same directory (no
  atomic-rename dance elsewhere in this script either).
- One file, one line, no schema - nothing else reads or writes `$STATE/started_at`.

## Changes to `bin/board.sh`

`recent_alerts`'s line-format regex gains a capture group for the agent id that's already sitting
in the brackets (today it's matched but discarded):

```bash
if [[ ! $line =~ ^([0-9T:-]+Z)\ \[([^]]*)\]\ (.*)$ ]]; then
  echo "$line"; continue
fi
ts="${BASH_REMATCH[1]}"; agent_id="${BASH_REMATCH[2]}"; msg="${BASH_REMATCH[3]}"
```

New helper, alongside `still_needs_human`:

```bash
# agent_restarted_since AGENT_ID ALERT_EPOCH -> exit 0 if AGENT_ID has a recorded process start
# later than ALERT_EPOCH (the alert belongs to a start that's since been superseded), 1 otherwise.
# Missing or unparseable marker fails open (1 = not superseded, alert stays subject to the normal
# rules below) - same fail-open philosophy as still_needs_human.
agent_restarted_since() {
  local agent_id="$1" alert_epoch="$2" started_raw started_epoch
  started_raw=$(cat "$DATA_DIR/control/state/$agent_id/started_at" 2>/dev/null) || return 1
  started_epoch=$(date -d "$started_raw" +%s 2>/dev/null) || return 1
  (( started_epoch > alert_epoch ))
}
```

New pre-check, inserted right after the `ts`/`agent_id`/`msg` extraction and *before* the existing
needs-human check:

```bash
if [[ $msg =~ ^preflight: ]]; then
  alert_epoch=$(date -d "$ts" +%s 2>/dev/null) && agent_restarted_since "$agent_id" "$alert_epoch" && continue
fi
```

- Matches all three preflight messages (`preflight: bd cannot reach the Beads database`,
  `preflight: usage limit hit (...); waiting Ns before retrying startup`,
  `preflight: claude failed to run ...` - agent-loop.sh:283,290,294), since all three share the
  `preflight:` prefix and none of them appear anywhere else in `alert()`'s call sites.
- If `date -d "$ts"` fails (malformed timestamp) the `&&` chain short-circuits: falls through
  unchanged, matching the file's existing fail-open convention for unparseable timestamps.
- If `agent_restarted_since` returns 1 (no later start recorded, including "never recorded" -
  e.g. right after a fresh checkout, or the state directory being new): falls through unchanged.
- If it returns 0: `continue` drops the line before any other classification runs.
- **Falling through matters**: the `preflight: usage limit hit (...); waiting Ns` message also
  matches the existing usage-limit-family regex a few lines down (it already did, before this
  story) - that's correct and unchanged. So this pre-check must never unconditionally *keep* a
  line, only ever *drop* it early; every non-superseded preflight alert still gets classified by
  the untouched existing rules (usage-limit elapsed-wait for that one message, generic
  `ALERT_MAX_AGE_MINUTES` cutoff for the other two, per 47q).
- Nothing here touches the needs-human branch's own `id` extraction (issue id, from the message
  text) - that regex doesn't match `preflight:`-prefixed messages, so it's unaffected.

No other line in `recent_alerts` changes. `alerts.log` is still never rewritten; the `tail -n 6`
window still applies first, exactly as before.

## Acceptance criteria mapping

1. Earlier start's preflight alert, agent has since started again → `agent_restarted_since`
   true (recorded start > alert timestamp) → dropped, regardless of age.
2. Current start's own preflight alert, no later start recorded → pre-check falls through →
   governed by existing usage-limit/age-cutoff rules exactly as before.
3. Two successive starts, second one's preflight alert has no later recorded start (yet) →
   only that second one's pre-check falls through and it stays (per AC2 logic); the first one's
   pre-check sees the second start's marker (later than its own timestamp) and drops it.
4. Per-agent: `agent_restarted_since` looks up `$DATA_DIR/control/state/<that agent's id>/started_at`
   only - one agent's marker file never affects another agent's lines.
5. Non-preflight messages never match `^preflight:` (checked against every `alert()` call site -
   see Story context and the 2do design's own enumeration) → pre-check never triggers → identical
   to today.
6. No later start recorded for that agent → pre-check falls through → existing tail-window +
   47q age-cutoff behavior, unchanged.

## Test strategy

QA extends the existing sourced-function approach (`tests/agent-factory-47q_test.sh` is the
closest model): source `bin/board.sh` with a scratch `DATA_DIR` and a stub `bd` on `PATH` (needed
only because `still_needs_human` still runs for unrelated lines in the same fixture), call
`recent_alerts` directly. This feature needs no `bd` stubbing of its own - "has the agent started
again" is purely a file under `$DATA_DIR/control/state/<agent_id>/`, so tests just write it.

Suggested cases (one per AC, plus edge cases):
- Preflight alert for `engineer` at T-30min; write `control/state/engineer/started_at` = T-10min
  (later) → alert dropped (AC1), even though within `ALERT_MAX_AGE_MINUTES` and within the
  tail window.
- Preflight alert for `engineer` at T-5min; no `started_at` file at all → alert shown (AC2, and
  covers "never started successfully yet").
- Preflight alert for `engineer` at T-5min; `started_at` = T-10min (earlier than the alert, i.e.
  this is that start's own alert) → alert shown (AC2/AC6, not self-superseded).
- Two preflight alerts for `engineer`: T-20min ("bd cannot reach...") and T-10min ("claude failed
  to run..."); `started_at` = T-5min (later than both) → both dropped (generalizes AC1/AC3 to more
  than two).
- Two preflight alerts for `engineer`, successive starts: T-20min alert, then `started_at` written
  at T-15min (second start begins), then a second preflight alert at T-15min+1s from that same
  second start; no further `started_at` update after that → first alert dropped, second shown
  (AC3 exactly).
- Preflight alerts for `engineer` and `qa` both at T-20min; only `control/state/engineer/started_at`
  = T-10min written → engineer's alert dropped, qa's alert still shown (AC4).
- One needs-human alert, one usage-limit (main-loop) alert, one circuit-breaker alert, one daily
  budget alert, one git-sync-failure alert, one clone-failure alert, all old enough that they'd be
  candidates if the new rule mistakenly applied to them, plus a `started_at` file present for
  their agent → all still governed purely by their pre-existing rules, unaffected (AC5).
- `preflight: usage limit hit (...); waiting Ns` message specifically, no later start recorded: (a)
  wait window still running → shown; (b) elapsed → hidden - confirms the fall-through to the
  existing usage-limit branch still works for this message once this story's pre-check doesn't
  drop it.
- Malformed/unparseable `started_at` content (hand-edited garbage) → fails open, alert shown.
- `agent_restarted_since` with a missing state directory entirely (fresh `DATA_DIR`) → returns
  false, no error, no stray output.
- `shellcheck bin/board.sh bin/agent-loop.sh` clean; full existing regression suite (2do, 47q,
  and any other `tests/*_test.sh`) still passes unchanged.

Manual/integration note for QA: after this change, `bin/agent-loop.sh` also needs a smoke check
that it still starts cleanly end-to-end (writes `$STATE/started_at`, then proceeds through
preflight as before) - one run against a scratch `PROJECT_DIR` per the "bash script changes"
convention in `docs/ARCHITECTURE.md` is enough; no new acceptance-test file is required for
agent-loop.sh itself since its only change is the one-line marker write.

## Out of scope (per story)
No change to `alert()`, `alerts.log` format/rotation, preflight's own retry/exit behavior or
message wording, or resolution logic for any non-preflight alert family.
