# Design: agent-factory-whtf - throttle verbosity on board

## Context
`agent-factory-q4tj` added `throttle_section()` to `bin/board.sh` and an unconditional call to it
in `render()`, printing a `-- throttle (po/architect) --` header plus exactly one line on every
render, in every case (no file yet, `idle:false`, `idle:true`, or an unreadable/malformed file -
see that function's body, unchanged by this story). Since po/architect are only actually held back
in the `idle:true` case - the minority of the time - this section is visual noise the rest of the
time. This story narrows what `render()` prints; it does not touch `throttle_section()`,
`throttle.json`'s schema, `bin/set-throttle.sh`, or `throttle_ok()` (all out of scope per the
story).

## Approach

### `bin/board.sh` - gate the existing call in `render()`, `throttle_section()` untouched

`throttle_section()` stays exactly as it is today:
```bash
throttle_section() {
  local f="$DATA_DIR/control/throttle.json"
  [ -f "$f" ] || { echo "(no assessment yet - po/architect proceed unthrottled)"; return; }
  jq -r '(if .idle then "IDLE" else "GO" end) as $s | "\($s)  (assessed \(.assessed_at // "?"))  \(.reason // "no reason recorded")"' "$f" 2>/dev/null \
    || echo "(unreadable: $f)"
}
```
Deliberately unmodified: `tests/agent-factory-q4tj_test.sh`'s `run_throttle_section()` sources
`bin/board.sh` and calls `throttle_section()` directly, asserting it still prints `GO`/`IDLE`/"no
assessment yet" text for those three fixtures - that test must keep passing unmodified, since
nothing about what `throttle_section()` itself returns has changed. Only what `render()` does with
that return value changes.

`throttle_section()`'s four possible outputs, and what this story does with each:

| Case | Output today (unchanged) | render() this story |
|---|---|---|
| no `throttle.json` | `(no assessment yet - po/architect proceed unthrottled)` | hidden (AC1) |
| `idle:false` | `GO  (assessed <ts>)  <reason>` | hidden (AC2) |
| `idle:true` | `IDLE  (assessed <ts>)  <reason>` | shown, with header (AC3) |
| unreadable/malformed | `(unreadable: <path>)` | shown, with header (AC4) |

`render()` currently (in full, for reference - only the `throttle_out`/`if` block below is new):
```bash
render() {
  clear
  echo "== $(date -u +%FT%TZ) =="
  echo; echo "-- throttle (po/architect) --"
  throttle_section
  echo; echo "-- in progress --"
  ...
```
Replace those two throttle lines with:
```bash
  local throttle_out
  throttle_out=$(throttle_section)
  if [[ "$throttle_out" == "GO  ("* || "$throttle_out" == "(no assessment yet"* ]]; then
    :  # nothing held back, or no judgment recorded yet - AC1/AC2: stay quiet
  else
    echo; echo "-- throttle (po/architect) --"
    echo "$throttle_out"  # IDLE, or the file exists but is unreadable/malformed - AC3/AC4: surface it
  fi
```
(`local` split from the assignment, not combined on one line, so a failure inside the command
substitution can't be masked - matches this file's existing style elsewhere, e.g.
`recent_alerts()`'s locals.)

**Why match on the two "hide" prefixes rather than the two "show" ones:** `throttle_section()`'s
two silent-by-design outputs (`(no assessment yet...`, `GO  (...`) are fixed, hardcoded strings
with no variable content before the first space that could collide with a real reason - `GO`/`IDLE`
only ever come from the `if .idle then "IDLE" else "GO" end` literal, never from data. Everything
else - `IDLE  (...` and the catch-all `(unreadable: ...)` - falls through to the `else` branch and
gets shown. That catch-all is what satisfies AC4 without a third, separate case to maintain: *any*
output that isn't recognized as one of the two known-quiet cases is treated as "something to show,"
so a future third failure mode in `throttle_section()` (should one ever get added) fails toward
visible-by-default rather than silently joining the hidden set.

**Why not change `throttle_section()` to return empty itself for the quiet cases:** that would
change its contract (today it always writes something to stdout) and break
`run_throttle_section()`'s three fixture assertions in `tests/agent-factory-q4tj_test.sh`, which
this story has no reason to touch - the story's own Context note says explicitly this only changes
what `board.sh` *displays*. Gating in `render()` instead keeps `throttle_section()`'s existing,
already-tested contract intact and confines the entire change to one `render()` call site.

No other section of `render()` changes - `blocked_section`, `ready_section`,
`needs_human_section`, `recent_alerts` and their headers all print unconditionally, exactly as
before (explicitly out of scope per the story).

## Error cases
- **Malformed/unreadable `throttle.json`** (AC4): `throttle_section()`'s own `|| echo
  "(unreadable: $f)"` is unchanged, and that string doesn't match either quiet-case prefix, so it
  falls to the `else` branch and prints with the header - the failure is never silently folded into
  the "nothing to show" cases. This is the one case this story must not regress, since AC4 exists
  specifically to keep that q4tj guarantee alive under the new gating.
- **`throttle.json` missing `idle`/`reason` keys but otherwise valid JSON**: unchanged pre-existing
  behavior from q4tj - `jq` treats a missing `.idle` as falsy, so `throttle_section()` prints a
  `GO` line (not an error), which this story hides same as any other `GO`. Out of scope to change
  (not a new failure mode introduced here).
- **`DATA_DIR`/`control/` unreadable at the directory level** (permissions, not just the file):
  `[ -f "$f" ]` in `throttle_section()` returns false the same as a missing file, so this falls
  into the AC1 "no assessment yet" quiet case, same as today's behavior for a missing file -
  unchanged, not a regression this story introduces.

## Acceptance criteria mapping
1 -> `throttle_out == "(no assessment yet"*` quiet branch. 2 -> `throttle_out == "GO  ("*` quiet
branch. 3 -> `else` branch (falls through, `IDLE` line shown with header, same text format as
today). 4 -> `else` branch (falls through, `(unreadable: ...)` shown with header) +
`throttle_section()` left completely unmodified so q4tj's existing malformed-input guarantee
carries forward unchanged.

## Test strategy (QA)
New `tests/agent-factory-whtf_test.sh`, acceptance-style (no unit-test framework - see
`docs/ARCHITECTURE.md`), one function per AC. Source `bin/board.sh` against a scratch `DATA_DIR`
and call `render()` itself (not just `throttle_section()`) so the assertions cover the actual gating
logic, not just the unchanged helper - `render()` also calls `bd`/`tail` for its other sections, so
stub or scratch those the same way existing tests in this repo stub `bd` (see
`tests/agent-factory-q4tj_test.sh`'s harness style, or any `bin/agent-loop.sh` test's stub-`bd`
pattern) so `render()` runs without a real Beads DB. `render()` also calls `clear`; run it in a
harness that either stubs `clear` to a no-op or simply doesn't care about it corrupting captured
output (it writes a terminal control sequence, not stdout text QA is asserting against - confirm
this doesn't land inside the captured string on the test runner's terminal, e.g. by piping through
`cat` or redirecting `TERM=dumb`).

- **AC1**: scratch `DATA_DIR` with no `control/throttle.json` at all. Assert `render()`'s output
  does not contain `-- throttle (po/architect) --` anywhere.
- **AC2**: write `{"idle":false,"reason":"plenty of room","assessed_at":"..."}`. Assert `render()`'s
  output does not contain `-- throttle (po/architect) --` and does not contain `plenty of room`.
- **AC3**: write `{"idle":true,"reason":"backlog too deep at stage:implement","assessed_at":"..."}`.
  Assert `render()`'s output contains `-- throttle (po/architect) --` followed by a line containing
  both `IDLE` and `backlog too deep at stage:implement`.
- **AC4**: write an invalid-JSON `control/throttle.json` (e.g. `not json`). Assert `render()`'s
  output contains `-- throttle (po/architect) --` and an `(unreadable:` line - i.e. the malformed
  case is never swallowed into AC1/AC2's silence.
- **Regression**: run `tests/agent-factory-q4tj_test.sh` unmodified and confirm `failed=0` -
  `run_throttle_section()`'s three assertions against `throttle_section()` directly must still
  pass, since that function is untouched.
- `shellcheck bin/board.sh` on the diff.
