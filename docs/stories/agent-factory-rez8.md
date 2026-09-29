# agent-factory-rez8: Shutdown vs. startup

## Story
As an agent-factory operator, I want `bin/stop.sh` to actually bring the whole factory down once
the agents have exited, and `bin/start.sh` to reliably start a fresh session afterward, so that
stopping and restarting agent-factory doesn't require me to manually kill a stale tmux session or
clear leftover STOP files by hand.

## Context
`bin/stop.sh` has three modes: `graceful` (touch `$DATA_DIR/control/STOP`, let agents exit on
their own after their current session), `now` (immediately `docker stop` a fixed list of
containers and `tmux kill-session`), and `clear` (remove the STOP file(s), no other side effects).

Only `bin/agent-loop.sh` (`stopping()`, agent-loop.sh:62, checked at agent-loop.sh:373) ever looks
at the STOP file - that's the five build roles plus `team-lead`. `bin/board.sh` and
`bin/ops-shell.sh`, the two containers occupying the `ops` window (per `bin/start.sh`), never
check it and just keep running. So a `graceful` stop only ever stops the role/team-lead
containers; `board` and `ops` - and therefore the tmux session they're panes of - are never torn
down by anything, no matter how long the operator waits.

`bin/start.sh` opens with:
```
if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Already running: tmux attach -t $SESSION"; exit 0
fi
rm -f "$DATA_DIR/control/STOP" "$DATA_DIR"/control/STOP.*
```
Because the session housing `board`/`ops` is still alive after a `graceful` stop, this check
always fires, `start.sh` exits immediately, and the STOP-flag cleanup on the next line never runs.
The operator is left with a tmux session that looks present but whose role panes have all exited,
a STOP flag still in effect, and no way to get back in through `start.sh` - they have to know to
manually `tmux kill-session` and/or run `stop.sh clear` first, none of which is documented in
`stop.sh`'s own usage comment.

Separately, `now`'s container list (`stop.sh`'s `now` branch) is `po architect qa engineer
reviewer ops board` - it omits `team-lead`, a role that's been running as its own pane/container
(`bin/start.sh:32`) since agent-factory-dx0 landed. `now` already claims to stop "agent
containers"; leaving one running is a bug in the same code path this story is fixing, not a
separate concern.

## Acceptance criteria

1. **Given** the factory is running, **when** the operator runs `bin/stop.sh graceful` and every
   role agent - `po`, `architect`, `qa`, `engineer`, `reviewer`, `team-lead` - has finished its
   current session and exited, **then** the `ops` and `board` containers are also stopped and the
   tmux session no longer exists, with no further manual commands required beyond the original
   `stop.sh graceful` invocation.
2. **Given** `bin/stop.sh graceful` has completed as in AC1, **when** the operator runs `bin/start.sh`,
   **then** it starts a new tmux session in which every role's pane is actually running its agent
   loop (not exiting immediately) - i.e. no STOP flag left over from the previous stop is still in
   effect.
3. **Given** the factory is genuinely still running (tmux session alive, at least one role agent
   still active, no STOP flag in effect), **when** the operator runs `bin/start.sh`, **then** it
   still prints "Already running: tmux attach -t \<session\>" and exits 0 without altering
   anything - unchanged from current behaviour.
4. **Given** the factory is running, **when** the operator runs `bin/stop.sh now`, **then** all
   six role containers (`po`, `architect`, `qa`, `engineer`, `reviewer`, `team-lead`) plus `ops`
   and `board` are stopped and the tmux session is killed, immediately, regardless of whether any
   agent is mid-session - closing the current gap where `team-lead` is left running.
5. **Given** `bin/stop.sh now` has completed as in AC4, **when** the operator runs `bin/start.sh`,
   **then** it starts a new session the same way as in AC2 (no leftover STOP flag blocks it).
6. **Given** any state of the factory, **when** the operator runs `bin/stop.sh clear`, **then** it
   continues to only remove STOP flag files and has no effect on running containers or the tmux
   session - unchanged from current behaviour.

## Out of scope
- Shortening, bypassing, or otherwise changing what "graceful" means for an in-flight role agent
  (i.e. it still finishes its current Claude Code session before exiting) - this story only
  concerns what happens once that has already occurred.
- Any change to `bin/board.sh`'s or `bin/ops-shell.sh`'s own content, output, or behaviour while
  they're running - they are only stopped as containers, not modified.
- A progress indicator or notification telling the operator when a `graceful` stop has finished
  tearing everything down - AC1 only specifies the end state, not how the operator observes it.
- Changing `bin/stop.sh`'s or `bin/start.sh`'s command-line interface (flags, arguments) beyond
  what's needed for the behaviour above.
