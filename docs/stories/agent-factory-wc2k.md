# agent-factory-wc2k: Focus the ops shell pane on startup

## Story
As an agent-factory operator, I want the shell pane in the `ops` window to have keyboard focus
when I first `tmux attach`, so that I can start typing commands immediately instead of first
having to move focus off the board pane.

## Context
`bin/start.sh` builds the `ops` window as a shell pane plus a board pane (`bin/board.sh`)
split above it, then selects the `ops` window so attaching lands there. Splitting makes the new
board pane the active one, so a fresh attach puts focus on the read-only board rather than the
shell. The window selection is already correct; only the active pane within it is wrong.

## Acceptance criteria

1. **Given** a freshly started factory (`bin/start.sh`), **when** a user attaches to the tmux
   session for the first time, **then** the active window is `ops` and its active pane is the
   shell pane (titled `shell`), not the board pane.
2. **Given** the same fresh start, **when** the `ops` window's panes are listed, **then** both
   the shell and board panes still exist, with the board above the shell and the existing pane
   titles, sizes and options unchanged.
3. **Given** a fresh start, **when** the `agents` window is inspected, **then** its panes,
   titles and layout are unchanged.
4. **Given** the factory is already running, **when** `bin/start.sh` is run again, **then** it
   still reports it is already running and does not alter which pane or window is active.

## Out of scope
- Which window is selected on attach (already `ops`).
- Focus behaviour after respawning panes or on later attaches, which follows normal tmux behaviour.
- Any change to the board's content or the layout of either window.
