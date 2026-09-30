# agent-factory-b50b: Multi-line alerts age out of recent alerts - design

## Approach

One change, entirely inside `bin/board.sh`'s `recent_alerts`; no other file changes (`alert()`,
`alerts.log` format, the `tail -n 6` window and all alert wording are out of scope).

Today pass 2 treats every line that doesn't match `^<ts> [<agent>] <msg>$` as "print unchanged".
That is correct for a *truncated* alert (continuation lines at the very start of the window with
no header visible) but wrong for continuation lines that follow a header in the window: they
should inherit the header's show/hide decision.

Rule: **a line that doesn't match the log format is a continuation of the nearest preceding
timestamped line in the window.** It is printed iff that header line was printed. If there is no
preceding header in the window, it is printed (fail visible, AC4).

## Change to `bin/board.sh`

Pass 1 (restart-epoch map) is unchanged: it already `continue`s past non-matching lines, so
continuation text can never feed restart evidence.

Pass 2: the body of the `while` loop is currently a chain of `echo`/`continue`. Extract that
classification into a helper, `alert_line_visible LINE`, that returns 0 (show) / 1 (hide) and
does no printing. It is defined alongside `recent_alerts` and reads `restart_epoch`, `now` and
`max_age_s` from the caller's locals via bash dynamic scoping (the same way the loop body reads
them today; declare them `local` in `recent_alerts` as now). Its logic is the existing body,
verbatim, with each `echo "$line"; continue` -> `return 0`, each silent `continue` -> `return 1`,
and the needs-human branch -> `still_needs_human "$id"; return`. The non-matching-line branch is
NOT part of the helper.

The pass-2 loop becomes:

```bash
local seen_header=0 header_shown=0
while IFS= read -r line; do
  if [[ $line =~ ^[0-9T:-]+Z\ \[[^]]*\]\ .*$ ]]; then
    seen_header=1
    if alert_line_visible "$line"; then header_shown=1; echo "$line"; else header_shown=0; fi
  elif (( ! seen_header || header_shown )); then
    echo "$line"     # continuation of a shown header, or orphan before any header (fail visible)
  fi
done <<< "$lines"
```

Semantics:

- Header line -> `seen_header=1`, `header_shown` = result of `alert_line_visible`.
- Non-header line -> print iff `! seen_header` or `header_shown`.

Notes:
- A blank continuation line (auth output with an empty line) is handled identically; `read`
  yields an empty string, which doesn't match the format.
- The needs-human decision calls `still_needs_human` once per header, so its continuation lines
  follow the same decision with no extra `bd` calls (AC3). Likewise usage-limit wait-window.
- Update the `recent_alerts` header comment: replace "Lines that don't match the log format ...
  are printed unchanged" with the continuation rule above, and mention agent-factory-b50b.
- `alerts.log` is only ever read (AC6).

## Acceptance criteria mapping

1. Header dropped (age cutoff or wzg superseded) -> `header_shown=0` -> continuations hidden.
2. Header shown -> continuations printed right after it, input order preserved.
3. needs-human / usage-limit headers: decision made once by the same branches, continuations follow.
4. Non-header lines before any header in the window: `seen_header=0` -> printed.
5. Single-line alerts: no non-header lines exist, so the new branch never fires; helper body is the
   old logic verbatim -> identical output.
6. No writes to `alerts.log`.

Edge (documented, accepted): a continuation line that happens to begin with a timestamp and
`[agent]` would be treated as a new header; alerts are written by `bin/agent-loop.sh` with their
own prefix so this doesn't occur in practice.

## Test strategy

New `tests/agent-factory-b50b_test.sh`, same harness as `tests/agent-factory-47q_test.sh`
(source `bin/board.sh` with scratch `DATA_DIR`, stub `bd` on `PATH`, call `recent_alerts`;
`loop.log` fixtures for the wzg case). Cases, one per AC:
- AC1: old multi-line alert (2-3 continuation lines) + fresh single-line alert -> only the fresh
  one shown; and a superseded `claude`/`harness failed to run` multi-line alert (later `started:`
  line) -> header and continuations all hidden.
- AC2: fresh multi-line alert -> header and continuations shown in order (compare exact output).
- AC3: multi-line needs-human header (stub `bd` says label still present -> shown with
  continuations; label gone -> all hidden); usage-limit header inside its wait window -> shown
  with continuations, elapsed -> hidden with continuations.
- AC4: window starts with orphan continuation lines (e.g. 7+ physical lines so the header is
  cut off by `tail -n 6`) -> orphans shown, later alerts still judged normally; an orphan block
  followed by an *old* header must not be hidden by that header (orphans precede it).
- AC5: re-run a few single-line cases (old hidden, fresh shown); the existing 47q and wzg test
  scripts must still pass unchanged.
- AC6: `cksum`/content of `alerts.log` identical before and after.
- Blank continuation line between two continuations follows its header.
- `shellcheck bin/board.sh` stays clean if already run by existing tests.
