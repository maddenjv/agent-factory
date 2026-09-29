# Design: agent-factory-rez8 - Shutdown vs. startup

## Context
`bin/stop.sh graceful` only ever touches `$DATA_DIR/control/STOP`. Of the eight containers
`bin/start.sh` creates (`po architect qa engineer reviewer team-lead ops board`), only the six
role/team-lead ones run `bin/agent-loop.sh`, and only `agent-loop.sh` looks at that flag
(`stopping()`, agent-loop.sh:62, checked at the top of the main loop, agent-loop.sh:373). `ops`
(`bin/ops-shell.sh`) and `board` (`bin/board.sh`, `while :; do render; sleep 15; done`, no STOP
check, and per this story's "Out of scope" it must stay that way) never exit on their own, so the
tmux session they're panes of never goes away by itself. `bin/start.sh` then refuses to do
anything - including its own STOP-flag cleanup - whenever that stale session is still alive:
```bash
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Already running: tmux attach -t $SESSION"; exit 0
fi
rm -f "$DATA_DIR/control/STOP" "$DATA_DIR"/control/STOP.*
```
Separately, `stop.sh now`'s container list omits `team-lead`, a role that has run as its own
container since `agent-factory-dx0`.

Neither container in `ops`'s window has a docker socket (`docker-compose.yml`: "Container
hardening: no docker socket" on the `agent` service, which `ops`/`board` also run as), so nothing
running *inside* any container can ever `docker stop` or `tmux kill-session` anything. The
teardown this story needs can only happen on the host, where `bin/stop.sh` itself already runs
(`bin/lib.sh`'s own header: "Sourced by every host-side bin/*.sh script").

## Approach

### 1. `bin/lib.sh`: one shared role list
`stop.sh now` and the new watcher (below) both need "all six agent-loop.sh-driven containers,"
and today only `start.sh` has this list (split across a literal `pane team-lead team-lead agent`
call and its own `ROLES=(po architect qa engineer reviewer)` - deliberately left alone, since nothing
in this story touches pane composition). Add one constant next to `KIT_DIR`/`PROJECT_DIR` so the
two places that need the full six-role list can't drift apart:
```bash
FACTORY_ROLES=(po architect qa engineer reviewer team-lead)
```
`lib.sh` is sourced fresh by every script that needs it (not exported - bash can't export
arrays), same as today.

### 2. `bin/stop.sh`: `now` gains `team-lead`
```bash
now)
  for r in "${FACTORY_ROLES[@]}" ops board; do docker stop "factory-$r" >/dev/null 2>&1 & done; wait
  tmux kill-session -t "$SESSION" 2>/dev/null
  echo "..." ;;
```
Purely additive - same concurrent-`docker stop`-then-`wait`-then-`kill-session` shape as today,
just with `team-lead` in the list. This alone satisfies AC4. AC5 needs no further change: `now`
already kills the tmux session synchronously before `stop.sh` returns, so `start.sh`'s
`has-session` check already sees no session and already reaches its `rm -f STOP...` line - that
path was never broken, only `graceful` was.

### 3. `bin/stop.sh`: `graceful` launches a detached watcher, still returns immediately
```bash
graceful)
  mkdir -p "$DATA_DIR/control"
  touch "$DATA_DIR/control/STOP"
  echo "STOP flag set; agents exit after their current session, then ops/board and the tmux session stop automatically (see $DATA_DIR/control/graceful-shutdown.log)."
  nohup "$(dirname "${BASH_SOURCE[0]}")/stop-watch.sh" "$SESSION" \
    >>"$DATA_DIR/control/graceful-shutdown.log" 2>&1 </dev/null &
  disown
  ;;
```
`mkdir -p` moves one line earlier (was already implied by `touch`'s parent, now also needed for
the log file). `nohup ... & disown`: `stop.sh` is normally run directly from an operator's
interactive shell, which is exactly the case where a plain `&` isn't enough - if the operator's
terminal/session ends (SIGHUP) before the watcher finishes polling, an un-nohup'd, un-disowned
background job can be killed with it. `nohup` ignores SIGHUP for the watcher process itself;
`disown` removes it from the invoking shell's job table so the shell doesn't wait for or signal it
either. This keeps `stop.sh graceful`'s own behaviour exactly as fast/synchronous as it is today
(prints and returns immediately) while making AC1's teardown happen without any further command
from the operator.

### 4. `bin/stop-watch.sh` (new)
A small standalone script, not a function inside `stop.sh`, so QA can invoke it directly (real
polling loop, real exit behaviour) instead of only indirectly through a backgrounded `stop.sh`
call:
```bash
#!/usr/bin/env bash
# stop-watch.sh <session> - launched by bin/stop.sh's graceful mode, backgrounded and detached
# from the invoking terminal. Polls until none of FACTORY_ROLES' containers are still running,
# then stops ops/board and kills the tmux session housing every pane - the teardown a graceful
# stop needs that nothing else performs (docs/design/agent-factory-rez8.md). Never run directly
# by an operator.
set -uo pipefail   # narrower than stop.sh's -e: one bad poll must not kill a background watcher
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SESSION="${1:?usage: stop-watch.sh <session>}"
POLL_INTERVAL="${STOP_WATCH_POLL_INTERVAL:-15}"

role_running() { [ -n "$(docker ps -q -f "name=^factory-$1\$" 2>/dev/null)" ]; }

while :; do
  any=0
  for r in "${FACTORY_ROLES[@]}"; do role_running "$r" && { any=1; break; }; done
  [ "$any" -eq 0 ] && break
  sleep "$POLL_INTERVAL"
done

for r in ops board; do docker stop "factory-$r" >/dev/null 2>&1 & done
wait
tmux kill-session -t "$SESSION" 2>/dev/null
echo "$(date -u +%FT%TZ) graceful shutdown complete: ops/board stopped, tmux session $SESSION killed."
```
`STOP_WATCH_POLL_INTERVAL` (default 15s - agent sessions run up to `ITERATION_TIMEOUT`, 45m by
default, so sub-second polling would just be wasted `docker ps` calls) is overridable so QA's
tests don't need to wait real minutes between polls. `role_running` anchors the name filter
(`^factory-po$`, not a bare substring) so no role's container name can ever match another's.
Deliberately does not touch the STOP flag itself - `start.sh` already removes it once it gets past
the `has-session` check (see point 5), so clearing it here too would be redundant, and clearing it
*before* the tmux session is actually gone would let a same-second `start.sh` run race the
watcher's own teardown.

### 5. `bin/start.sh`: unchanged
AC2 falls out of point 3/4 with no code change: once the watcher's `tmux kill-session` has
actually run, `start.sh`'s existing `has-session` check no longer finds a session, so it falls
through to its existing `rm -f "$DATA_DIR/control/STOP" "$DATA_DIR"/control/STOP.*` line exactly
as it does on a from-nothing start today. AC3 (session still alive -> "Already running", exit 0,
nothing altered) is the same pre-existing branch, untouched. Confirmed by re-reading `start.sh`
top to bottom: nothing between the `has-session` check and the STOP-flag `rm` depends on anything
this story changes.

## Interfaces / data shapes
- New env var `STOP_WATCH_POLL_INTERVAL` (seconds, default 15), read only by `stop-watch.sh`.
- New log file `$DATA_DIR/control/graceful-shutdown.log` - append-only, one line per graceful stop
  cycle's final "teardown complete" message, plus anything either backgrounded `docker
  stop`/`tmux kill-session` call happens to write to stderr. Not read by any other script; purely
  an operator-visible trail for "did the automatic teardown actually happen yet."
- New shared constant `FACTORY_ROLES` in `bin/lib.sh` (array, six role names). No change to any
  existing exported variable.

## Error cases
- **A role container never exits** (agent wedged, `docker stop` never reaches it): the watcher
  polls forever - same "no timeout" shape `stopping()`'s "finish current session" already has
  today; this story explicitly leaves shortening/bypassing graceful shutdown out of scope. The
  operator retains `stop.sh now` as the immediate/forceful path (AC4).
- **`docker`/`tmux` transiently unavailable** when the watcher polls: `role_running`'s `docker ps`
  failure is swallowed by `2>/dev/null` and empty-output-so-false, so a transient error just reads
  as "not running yet" and the loop retries next interval rather than tearing down early or
  crashing (`set -uo pipefail`, no `-e`, matches `agent-loop.sh`'s own long-running-loop
  convention).
- **Two `graceful` invocations in a row** (operator re-runs `stop.sh graceful` before the first
  watcher has finished): both watchers converge on the same end state - each independently polls
  the same containers and, once none are running, issues the same idempotent `docker
  stop`/`tmux kill-session` calls (a second `docker stop`/`kill-session` against an
  already-stopped target is a no-op, same as today's `now` branch already assumes with its
  `2>&1 &`/`2>/dev/null`). No lock file is introduced; the redundant work is cheap and harmless.
- **Watcher's log directory missing**: `graceful` now does `mkdir -p "$DATA_DIR/control"` before
  backgrounding the watcher (was already implicitly required by `touch .../STOP`), so this can't
  happen in practice.

## How each acceptance criterion is satisfied
| AC | How |
|----|-----|
| 1 | `stop-watch.sh`, launched by `graceful`, polls `FACTORY_ROLES` and stops `ops`/`board` + kills the tmux session once all six are gone - no manual step beyond the original `stop.sh graceful`. |
| 2 | Once the watcher's `tmux kill-session` runs, `start.sh`'s existing `has-session` check (unmodified) falls through to its existing STOP-flag cleanup (unmodified). |
| 3 | `start.sh`'s `has-session` branch is untouched by this story. |
| 4 | `stop.sh now`'s container list becomes `"${FACTORY_ROLES[@]}" ops board`, adding `team-lead`. |
| 5 | `now` already kills the tmux session synchronously before returning - `start.sh` sees no session, same code path as AC2. |
| 6 | `clear` branch is untouched by this story. |

## Test strategy
Same technique `tests/acceptance/agent-factory-uhc.sh` already established for this codebase:
fake `docker` and `tmux` on `PATH` that log every invocation and answer from a small state
directory, since `bin/stop.sh`/`bin/stop-watch.sh` run on the host where neither is guaranteed
installed (confirmed absent in this sandbox). New file `tests/agent-factory-rez8_test.sh`,
following that file's PASS/FAIL/SKIP-per-AC convention (`bash tests/agent-factory-rez8_test.sh`).

- **AC4** (`now` includes `team-lead`): fake `docker` logs `stop` invocations; run `SESSION=<x>
  PROJECT_DIR=<scratch> PATH=<fakebin>:$PATH bin/stop.sh now`; assert the fake docker log's
  `stop` calls cover exactly `{po,architect,qa,engineer,reviewer,team-lead,ops,board}` (order
  agnostic - they're backgrounded); assert fake tmux log shows one `kill-session -t <x>` call;
  assert exit 0.
- **AC6** (`clear` unchanged): create `$DATA_DIR/control/STOP` and `STOP.po`; run `stop.sh clear`;
  assert both are gone; assert the fake docker/tmux logs are empty (no invocation at all); assert
  exit 0.
- **AC1/AC2, via `stop-watch.sh` directly** (fast, no real backgrounding/detach needed - test the
  watcher's own logic in isolation):
  1. Fake `docker ps -q -f name=...` reads container-is-running state from files the test controls
     (e.g. `$STATE/factory-po`, etc. - present = "running"); start with all six role files present.
  2. Run `STOP_WATCH_POLL_INTERVAL=1 PATH=<fakebin>:$PATH bin/stop-watch.sh <session>` in the
     background (real shell `&`, this test's own background job - not nohup'd, since the test
     process controls its own lifetime); assert that after ~2 poll intervals no `docker stop`/
     `kill-session` calls have appeared in the logs yet (still "running").
  3. Remove all six state files (simulating every role container exiting); within a few more poll
     intervals, assert the fake docker log shows `stop` calls for exactly `{ops,board}` and the
     fake tmux log shows `kill-session -t <session>`; assert the process has exited 0; assert
     `$DATA_DIR/control` (or wherever the test points stdout/stderr) contains the "graceful
     shutdown complete" line.
- **AC1, end-to-end through `stop.sh graceful`**: with the same fake docker/tmux, pre-arrange the
  state files so all six role containers already read as "not running" (so the watcher's loop
  exits on its first check) and `STOP_WATCH_POLL_INTERVAL=1`; run `stop.sh graceful`; assert it
  prints its message and returns near-instantly (doesn't block on the watcher); assert `STOP`
  exists immediately; then poll (bounded `until`/`sleep` loop, a few seconds' timeout) for the
  fake tmux log to show `kill-session` and for `graceful-shutdown.log` to show the completion
  line - proving `stop.sh` actually launched a working, detached watcher rather than the test only
  exercising `stop-watch.sh` in isolation.
- **AC3 regression**: fake tmux reports the session exists; run `start.sh`; assert "Already
  running", exit 0, and (as `agent-factory-uhc`'s own AC6 test already checks) exactly one tmux
  call (`has-session`) - i.e. still short-circuits before touching STOP. This story doesn't change
  `start.sh`, so this test is a regression guard, not new coverage.
- **shellcheck**: `bin/stop.sh`, `bin/stop-watch.sh`, `bin/lib.sh` - project convention for any
  touched bash file.
