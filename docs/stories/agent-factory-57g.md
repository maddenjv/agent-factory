# agent-factory-57g: Remove "spend today" from the board

## Story
As an agent-factory operator watching the tmux board, I want the "spend today (USD)" section
removed from the board display, so that the board only shows sections that are still useful to me.

## Context
`bin/board.sh`'s `render()` function prints a "-- spend today (USD) --" section
(bin/board.sh:57-58) that sums the numeric contents of `$DATA_DIR/control/cost/*.<today's date>`
files and prints the total. This is a display-only concern local to `render()`; no other script
reads or depends on that output (the underlying `control/cost/` files and whatever writes them
are untouched by this story - `DAILY_BUDGET_USD`, the daily budget cap enforced elsewhere in
`bin/agent-loop.sh`, is a separate mechanism and stays as-is).

## Acceptance criteria

1. **Given** the board is rendered, **when** `render()` runs, **then** the output contains no
   "spend today" section header and no dollar-total line derived from `control/cost/`.
2. **Given** the board is rendered, **when** `render()` runs, **then** the "in progress", "ready",
   "needs-human", and "recent alerts" sections still appear, in the same order and format as
   before, immediately following one another with the "spend today" gap closed (no leftover blank
   section).

## Out of scope
- Any change to how spend/cost data is collected, written to `control/cost/`, or enforced
  (`DAILY_BUDGET_USD` and the daily budget cap in `bin/agent-loop.sh` are untouched).
- Adding spend/cost information anywhere else (e.g. a different board section, a log file, a
  separate command).
