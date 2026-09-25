# agent-factory-uhc: Tmux layout - move board into ops, give team-lead its old slot

## Story
As an agent-factory operator attaching to the tmux session, I want the live status board
relocated into the `ops` window (where I do my own typing) and the `team-lead` role given the
pane slot the board used to occupy in the `agents` window, so that the `agents` window holds only
the six agent roles and I can still see the board without switching windows away from my shell.

## Context
`bin/start.sh` currently builds two tmux windows:
- `agents`: a `board` pane (running `bin/board.sh`) plus one pane per role in `ROLES=(po architect
  qa engineer reviewer)`, all tiled via `pane()` (`bin/start.sh:18-30`), with
  `pane-border-status`/`pane-border-format` showing each pane's title.
- `ops`: a single interactive shell pane (`bin/ops-shell.sh`), where the operator actually types.

A sixth role, `team-lead`, is being added by story `agent-factory-dx0` (design/implementation in
progress on `story/agent-factory-dx0` at the time of writing - not yet merged to `main`). Once it
exists, `team-lead` should run as a normal tiled pane in the `agents` window, like the other five
roles, in the slot `board` currently occupies (i.e. `board` is removed from `ROLES`'-equivalent
pane list and `team-lead` takes its place there). `board` itself moves to the `ops` window, as an
second pane there rather than disappearing - the operator watching the board today does it by
switching to the `agents` window and looking at the `board` pane; after this change that same live
view should be visible in the `ops` window, without giving up the terminal-height budget that
window otherwise gives entirely to the interactive shell.

This story only concerns pane placement/window membership in `bin/start.sh`. It does not touch
`bin/board.sh`'s content or behaviour, nor `team-lead`'s own logic (`agent-factory-dx0`'s
concern). **This story's implementation is sequenced after `agent-factory-dx0` lands on `main`**
(that story's design doc adds `agents/team-lead.md` and the `ROLE=team-lead` support this story's
pane needs to actually run) - the architect/engineer picking this up should confirm `team-lead`
support is on `main` (or rebase onto `story/agent-factory-dx0` if it's still only there) before
implementing.

## Acceptance criteria

1. **Given** a fresh `bin/start.sh` run, **when** the tmux session comes up, **then** the `agents`
   window contains exactly six panes - one per role in `po architect qa engineer reviewer
   team-lead` - and no `board` pane.
2. **Given** a fresh `bin/start.sh` run, **when** the tmux session comes up, **then** the `team-lead`
   pane occupies the tiled position `board` used to occupy in the `agents` window (i.e. swapping
   `board` for `team-lead` in the pane-creation order, first among the window's panes), and the
   other five role panes keep their existing relative order.
3. **Given** a fresh `bin/start.sh` run, **when** the tmux session comes up, **then** the `ops`
   window contains exactly two panes: the pre-existing interactive shell pane, and a `board` pane
   running the same command `bin/board.sh` was run with in the `agents` window before this change.
4. **Given** the `ops` window's two panes, **when** the tmux session comes up, **then** the `board`
   pane is positioned above the shell pane and sized to approximately one third of the window's
   total height (the shell pane keeping the remaining ~two thirds).
5. **Given** the `agents` window's `remain-on-exit`, `pane-border-status`, and `pane-border-format`
   window options (so a dead pane's last output stays visible, and each pane's title shows), **when**
   the tmux session comes up, **then** these options are also set on the `ops` window, so a dead
   `board` pane behaves and displays the same way there as every pane already does in `agents`.
6. **Given** the tmux session is already running (`bin/start.sh` called a second time), **when**
   `start.sh` runs again, **then** it still prints "Already running" and exits 0 without altering
   the existing layout, unchanged from current behaviour.
7. **Given** the startup summary `start.sh` prints after creating the session, **when** it lists
   window contents, **then** it reflects the new layout (six roles including `team-lead` in
   `agents`; `board` mentioned as part of `ops`), so the printed hint text doesn't contradict what
   the operator sees on screen.

## Out of scope
- `agents/team-lead.md`, `team-lead`'s runtime behaviour, or the `needs-team-lead` label/escalation
  mechanism - all `agent-factory-dx0` (and its dependents `agent-factory-ulq`, `agent-factory-250`).
- Any change to `bin/board.sh`'s content, data sources, or refresh behaviour.
- Resizing or otherwise changing the `agents` window's tiled layout algorithm beyond
  accommodating one more pane in `team-lead`'s place.
- Adding a way to resize the `ops` window's board/shell split after startup (a one-time ~1/3
  sizing at creation is sufficient).
