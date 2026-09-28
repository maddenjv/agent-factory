# Design: agent-factory-q4tj - team-lead-driven WIP throttle for po/architect

## Context
Today `bin/agent-loop.sh`'s `wip_ok()` gates only `po` (`architect` is never throttled) against a
fixed `WIP_LIMIT` count of "stories with an open `role:reviewer` issue," computed by `in_flight()`,
with `idle_downstream_role()` letting `po` proceed anyway whenever architect/engineer/qa/reviewer
has nothing ready or in-progress. It's a static bash heuristic with no notion of backlog
complexity and no quota/budget awareness, and it has a known accounting gap
(`agent-factory-gn4v`): once a story has only its `role:team-lead,needs-chain` issue open (no
stage issue yet, since `agent-factory-x8wj`), it counts toward neither `in_flight()` nor
`idle_downstream_role()`.

Human decision (2026-09-28, on `agent-factory-gn4v`, approved - see that issue's notes): rather
than patch the accounting gap, move the decision itself off `po`'s fixed rule and onto
`team-lead`'s judgment, sized to keep `engineer`/`qa`/`reviewer` busy (where most agent time is
spent) and aware of remaining quota/budget. This story therefore **removes** `WIP_LIMIT`,
`in_flight()`, `idle_downstream_role()` and `wip_ok()` outright rather than keeping them alongside
a new mechanism - AC3 ("not a fixed count... or any other hardcoded number") rules out keeping a
parallel hardcoded cap, and AC5 asks for `gn4v`'s gap to be "resolved as a consequence of this
story, not patched separately," which a full replacement gives for free: `team-lead` reads the
whole board itself, so there's no separate mechanical "in flight" count to have a blind spot in.

### Mechanism choice
The story's "Out of scope" explicitly leaves the reaching-po/architect mechanism to me, naming "a
new team-lead poll trigger, a control file, a bd label, or a synthetic issue" as options. I picked
**a control file (`$CONTROL/throttle.json`) written by a periodic, issue-less `team-lead` session**,
not a bd issue, for one concrete reason: `team-lead`'s three existing entry points
(`needs-team-lead`, `needs-chain`, the no-`role:*`-label sweep) are all one-shot - read, decide,
close, done forever. This assessment is the opposite: AC6 requires it to keep being redone as
conditions change, for as long as the factory runs. Forcing that through a bd issue would mean
either reopening a closed issue on a timer (nothing in this codebase does that, and
`handle_outcome()`/`record_failure()` both assume "closed" is terminal) or creating a fresh issue
every cycle (issue-id churn with no real handoff value - nobody downstream reads it the way a
story's chain does). A plain control file, refreshed on a timer straight out of `team-lead`'s own
idle loop, avoids inventing either of those. `po`/`architect`'s `wip_ok()` already reads
Beads/filesystem state directly and cheaply on every loop tick without spawning a Claude session -
the replacement, `throttle_ok()`, does the same, just against this file instead of `bd list`.

## Approach

### 1. `bin/agent-loop.sh` - replace the throttle, add the periodic assessment trigger

**Config (near the top, replacing the `WIP_LIMIT` line):**
```bash
THROTTLE_STALE_SECS="${THROTTLE_STALE_SECS:-900}"        # how often team-lead re-assesses
THROTTLE_ALERT_STALE_SECS="${THROTTLE_ALERT_STALE_SECS:-3600}"  # alert if it falls further behind than this
```
(`DAILY_BUDGET_USD` line right below is untouched.)

**Throttles section, replacing `in_flight()`/`idle_downstream_role()`/`wip_ok()` in full:**
```bash
# ---------- throttles ----------
# team-lead-driven WIP throttle (agent-factory-q4tj): po and architect - top-of-funnel - start new
# work only while team-lead judges the engineer/qa/reviewer backlog has room and usage quota is
# likely to last. team-lead is never throttled by this (it has to keep running to produce the
# assessment), and engineer/qa/reviewer are never throttled by it either - only po/architect are
# top-of-funnel. The judgment itself lives entirely in team-lead's own Claude Code session
# (agents/team-lead.md's "Assess the po/architect throttle") - nothing here second-guesses it;
# this is just the plumbing that reads its last recorded decision and keeps it fresh.
THROTTLE_FILE="$CONTROL/throttle.json"

throttle_age() {  # seconds since the last recorded assessment, or a large number if there is none
  local ts epoch
  ts=$(jq -r '.assessed_at // empty' "$THROTTLE_FILE" 2>/dev/null)
  [ -n "$ts" ] || { echo 999999; return; }
  epoch=$(date -d "$ts" +%s 2>/dev/null) || { echo 999999; return; }
  echo $(( $(date +%s) - epoch ))
}

throttle_ok() {  # false only for po/architect, and only once team-lead has recorded idle:true.
                  # No assessment yet (fresh run, or team-lead falling behind) fails OPEN - po and
                  # architect proceed. Deliberate: DAILY_BUDGET_USD and the Claude Code plan usage
                  # limit (both enforced unconditionally elsewhere in this loop) are the hard stops
                  # against runaway spend; this is a softer "don't start work you can't finish"
                  # layer on top of those, and a missing/stale file must not silently wedge the
                  # whole factory at the top of the funnel just because team-lead's own loop
                  # hiccuped - see throttle_stale_alert() below for how a human finds out that
                  # happened instead.
  case "$ROLE" in po|architect) ;; *) return 0 ;; esac
  [ -f "$THROTTLE_FILE" ] || return 0
  jq -e '.idle != true' "$THROTTLE_FILE" >/dev/null 2>&1
}

throttle_stale_alert() {  # team-lead only, see main loop - alerts once when assessments stop
                           # arriving, resets once they resume so a later real staleness re-alerts
  local age; age=$(throttle_age)
  if [ "$age" -ge "$THROTTLE_ALERT_STALE_SECS" ]; then
    [ "$throttle_stale_alerted" = 1 ] || alert "throttle assessment stale (${age}s > ${THROTTLE_ALERT_STALE_SECS}s) - po/architect are running unthrottled in the meantime"
    throttle_stale_alerted=1
  else
    throttle_stale_alerted=0
  fi
}
```
`spent_today()`/`budget_ok()` right below: unchanged.

**`build_prompt()`: unchanged.** New function added right after it:
```bash
build_throttle_prompt() {
  cat "$KIT_DIR/agents/team-lead.md"
  printf '\n\n---\nNo bd issue this session: assess the po/architect throttle now (see "Assess the po/architect throttle" above), then record it with bin/set-throttle.sh - that is the only place this decision is recorded, so do not skip it.\nRepository: %s (your own clone; remote "origin"). Shared conventions are in CLAUDE.md. KIT_DIR=%s PROJECT_DIR=%s\n' "$REPO" "$KIT_DIR" "$PROJECT_DIR"
}
```

**`run_agent()` becomes a thin wrapper around a shared session runner** (same body as today,
renamed and generalized to take a log name and a prompt instead of always deriving both from a bd
issue id):
```bash
run_claude_session() {  # run_claude_session LOGNAME PROMPT -> sets LAST_RUN_QUOTA_MSG (empty
                         # unless this run hit a usage limit); shared by run_agent() (one bd issue)
                         # and run_throttle_assessment() (no bd issue).
  local logname=$1 prompt=$2 logfile errfile outfile cost
  logfile="$LOGDIR/$(date +%F).$logname.jsonl"
  errfile=$(mktemp); outfile=$(mktemp)
  local args=(-p "$prompt" --dangerously-skip-permissions --max-turns "$MAX_TURNS"
              --output-format stream-json --verbose)
  [ -n "$MODEL" ] && args+=(--model "$MODEL")
  ( cd "$REPO" && timeout "$ITERATION_TIMEOUT" claude "${args[@]}" 2>"$errfile" ) \
    | tee -a "$logfile" "$outfile" | jq -R -r --unbuffered "$RENDER" 2>/dev/null
  cost=$(jq -rs '[.[] | select(.type=="result")] | last | .total_cost_usd // 0' "$logfile" 2>/dev/null)
  echo "${cost:-0}" >> "$CONTROL/cost/$ROLE.$(date +%F)"
  cat "$errfile" >> "$LOGDIR/claude-err.log"
  LAST_RUN_QUOTA_MSG=$(quota_hit_message "$errfile")   # stderr, else this run's final error result
  [ -n "$LAST_RUN_QUOTA_MSG" ] || LAST_RUN_QUOTA_MSG=$(quota_hit_from_stream "$outfile")
  rm -f "$errfile" "$outfile"
}

run_agent() { run_claude_session "$1" "$(build_prompt "$1")"; }               # sets LAST_RUN_QUOTA_MSG
run_throttle_assessment() { run_claude_session throttle "$(build_throttle_prompt)"; }  # sets LAST_RUN_QUOTA_MSG
```
Byte-for-byte the same `claude` invocation, cost accounting and quota detection as today's
`run_agent()` - only the id-vs-logname/prompt split changed, so no existing behaviour for a normal
issue session changes.

**Main loop:** replace
```bash
fails=0
idle_logged=0
while :; do
  if stopping; then log "STOP requested; exiting"; exit 0; fi
  if ! budget_ok; then alert "daily budget reached ($(spent_today) USD); pausing 30 min"; sleep 1800; continue; fi
  if ! wip_ok; then sleep "$IDLE_SLEEP"; continue; fi

  id=$(next_issue)
  if [ -z "$id" ]; then
    [ "$idle_logged" = 1 ] || { log "queue empty; idling"; idle_logged=1; }
    sleep "$IDLE_SLEEP"; continue
  fi
  idle_logged=0
```
with
```bash
fails=0
idle_logged=0
throttle_idle_logged=0
throttle_stale_alerted=0
while :; do
  if stopping; then log "STOP requested; exiting"; exit 0; fi
  if ! budget_ok; then alert "daily budget reached ($(spent_today) USD); pausing 30 min"; sleep 1800; continue; fi

  [ "$ROLE" = "team-lead" ] && throttle_stale_alert

  if ! throttle_ok; then
    if [ "$throttle_idle_logged" != 1 ]; then
      log "idle: team-lead throttle holding $ROLE back ($(jq -r '.reason // "no reason recorded"' "$THROTTLE_FILE" 2>/dev/null))"
      throttle_idle_logged=1
    fi
    sleep "$IDLE_SLEEP"; continue
  fi
  throttle_idle_logged=0

  id=$(next_issue)
  if [ -z "$id" ]; then
    if [ "$ROLE" = "team-lead" ] && [ "$(throttle_age)" -ge "$THROTTLE_STALE_SECS" ]; then
      log "no triage work; throttle assessment due (last one $(throttle_age)s ago)"
      if sync_repo; then
        run_throttle_assessment
        if [ -n "$LAST_RUN_QUOTA_MSG" ]; then
          wait_s=$(usage_limit_wait_seconds "$LAST_RUN_QUOTA_MSG")
          alert "throttle assessment: usage limit hit ($LAST_RUN_QUOTA_MSG); waiting ${wait_s}s"
          sleep "$wait_s"; continue
        fi
      else
        log "git sync failed; throttle assessment skipped this cycle"
      fi
      sleep "$IDLE_SLEEP"; continue
    fi
    [ "$idle_logged" = 1 ] || { log "queue empty; idling"; idle_logged=1; }
    sleep "$IDLE_SLEEP"; continue
  fi
  idle_logged=0
```
Everything from `if ! claim "$id"; then ...` onward: **unchanged**. `throttle_ok` short-circuits to
`return 0` for every role except `po`/`architect` (`case` statement), so this new block is a no-op
for `engineer`/`qa`/`reviewer`, and for `team-lead` it only ever affects the (pre-existing, just
relocated) `budget_ok` gate plus the new stale-assessment check - never `throttle_ok` itself. The
assessment run is deliberately not wrapped in `claim`/`handle_outcome`/`record_failure`: there is
no bd issue to claim or fail, so a crashed or timed-out assessment simply leaves `throttle.json`
stale, which the very next idle tick (`IDLE_SLEEP` later) retries on its own - see Error cases.

### 2. `bin/set-throttle.sh` - new file, the only writer of `throttle.json`
```bash
#!/usr/bin/env bash
# Usage: set-throttle.sh <go|idle> "<reason>"
# Records team-lead's current judgment on whether po/architect may claim new top-of-funnel work
# (agent-factory-q4tj) - see agents/team-lead.md's "Assess the po/architect throttle" and
# bin/agent-loop.sh's throttle_ok()/throttle_age(). engineer, qa and reviewer never read this file.
#
# Runs inside team-lead's own Claude Code session (bin/agent-loop.sh's run_throttle_assessment()),
# whose cwd is its own clone ($DATA_DIR/workspaces/team-lead), not $PROJECT_DIR - so, unlike
# bin/lib.sh's host-side scripts, this does not take DATA_DIR from $PWD. It doesn't need to: every
# agent container already has DATA_DIR exported (bin/env.sh, sourced early in agent-loop.sh, while
# PWD is still the container's $PROJECT_DIR working_dir - see docker-compose.yml), so it's already
# in this session's environment. The PROJECT_DIR-based fallback below only matters if this is ever
# run by hand outside that flow.
set -euo pipefail
: "${PROJECT_DIR:?PROJECT_DIR must be set (set by docker-compose in every agent container)}"
DATA_DIR="${DATA_DIR:-$PROJECT_DIR/.agent-factory}"
CONTROL="$DATA_DIR/control"
mkdir -p "$CONTROL"

decision=${1:?usage: set-throttle.sh <go|idle> "<reason>"}
reason=${2:?usage: set-throttle.sh <go|idle> "<reason>"}
case "$decision" in
  go)   idle=false ;;
  idle) idle=true ;;
  *) echo "set-throttle.sh: decision must be 'go' or 'idle', got '$decision'" >&2
     echo "usage: set-throttle.sh <go|idle> \"<reason>\"" >&2; exit 2 ;;
esac
[ -n "${reason//[[:space:]]/}" ] || { echo "set-throttle.sh: reason must not be empty" >&2; exit 2; }

tmp=$(mktemp "$CONTROL/throttle.json.XXXXXX")
jq -n --argjson idle "$idle" --arg reason "$reason" --arg ts "$(date -u +%FT%TZ)" \
  '{idle: $idle, reason: $reason, assessed_at: $ts}' > "$tmp"
mv -f "$tmp" "$CONTROL/throttle.json"
echo "throttle: $decision - $reason"
```
`chmod +x bin/set-throttle.sh`. The temp-file-then-`mv` (same directory, so same filesystem) makes
the write atomic - `throttle_ok()`/board.sh reading concurrently never see a half-written file.

### 3. `agents/team-lead.md` - a fourth, issue-less kind of session

Intro paragraph replaced (the one describing team-lead's entry points):
```markdown
Your job is triage, not implementation: diagnose why a piece of work is stuck, decide a new
story's stage chain, judge whether po and architect should keep starting new work, or find where
an unrouted issue belongs, and either correct its routing, size the chain, record a throttle
decision, or hand it to a human - you never write story/design/code/test content yourself. Unlike
the other five roles, you have no ongoing `role:team-lead` work queue in the usual sense;
`agent-loop.sh`'s team-lead poll runs one of four kinds of session, stated in the trailer after
this file: a bd issue that belongs to some *other* role's stage, already labelled
`needs-team-lead`, keeping whatever `role:`/`stage:` labels it also carries; a new story's
`role:team-lead,needs-chain` issue, created by po right after it writes
`docs/stories/<story-id>.md`, asking you to decide which stages that story's chain needs; a bd
issue with no `role:*` label at all (and not `needs-human`), found by sweeping the board for work
that never got routed anywhere; or no bd issue at all - a periodic check of whether po and
architect should keep claiming new top-of-funnel work (see "Assess the po/architect throttle"
below). If the trailer says "Your assigned issue: <id>", `bd show <id>` first: if it carries
`needs-chain`, skip to "Size a new story's chain" below instead of steps 1-5; if it carries
`needs-team-lead`, follow steps 1-5 below unchanged; if it carries no `role:*` label, skip to
"Sweep: issues with no `role:*` label" instead. If the trailer instead says "No bd issue this
session", skip directly to "Assess the po/architect throttle" below.
```
Steps 1-5, "Size a new story's chain", and "Sweep: issues with no `role:*` label": **unchanged**
(out of scope - no change to any existing entry point's logic).

New section, appended at the end of the file:
```markdown
## Assess the po/architect throttle

Triggered with no bd issue at all - `agent-loop.sh` runs this whenever your own queue (steps 1-5
above, "Size a new story's chain", and the sweep above) is empty and the last assessment is more
than `THROTTLE_STALE_SECS` seconds old (see `bin/agent-loop.sh`'s `throttle_age()`/`throttle_ok()`).
There is nothing to `bd show` here - the trailer after this file says so explicitly.

po and architect are top-of-funnel: they start new stories/design work. engineer, qa and reviewer
are never idled by this policy - they are where most agent time is actually spent, and keeping
them fed is the point. Your job here is the same kind of judgment call as sizing a story's stage
chain (above): there is no fixed rubric for "the backlog is too large" or "quota is too low" - you
decide per situation, favoring finishing in-flight work over starting new work whenever you're
unsure.

1. Read broadly, the same habit as steps 1-5 above:
   - `bd list --limit 200 --json` for the whole board: how many stories are open, at what stage
     each sits, how much is stalled on `needs-human`/`needs-team-lead`, and - this matters - how
     many stories have only a `role:team-lead,needs-chain` issue open with no design/tests/
     implement/verify/review issue built yet (`bin/new-story.sh` hasn't run for them). Those count
     as occupying capacity too, exactly like any other in-flight story - they just haven't reached
     `bin/new-story.sh` yet.
   - Weigh depth *and* shape, not just a count: a handful of stories each with one stuck
     `needs-human` issue is a different situation than a dozen stories all sitting healthy at
     `stage:implement` - use judgment.
   - Usage/spend signals - reuse these rather than duplicating them: today's total spend across
     `$DATA_DIR/control/cost/*.$(date +%F)` against `$DAILY_BUDGET_USD` (if it's set - empty means
     no cap), and how recently `$DATA_DIR/control/alerts.log` shows a "usage limit hit" line for
     any role. Favor completion of in-flight work over starting new work whenever the factory
     looks unlikely to finish new work before quota/budget runs out.
2. Decide: `go` (there's room; po/architect may keep claiming new ready work) or `idle` (hold
   po/architect back - the backlog is too large to justify starting more, or quota/budget is too
   thin to finish it). This is a live judgment, not a one-time decision - whatever you record now
   holds until your next assessment (`THROTTLE_STALE_SECS` later, or sooner if a human triggers
   one), so state a reason that will still make sense to whoever reads it then.
3. Record it: `"$KIT_DIR/bin/set-throttle.sh" go "<reason>"` or `"$KIT_DIR/bin/set-throttle.sh"
   idle "<reason>"` - the reason is what a human sees on the board and in the logs (`bin/board.sh`,
   and `agent-loop.sh`'s own log line when po/architect find themselves idled), so make it
   specific: what you looked at and why it does or doesn't justify starting more work. This is the
   only record of this session - there is no bd issue to comment on or close.

Nothing here ever touches `needs-human`/`needs-team-lead` or any bd issue - if you find a
*specific* stuck issue while reading broadly, that's a separate problem: leave it for its own
needs-team-lead/sweep pass, don't fix it here, and don't let it block recording a throttle decision.
```

### 4. `.env.example`
Remove the `WIP_LIMIT=2 ...` line. Add, near `IDLE_SLEEP`:
```
THROTTLE_STALE_SECS=900        # how often team-lead re-assesses whether po/architect may start new work
THROTTLE_ALERT_STALE_SECS=3600 # alert if an assessment falls further behind than this (team-lead may be stuck/down); po/architect fail OPEN while stale, not idle
```

### 5. `README.md`
Guardrails paragraph: the `WIP limit on the PO (...)` clause replaced with:
```markdown
a team-lead-judged throttle on `po`/`architect` only (never `engineer`/`qa`/`reviewer`) - team-lead
periodically weighs the engineer/qa/reviewer backlog and remaining usage/budget quota and records
`go`/`idle` (with a reason) in `.agent-factory/control/throttle.json`; see the board's `-- throttle
--` line for the current call (`agent-factory-q4tj`);
```
"Day to day" table's team-lead row: append a clause - "...it also periodically judges whether
po/architect should keep starting new work; see the board's `-- throttle --` line for its current
call and reason."

### 6. `docs/ARCHITECTURE.md`
Team-lead paragraph gets one more sentence appended (after the existing `needs-chain` sentence):
```markdown
Since `agent-factory-q4tj`, it also runs a fourth, issue-less kind of session on a timer
(`THROTTLE_STALE_SECS`, default 900s): it judges whether `po`/`architect` should keep starting new
top-of-funnel work, based on how deep the `engineer`/`qa`/`reviewer` backlog has grown (including
stories that only have a `needs-chain` issue open) and how much usage quota/budget remains, and
records that judgment - with a reason - in `.agent-factory/control/throttle.json`
(`bin/set-throttle.sh`). `bin/agent-loop.sh`'s `throttle_ok()` reads it for `po`/`architect` only;
`engineer`/`qa`/`reviewer` are never throttled by it, and a missing/stale file fails open (see
`docs/design/agent-factory-q4tj.md`'s Error cases) rather than wedging the whole factory.
```

### 7. `bin/board.sh` - surface the current call so "idle" isn't silent (AC7)
New function, plus one call in `render()`:
```bash
throttle_section() {
  local f="$DATA_DIR/control/throttle.json"
  [ -f "$f" ] || { echo "(no assessment yet - po/architect proceed unthrottled)"; return; }
  jq -r '(if .idle then "IDLE" else "GO" end) as $s | "\($s)  (assessed \(.assessed_at // "?"))  \(.reason // "no reason recorded")"' "$f" 2>/dev/null \
    || echo "(unreadable: $f)"
}
```
In `render()`, right after the `== ... ==` header line and before `-- in progress --`:
```bash
echo; echo "-- throttle (po/architect) --"
throttle_section
```

## Error cases
- **No `throttle.json` yet** (fresh factory, or team-lead not caught up): `throttle_ok()` fails
  open - po/architect proceed. Deliberate (see `throttle_ok()`'s comment above): the hard spend
  guards (`budget_ok`, the Claude Code plan usage-limit wait) already exist and apply regardless;
  this mechanism is a softer layer on top of them, and a startup/outage window must not
  permanently wedge the top of the funnel. `throttle_stale_alert()` (team-lead's own loop only)
  surfaces the "team-lead isn't keeping up" condition once it passes `THROTTLE_ALERT_STALE_SECS`
  (default 1h) so a human notices even though the factory keeps running.
- **team-lead's assessment session crashes, times out, or forgets to call `set-throttle.sh`**:
  `throttle.json` simply stays stale; there's no bd issue to fail, so none of
  `record_failure`/the attempt cap/the circuit breaker apply. The very next idle tick
  (`IDLE_SLEEP` later) re-evaluates `throttle_age() >= THROTTLE_STALE_SECS` and retries
  automatically - same self-healing shape as today's usage-limit retry, just without a bd issue to
  release.
- **Usage limit hit mid-assessment**: handled identically to a normal issue session -
  `usage_limit_wait_seconds` sleep, not counted as a failure - except there's no issue to release
  first, so that step is simply skipped.
- **Concurrent read while `set-throttle.sh` is writing**: the write goes to a `mktemp` file in the
  same directory, then `mv -f` (atomic rename on the same filesystem) - `throttle_ok()`/
  `throttle_section()` never observe a partially-written file.
- **First-ever startup**: no file exists, so po/architect start immediately (fail-open above);
  team-lead's own first idle tick (as soon as its own queue is empty, typically its very first
  loop iteration) immediately runs the first assessment, since `throttle_age()` on a missing file
  returns `999999`, always `>= THROTTLE_STALE_SECS`.
- **`agent-factory-gn4v`'s accounting gap** (a story counted toward neither old check while
  awaiting `needs-chain` sizing): resolved as a consequence, not patched - there is no longer a
  separate mechanical "in flight" count with its own blind spot; team-lead reads `bd list` itself
  each assessment and is explicitly told (section 3, step 1) to count `needs-chain`-only stories as
  occupying capacity.
- **Obsolete regression tests**: `tests/agent-factory-8wq_test.sh`, `tests/agent-factory-zwn7_test.sh`
  and `tests/agent-factory-ulq_test.sh` all extract and exercise `in_flight()`/`wip_ok()` directly
  (via `sed -n '/^in_flight()/,/^wip_ok()/p' bin/agent-loop.sh`) - functions this story deletes.
  QA must **delete all three files** as part of this story's write-tests/verify stage; this is not
  a regression (the mechanism they pin down is being deliberately replaced, per AC3/AC5), and
  nothing should attempt to keep `in_flight()`/`idle_downstream_role()`/`wip_ok()`/`WIP_LIMIT`
  around as a compatibility shim. `tests/agent-factory-dx0_test.sh`,
  `tests/agent-factory-m7af_test.sh` and `tests/agent-factory-x8wj_test.sh` (team-lead's other
  three entry points) are unaffected: their fixtures all make `next_issue()` return a real id, so
  the new "queue empty -> throttle assessment" branch never fires in them, and `throttle_ok()`
  itself is a no-op for `ROLE=team-lead`.

## Acceptance criteria mapping
1 -> §1 `throttle_ok()`'s `go` path + main loop. 2 -> §1 `throttle_ok()`'s `case "$ROLE" in
po|architect` (nothing else is ever gated) + main loop's idle branch + §2 `set-throttle.sh idle`.
3 -> §3's explicit "no fixed rubric... you decide per situation" + the fact that no numeric
comparison of any kind remains in `bin/agent-loop.sh`'s throttle code (§1). 4 -> §3 step 1's
usage/spend bullet (reads `$DATA_DIR/control/cost/*`, `DAILY_BUDGET_USD`, `alerts.log` - the
existing guardrails, reused not duplicated). 5 -> §3 step 1's first bullet (`needs-chain`-only
stories explicitly named as occupying capacity) + Error cases' `gn4v` note. 6 -> §1
`THROTTLE_STALE_SECS`-driven re-assessment in team-lead's own loop, and `throttle_ok()` reading the
file fresh (no caching) on every `po`/`architect` loop tick. 7 -> §1's "idle: team-lead throttle
holding $ROLE back (<reason>)" log line + §2's `reason` field + §7's board section +
`throttle_stale_alert()`.

## Test strategy (QA)
No unit-test framework (see `docs/ARCHITECTURE.md`) - same acceptance-style approach as every
prior `bin/agent-loop.sh` story (`agent-factory-8wq`/`zwn7`/`ulq`/`dx0`/`x8wj`). New
`tests/agent-factory-q4tj_test.sh`, one function per acceptance criterion:

- **AC1/AC2/AC6 (`throttle_ok()`/`throttle_age()`)**: extract the two functions from
  `bin/agent-loop.sh` with a stub `bd`-free, file-only harness (no `bd` needed at all - unlike the
  old `in_flight()`, these only ever read `$THROTTLE_FILE`): write fixture `throttle.json` files
  (`{"idle":false,...}`, `{"idle":true,...}`, missing file, malformed JSON, a file with an old
  `assessed_at`) into a scratch `$CONTROL`, source the extracted functions with
  `THROTTLE_FILE="$scratch/throttle.json"`, and assert `throttle_ok`'s exit status for
  `ROLE=po`/`ROLE=architect` (both must behave identically) vs `ROLE=engineer`/`qa`/`reviewer`/
  `team-lead` (always exit 0, regardless of the fixture - AC2's "never idled"). AC6: write `idle`,
  assert `throttle_ok` false; overwrite the same file with `go`; assert `throttle_ok` true on the
  very next call with no other state change - the "not a one-time snapshot" behaviour.
- **AC7 (visible reason)**: with an `idle` fixture, run the real `bin/agent-loop.sh` main-loop body
  (same harness style as `tests/agent-factory-dx0_test.sh`'s "real loop, stub `claude`") for
  `ROLE=po` for one iteration and grep `loop.log` for the `idle: team-lead throttle holding`
  line containing the fixture's `reason` text; separately, source `bin/board.sh`'s
  `throttle_section` against the same fixture and assert it prints the `reason`.
- **§2 `set-throttle.sh`**: run it directly against a scratch `DATA_DIR` for both `go`/`idle`,
  assert `throttle.json`'s shape (`jq` round-trip: `.idle` boolean, `.reason`, `.assessed_at`
  parseable), assert a bad first arg exits non-zero without writing the file, assert an empty
  reason is rejected.
- **AC1/AC6 (periodic assessment trigger)**: real-loop harness, `ROLE=team-lead`, stub `bd list`
  returning no `needs-team-lead`/`needs-chain`/unrouted issue (so `next_issue` is empty) and a stub
  `claude` that just runs `bin/set-throttle.sh go "test"` and exits - with `THROTTLE_STALE_SECS=0`
  assert the stub `claude` gets invoked and `throttle.json` ends up fresh; with
  `THROTTLE_STALE_SECS` large and a fresh fixture file, assert it does *not* get invoked (stub
  `claude` call-count fixture, same technique `tests/agent-factory-dx0_test.sh` already uses for
  its stub).
- **AC3/AC4/AC5 (team-lead prompt content)**: grep `agents/team-lead.md`'s new section for: "no
  fixed rubric" or equivalent near "per situation" (AC3); `DAILY_BUDGET_USD` and `alerts.log`
  appearing together (AC4); `needs-chain` appearing together with "occupying capacity" or
  equivalent (AC5).
- **Regression**: `tests/agent-factory-dx0_test.sh`, `tests/agent-factory-m7af_test.sh`,
  `tests/agent-factory-x8wj_test.sh` must still report `failed=0` unmodified - verify by actually
  running all three against the new `bin/agent-loop.sh`/`agents/team-lead.md` during this design
  session's own check (do this before closing, same as `x8wj`'s design session did for its four
  regression suites).
- **Deletion**: confirm `tests/agent-factory-8wq_test.sh`, `tests/agent-factory-zwn7_test.sh`,
  `tests/agent-factory-ulq_test.sh` are removed (not just left failing) and that `git grep -n
  'WIP_LIMIT\|in_flight()\|idle_downstream_role()\|wip_ok()'` across `bin/`, `agents/`,
  `README.md`, `.env.example`, `docs/ARCHITECTURE.md` returns nothing (historical
  `docs/design/*.md`/`docs/stories/*.md` files are exempt - left as-is, per CLAUDE.md they are a
  historical record, not living documentation).
- `shellcheck bin/agent-loop.sh bin/set-throttle.sh bin/board.sh` on the diff.
