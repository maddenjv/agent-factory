# agent-factory-lv8s: Stale multi-line alert tail on the board - design

## Root cause

`recent_alerts` (bin/board.sh) windows `alerts.log` by *physical* lines (`tail -n 6`). When the
window starts inside a multi-line alert, the headerless leading lines are "orphans"; the b50b rule
prints orphans ("fail visible"), so an old alert's tail stays on the board forever.

## Approach

Window by *logical alert* instead of physical line. An alert = a header line
(`^[0-9T:-]+Z \[[^]]*\] `) plus the non-header lines that follow it. Change is confined to the
`lines=$(tail -n 6 ...)` assignment in `recent_alerts` plus the pass-2 loop; `alert()`, the log
format, the age default and all alert wording are untouched. `alerts.log` is only read.

### 1. Window selection (replaces `lines=$(tail -n 6 ...)`)

Add helper `alert_window FILE` in bin/board.sh, printing to stdout the last 6 alerts in full:

- Read `tail -n 200 FILE` (`ALERT_SCAN_LINES`, constant, bounds the work on a huge log).
- Discard every line before the first header line in that tail (orphans: their header is out of
  reach and they cannot be attributed to a current alert - AC1).
- Of the remaining lines keep everything from the header of the 6th-from-last alert (or from the
  first header if there are fewer than 6 alerts) to the end.

Suggested awk (any equivalent is fine):

```bash
alert_window() {
  tail -n 200 "$1" 2>/dev/null | awk -v keep=6 '
    /^[0-9T:-]+Z \[[^]]*\] / { n++; hdr[n] = NR }
    n > 0 { line[NR] = $0 }
    END { if (!n) exit; s = hdr[n > keep ? n - keep + 1 : 1]; for (i = s; i <= NR; i++) print line[i] }'
}
```

(`recent_alerts`: `lines=$(alert_window "$DATA_DIR/control/alerts.log")`.) Note the awk header regex
must be the same as the one used by pass 2; define it once if practical.

Consequences:
- AC5: the most recent alert is always in the window with its header, however many lines it has
  (up to the 200-line scan bound; a single alert longer than 200 lines loses its header and is
  then dropped as an orphan - accepted, far beyond any real harness error).
- AC2: a young multi-line alert whose header was beyond 6 physical lines is now fully shown,
  header first.
- 47q AC7 still holds: for all-single-line logs, "6 alerts" == "6 lines", same output.
- The window can now be taller than 6 physical lines (up to 6 alerts' worth). Accepted; the age
  cutoff normally leaves only recent ones. No truncation of continuation text (wording is out
  of scope).

### 2. Pass 1 (restart-epoch map)

Unchanged; reads the new `$lines`. Already ignores non-header lines.

### 3. Pass 2

The orphan case can no longer occur (window always begins with a header), so `seen_header`
disappears:

```bash
local header_shown=0
while IFS= read -r line; do
  if [[ $line =~ ^[0-9T:-]+Z\ \[[^]]*\]\ .*$ ]]; then
    if alert_line_visible "$line"; then header_shown=1; echo "$line"; else header_shown=0; fi
  elif (( header_shown )); then
    echo "$line"      # continuation of a shown header (AC3/AC4)
  fi
done <<< "$lines"
```

`alert_line_visible` is unchanged. Update the `recent_alerts` header comment: replace "reads the
last 6 lines" with "reads the last 6 alerts (header + continuation lines; see alert_window)" and
replace the "no preceding timestamped line ... printed (fail visible)" sentence with: continuation
lines whose header is outside the scanned tail are dropped, never shown headerless
(agent-factory-lv8s, supersedes the b50b fail-visible rule).

## Supersedes (tests must change)

The b50b "orphan lines are shown" behaviour is intentionally reversed:
- `tests/agent-factory-b50b_test.sh` `test_ac4_truncated_alert_continuations_shown` (and its
  call at the bottom) asserts orphans are shown; QA must rewrite it to the lv8s AC1/AC2 behaviour
  (orphans hidden when the alert is old; header+continuations shown when young), not just delete it.
- All other b50b, 47q, wzg tests should pass unchanged; QA to confirm.

## AC mapping

1. Old alert whose header precedes the physical 6-line cut: the window now starts at a header,
   old header -> hidden by age (`alert_line_visible`) -> continuations hidden. No orphan ever printed.
2. Young such alert: its header is in the window (logical windowing) -> shown with continuations.
3. Header in window, aged/superseded -> `header_shown=0` -> continuations hidden (unchanged).
4. Header current -> header + continuations shown (unchanged).
5. Latest alert always fully in window (see above).

## Test strategy

New `tests/agent-factory-lv8s_test.sh`, same harness as 47q/b50b (source bin/board.sh, scratch
`DATA_DIR`, stub `bd`, call `recent_alerts`). Cases:
- AC1: old 5-line alert (header + 4 continuations, header at physical position >6 from end) then
  2 fresh single-line alerts -> only the fresh ones appear; none of the old continuation text.
- AC2: same shape but the multi-line alert is fresh -> header and all continuations shown, in order,
  before the later alerts.
- AC3/AC4: header-in-window old (hidden with continuations) vs fresh (shown with continuations);
  also needs-human and usage-limit multi-line headers.
- AC5: a single 12-line fresh alert as the last entry -> all 12 lines shown with the header.
- Log starts mid-alert (first lines headerless) with fewer than 6 alerts -> leading orphans never shown.
- More than 6 alerts -> only the last 6 alerts considered (older ones not back-filled).
- `alerts.log` unmodified (cksum before/after).
- Regression: 47q, wzg, b50b (after the QA rewrite above) all pass.
