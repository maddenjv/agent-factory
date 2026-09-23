# agent-factory-57g: Remove "spend today" from the board — design

## Approach

Delete the "spend today" block from `render()` in `bin/board.sh` (lines 57-58 today). Nothing
else in the file changes: `recent_alerts`, `still_needs_human`, the main loop, and every other
section are untouched, and `control/cost/*` on disk is untouched (per story Out of scope —
`DAILY_BUDGET_USD` enforcement in `bin/agent-loop.sh` doesn't read from `render()` and isn't
touched either).

Today:

```bash
render() {
  clear
  echo "== $(date -u +%FT%TZ) =="
  echo; echo "-- in progress --"
  bd list --json 2>/dev/null | jq -r '.[]? | select(.status=="in_progress") | "\(.id)  [\(.assignee // "-")]  \(.title)"'
  echo; echo "-- ready --"
  bd ready --limit 50 --json 2>/dev/null | jq -r '.[]? | "\(.id)  \((.labels // []) | join(","))  \(.title)"'
  echo; echo "-- needs-human (see \`bd show <id>\` for what's needed) --"
  bd list --json 2>/dev/null | jq -r '.[]? | select(.status!="closed" and ((.labels // []) | index("needs-human"))) | "\(.id)  \(.title)"'
  echo; echo "-- spend today (USD) --"
  cat "$DATA_DIR"/control/cost/*."$(date +%F)" 2>/dev/null | awk '{s+=$1} END{printf "%.2f\n", s+0}'
  echo; echo "-- recent alerts --"
  recent_alerts
}
```

After (the two "spend today" lines removed, nothing else changed — the "needs-human" block's
trailing `echo` now falls straight into "recent alerts", closing the gap per AC2):

```bash
render() {
  clear
  echo "== $(date -u +%FT%TZ) =="
  echo; echo "-- in progress --"
  bd list --json 2>/dev/null | jq -r '.[]? | select(.status=="in_progress") | "\(.id)  [\(.assignee // "-")]  \(.title)"'
  echo; echo "-- ready --"
  bd ready --limit 50 --json 2>/dev/null | jq -r '.[]? | "\(.id)  \((.labels // []) | join(","))  \(.title)"'
  echo; echo "-- needs-human (see \`bd show <id>\` for what's needed) --"
  bd list --json 2>/dev/null | jq -r '.[]? | select(.status!="closed" and ((.labels // []) | index("needs-human"))) | "\(.id)  \(.title)"'
  echo; echo "-- recent alerts --"
  recent_alerts
}
```

## Files to change

- `bin/board.sh` — remove the two lines that print the "-- spend today (USD) --" header and the
  `cat ... | awk ...` total (current lines 57-58, plus the blank-line `echo` immediately
  preceding them, since that blank/header pair is the section being removed — the "recent
  alerts" section keeps its own leading `echo; echo "-- recent alerts --"` unchanged, so no gap
  is left and no extra blank line is introduced).

No other file references this section: `grep -rn "spend today\|control/cost" bin/ docs/` (run
during implementation) should show only `board.sh`'s render function and — separately —
`agent-loop.sh`'s unrelated writer/enforcer of `control/cost/*`, which this story does not touch.

## Acceptance criteria mapping

1. The header string `"-- spend today (USD) --"` and the `cat "$DATA_DIR"/control/cost/*.$(date
   +%F) | awk ...` line are deleted outright — `render()`'s output no longer contains either.
2. "in progress", "ready", "needs-human", "recent alerts" keep their existing `echo; echo
   "-- ... --"` header lines verbatim and their existing relative order; only the "spend today"
   header+body between "needs-human" and "recent alerts" is removed, so "recent alerts" now
   immediately follows "needs-human"'s output with the same single blank-line separator every
   other section already uses (no leftover blank section, no double blank line).

## Test strategy

No unit-test framework per `docs/ARCHITECTURE.md`; QA exercises `bin/board.sh` directly, same
approach as agent-factory-2do (functions are guarded behind `BASH_SOURCE == 0`, so sourcing the
script doesn't start the infinite loop):

```bash
DATA_DIR=/tmp/board-test-$$
mkdir -p "$DATA_DIR/control"
source bin/board.sh
render
```

Suggested cases:
- Populate `$DATA_DIR/control/cost/` with a dated cost file containing a nonzero value, run
  `render` (or the whole script once) — output contains no "spend today" text and no dollar
  total anywhere.
- Inspect `render`'s output line-by-line — "needs-human" section's last line is immediately
  followed by the blank line + "-- recent alerts --" header (same spacing pattern as the other
  section boundaries), confirming no leftover blank section.
- `shellcheck bin/board.sh` clean, per repo convention.

## Out of scope (per story)
No change to `control/cost/` file writing, `DAILY_BUDGET_USD`, or the daily budget cap in
`bin/agent-loop.sh`. No spend/cost info added anywhere else.
