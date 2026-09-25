# agent-factory-wzg: Preflight recent alerts - design

> Reconciled 2026-09-25 (agent-factory-3lg) to describe the mechanism actually shipped in
> `bin/board.sh` (commits f7fbd44, then bugfix agent-factory-kuw). The original version of this
> doc proposed a new `control/state/<agent>/started_at` marker file written unconditionally by
> `bin/agent-loop.sh`; QA's committed acceptance tests (`tests/agent-factory-wzg_test.sh`) instead
> fabricate "the agent restarted" via the pre-existing `logs/<agent>/loop.log` `started: role=...`
> line and never populate that path, so the file-based approach as originally written could not
> have passed them. Engineer built against the signal the tests actually exercise. No change was
> ever made to `bin/agent-loop.sh`.

## Approach

One change, no new files, entirely inside `bin/board.sh`'s `recent_alerts`:

An agent's own preflight alert (`preflight: bd cannot reach the Beads database` or
`preflight: claude failed to run ...` - **not** `preflight: usage limit hit ...`, which stays
governed purely by agent-factory-2do's existing wait-window logic per AC5) is dropped once that
agent is known to have started again since the alert was logged. "Started again" is inferred
entirely from existing log data, in two ways, combined:

1. **A later preflight alert of its own.** `bd cannot reach` and `claude failed to run` both
   `exit 3` immediately (`bin/agent-loop.sh:308`, `:319-320`), so a second alert line for the same
   agent - of *any* kind, including a `usage limit hit` retry, which loops within its own process
   rather than exiting (`bin/agent-loop.sh:310-318`) - can only exist because a new process has
   since started. This needs no new marker: it's proven by the alert lines already in
   `alerts.log`.
2. **A later `started: role=...` line in that agent's own `logs/<agent>/loop.log`.** This is the
   pre-existing line `bin/agent-loop.sh:325` already logs once preflight succeeds and the main
   loop begins (used elsewhere as the liveness marker for "this agent has started" - see
   `docs/design/agent-factory-mi3.md`, `docs/design/agent-factory-9l0.md`,
   `tests/agent-factory-stg_test.sh`). It is unrelated to and untouched by this story.

Why not "preflight most recently succeeded" as the sole signal (i.e. (2) alone): AC3 requires that
when the same agent fails preflight twice in a row, only the newer failure is shown as soon as the
second start begins - independent of whether that second start's own preflight then passes. A
failed second start never logs a `started:` line, so (2) alone would never drop the first alert in
that case. Source (1) covers exactly this gap: any later alert line for the agent - success or not
- is itself proof a new process began, because the exit-type messages guarantee the earlier
process is dead.

Both existing signals are combined into a single "restart epoch" per agent before the alert list
is filtered a second time; if that epoch is later than a given `bd cannot reach`/`claude failed`
alert's own timestamp, the alert is dropped before it ever reaches the existing needs-human /
usage-limit / age-cutoff classification. If it isn't superseded, it falls through to that existing
classification completely unchanged (this is what gives AC2/AC6 - no regression - for free).

## Changes to `bin/agent-loop.sh`

None. No new marker file is written anywhere; `$CONTROL/state/<agent>/started_at` does not exist
in the shipped implementation. The existing `log "started: role=$ROLE ..."` line
(`bin/agent-loop.sh:325`) is read, not written, by this story, and only as one of two restart
signals (see Approach).

## Changes to `bin/board.sh`

`recent_alerts`'s line-format regex gains a capture group for the agent id that was already
sitting in the brackets (previously matched but discarded):

```bash
if [[ $line =~ ^([0-9T:-]+Z)\ \[([^]]*)\]\ (.*)$ ]]; then
  ts="${BASH_REMATCH[1]}"; agent="${BASH_REMATCH[2]}"; msg="${BASH_REMATCH[3]}"
```

New helper, alongside `still_needs_human`, reading the pre-existing `loop.log` liveness marker:

```bash
# agent_last_started_epoch AGENT_ID -> epoch of that agent's most recent successful-start marker
# (the "started: role=..." line agent-loop.sh logs to loop.log once preflight passes - a
# successful preflight itself logs nothing to alerts.log, so this is the only place that signal
# exists), or non-zero if there is none or it's unparseable. Fails open (non-zero => "no known
# restart"), same philosophy as still_needs_human.
agent_last_started_epoch() {
  local agent_id="$1" line ts
  line=$(grep -F "[$agent_id] started: role=" "$DATA_DIR/logs/$agent_id/loop.log" 2>/dev/null | tail -n 1)
  [ -n "$line" ] || return 1
  [[ $line =~ ^([0-9T:-]+Z)\ \[ ]] || return 1
  ts="${BASH_REMATCH[1]}"
  date -d "$ts" +%s 2>/dev/null
}
```

`recent_alerts` makes **two passes** over the same `tail -n 6 alerts.log` window (a single forward
pass can't work: whether an early line is superseded can depend on a later line the pass hasn't
reached yet - AC3):

**Pass 1** builds a per-agent `restart_epoch` map from every `preflight: (bd cannot reach|claude
failed to run|usage limit hit)` line seen (note: `usage limit hit` counts here as restart
*evidence*, per point (1) in Approach, even though it is never itself dropped - see agent-factory-
kuw below), taking the max timestamp per agent; then, for each agent with at least one such line,
raises that agent's `restart_epoch` further if `agent_last_started_epoch` returns a later epoch.

**Pass 2** re-walks the same lines and, for each `bd cannot reach`/`claude failed to run` line,
drops it (`continue`, before any other classification) iff its own timestamp is strictly earlier
than that agent's `restart_epoch`. Every other line - including `usage limit hit`, and every
non-preflight message - falls through unchanged to the pre-existing classification (needs-human /
usage-limit wait-window / `ALERT_MAX_AGE_MINUTES` cutoff), exactly as before this story.

- If `date -d "$ts"` fails on either pass (malformed timestamp), that line is skipped for restart-
  evidence purposes / falls through unclassified-by-this-check, matching the file's existing
  fail-open convention.
- `agent_last_started_epoch` and the `restart_epoch` map both fail open (agent-loop.sh never ran,
  or a fresh `DATA_DIR`, means "no known restart" - nothing is dropped).
- **Bugfix folded in (agent-factory-kuw):** the first implementation (f7fbd44) only fed `bd cannot
  reach`/`claude failed to run` lines into pass 1's restart-evidence scan, so an old exit-type
  alert was *not* dropped when the only later line for that agent was a `usage limit hit` retry
  (which doesn't exit the process, but *does* prove a later process started - see point (1) in
  Approach). Pass 1 was corrected to also scan `usage limit hit` lines as restart evidence, while
  pass 2 still never drops a `usage limit hit` line itself (that family's own wait-window logic
  from agent-factory-2do is the only thing that governs it, per AC5).

No other line in `recent_alerts` changes. `alerts.log` is still never rewritten; the `tail -n 6`
window still applies first, exactly as before.

## Acceptance criteria mapping

1. Earlier start's preflight alert, agent has since started again (either a later preflight line
   of its own, or a later `loop.log` `started:` line) → dropped, regardless of age.
2. Current start's own preflight alert, no later restart evidence → pass 2 falls through →
   governed by existing usage-limit/age-cutoff rules exactly as before.
3. Two successive starts, second one's preflight alert has no *later* restart evidence (yet) →
   it stays (per AC2 logic); the first one's own timestamp is earlier than the second alert's
   timestamp (itself restart evidence, per pass 1), so the first is dropped.
4. Per-agent: `restart_epoch` is keyed by agent id, built and consulted independently per agent -
   one agent's evidence never affects another agent's lines.
5. Non-preflight messages never match the `preflight: ...` patterns, and `usage limit hit` is
   never dropped by pass 2 even though it counts as restart evidence in pass 1 → identical to
   today for every family other than `bd cannot reach`/`claude failed to run`.
6. No restart evidence recorded for that agent → pass 2 falls through → existing tail-window +
   47q age-cutoff behavior, unchanged.

## Test strategy (as implemented: `tests/agent-factory-wzg_test.sh`)

Same sourced-function approach as `tests/agent-factory-47q_test.sh`: source `bin/board.sh` with a
scratch `DATA_DIR` and a stub `bd` on `PATH` (needed only for `still_needs_human` on the AC5
needs-human line), call `recent_alerts` directly. Restart evidence is fabricated by writing a
`started: role=...` line into a scratch `$DATA_DIR/logs/<agent>/loop.log` (helper `started_line`
+ the `LOOP_LOGS` associative array in the test file) - no `agent-loop.sh` invocation needed.

Covered cases (one function per AC, plus edge cases - see the test file for exact fixtures):
- `test_ac1_bd_unreachable_dropped_after_restart` / `test_ac1_claude_failed_dropped_after_restart`:
  each exit-type message dropped once a later `started:` line exists for that agent.
- `test_ac1_dropped_even_when_very_fresh`: dropped even at a 2s alert / 1s-later restart gap -
  proves this is restart-based, not age-based.
- `test_ac2_kept_when_agent_has_not_restarted_since`: no `loop.log` entry at all → alert shown.
- `test_ac3_only_most_recent_of_two_preflight_alerts_shown`: two exit-type alerts, no `loop.log`
  marker at all - the newer alert's own timestamp is itself the restart evidence that drops the
  older one.
- `test_edge_exit_type_alert_dropped_when_newer_usage_limit_alert_for_same_agent` (the
  agent-factory-kuw regression case): an old `bd cannot reach` alert is dropped once a newer
  `usage limit hit` alert for the same agent exists, even with no `loop.log` marker.
- `test_ac4_restart_affects_only_that_agents_own_alerts`: two agents, only one restarts → only
  that one's alert is dropped.
- `test_ac5_non_preflight_families_unaffected_by_restart`: needs-human, usage-limit,
  circuit-breaker, daily-budget, git-sync-failure, clone-failure lines all still shown, unaffected
  by a same-agent restart.
- `test_ac6_no_restart_old_alert_still_dropped_by_age_cutoff` /
  `test_ac6_no_restart_recent_alert_still_shown`: with no restart evidence at all, the pre-existing
  47q age-cutoff behavior is unchanged in both directions.
- `test_shellcheck_clean`: `shellcheck bin/board.sh` (skipped/fails in environments without
  shellcheck installed - a pre-existing environment gap, not specific to this story).

No manual/integration smoke test of `bin/agent-loop.sh` is needed for this story, since it is
unmodified.

## Out of scope (per story)
No change to `alert()`, `alerts.log` format/rotation, preflight's own retry/exit behavior or
message wording, `bin/agent-loop.sh`, or resolution logic for any non-preflight alert family.
