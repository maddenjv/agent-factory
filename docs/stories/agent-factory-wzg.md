# agent-factory-wzg: Preflight recent alerts

## Story
As an agent-factory operator watching the tmux board, I want a preflight-failure alert to
disappear from "recent alerts" as soon as that agent has started again, so that a problem from an
earlier, superseded start doesn't keep looking like a current problem after the agent has since
gotten past preflight.

## Context
`bin/agent-loop.sh` runs preflight checks once at the top of every run, before it starts pulling
issues: `bd ready` reachability (agent-loop.sh:283), then a live `claude` call, retried on a usage
limit and alerting on failure (agent-loop.sh:284-296). Each of the three preflight alert messages
is prefixed with that run's `$AGENT_ID` and a timestamp, same as every other line in
`alerts.log`.

A successful preflight logs nothing - so unlike the alerts story agent-factory-2do already knows
how to resolve (needs-human: label cleared; usage-limit: wait window elapsed), there is today no
signal at all that a preflight failure has stopped being true. If an agent's container is
restarted (whether via a fresh `bin/start.sh`, or an operator respawning just that one pane after
a crash) and preflight now passes, the earlier failure alert just sits in `alerts.log` and keeps
showing on the board - subject only to agent-factory-47q's 1-hour age cutoff - even though that
agent is now past preflight and running normally. The requester observed exactly this: a stale
preflight alert still on the board after the agent in question had clearly started again.

This story treats "that agent has started again" as a new resolution condition for preflight
alerts specifically, the same way 2do treats a cleared label or an elapsed wait window as
resolution for its two alert families. Scope is **per agent**, not one event for the whole
tmux session: a preflight alert is superseded the moment *that same agent* starts again,
regardless of whether the restart was part of a full `bin/start.sh` run or just that one pane
being respawned, and independently of what any other agent is doing. This is a deliberate reading
of "most recent factory start" in the original request - it's the interpretation that actually
removes stale entries in the case that motivated the request (one pane restarting), and it keeps
every other agent's alerts unaffected.

## Acceptance criteria

1. **Given** a preflight alert was logged for an agent during an earlier start, **and** that same
   agent has since started again, **when** the board refreshes, **then** that earlier preflight
   alert no longer appears in "recent alerts", regardless of how recently it was logged.
2. **Given** a preflight alert was logged for an agent during its current (most recent) start,
   **and** that agent has not started again since, **when** the board refreshes, **then** the
   alert still appears, subject to the existing tail-window and age-cutoff limits.
3. **Given** two preflight alerts were logged for the same agent from two different, successive
   starts, **when** the board refreshes, **then** only the alert from that agent's most recent
   start appears - the older one is dropped even if it would otherwise still be within
   agent-factory-47q's age cutoff.
4. **Given** preflight alerts exist for two different agents, **when** one of those agents starts
   again, **then** only that agent's own earlier preflight alerts are affected - the other
   agent's preflight alert continues to be shown or hidden purely by its own start history.
5. **Given** an alert that is not a preflight alert (needs-human, usage-limit, circuit breaker,
   daily budget, git sync failure, clone failure), **when** the board refreshes, **then** this
   story's start-based expiry does not apply to it - its existing behaviour from
   agent-factory-2do / agent-factory-47q is unchanged.
6. **Given** a preflight alert for an agent that has not started again, **when** the board
   refreshes, **then** it continues to be governed by the existing tail-window and 47q age cutoff
   exactly as before (no regression).

## Out of scope
- Treating "factory start" as one event covering all five roles at once - resolution is
  per-agent, per the Context above.
- Any change to when or how preflight itself runs, retries on a usage limit, or the wording of
  its alert messages.
- Resolution/expiry logic for any alert family other than preflight (already covered by
  agent-factory-2do and agent-factory-47q, and left as-is).
- Rewriting, rotating, or deleting `alerts.log` - only what the board *displays* changes.
- A persistent/structured alert store replacing `alerts.log`.
