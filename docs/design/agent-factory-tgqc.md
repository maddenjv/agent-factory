# agent-factory-tgqc: One-line alerts, and a cause on "not completed" alerts - design

All changes are in `bin/agent-loop.sh`. No new files besides tests; no change to `alerts.log`
format, board.sh, attempt-cap logic, or the notes appended to the issue.

## 1. Single-line alerts (AC1-4)

Add a pure helper next to `log()`/`alert()`:

```bash
one_line() {  # one_line TEXT... -> TEXT as one line: every CRLF/LF/CR run (with any blank lines
              # between) becomes a single space; no leading/trailing or repeated-from-breaks spaces
  printf '%s' "$*" | tr '\r\n' '\n\n' | awk 'NF{ sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); out = out (out==""?"":" ") $0 } END{print out}'
}
```

(Engineer may use any equivalent; contract below matters, not the pipeline.) Contract: split on
LF/CRLF/lone CR, drop lines that are empty or whitespace-only, trim each remaining line's
leading/trailing whitespace, join with one space. Text with no line breaks is returned
**byte-identical** (AC3) - so only trim per-line when the input actually contained a break;
simplest is: `case $msg in *$'\n'*|*$'\r'*) collapse;; *) keep;; esac`. Empty message -> empty
string. Use bash/tr/sed only (no new dependency); output has no trailing newline.

`alert()` becomes:

```bash
alert() {
  local msg; msg=$(one_line "$*")
  printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$AGENT_ID" "$msg" >> "$CONTROL/alerts.log"
  log "ALERT: $msg"
  [ -n "${NOTIFY_URL:-}" ] && curl ... -d "[$AGENT_ID] $msg" ...   # keep existing || true form
}
```

`$(...)` strips trailing newlines already; `log` receives the collapsed text, so `loop.log` and
the notification match `alerts.log` (AC4). `log()` itself is unchanged (not in scope).

## 2. Cause of the last failed session (AC5-8)

`run_harness_session` currently discards the harness exit status and error text. Add two globals,
reset at the top of the function (like `LAST_RUN_QUOTA_MSG`):

- `LAST_RUN_RC` - the harness (`timeout ... claude|copilot`) exit status. Capture immediately
  after the pipeline with `LAST_RUN_RC=${PIPESTATUS[0]}` in both branches (the subshell is the
  first pipeline element; `tee`/`jq` come after). 124 = `ITERATION_TIMEOUT` hit.
- `LAST_RUN_ERR` - bounded single-line excerpt (<=200 chars) of the harness's error message,
  computed before `$errfile`/`$outfile` are removed, first non-empty of:
  1. stderr (`$errfile`) - `one_line "$(head -c 2000 "$errfile")" | cut -c1-200`
  2. Claude only: the final `result` event of `$outfile` when `is_error == true` - its `.result`
     text (same jq selection style as `quota_hit_from_stream`), passed through `one_line`, cut to 200.
  3. empty.
  Add a small function `harness_error_excerpt ERRFILE OUTFILE` holding this so it is unit-testable.

`record_failure` builds the cause only in the cap-reached branch (AC8: below the cap no alert,
log line unchanged):

```bash
cause=$(failure_cause)   # helper reading LAST_RUN_RC / LAST_RUN_ERR
alert "$id not completed after $n attempts; labelled $esc_label ($cause)"
```

`failure_cause`:
- rc != 0: `harness exit status $rc` (+ ` (timeout)` when 124), else
  `session ended without closing or explaining` (rc 0).
- when `LAST_RUN_ERR` is non-empty append `: $LAST_RUN_ERR`.
- e.g. `agent-factory-x not completed after 3 attempts; labelled needs-team-lead (harness exit status 1: Error: ...)`

The alert still starts with `<id> not completed after <N> attempts; labelled <label>` (AC7); the
cause is a suffix in parentheses. The whole line passes through `alert()` so any newline in the
excerpt is collapsed (AC6); the 200-char cut is applied to the excerpt, before embedding. If
`LAST_RUN_RC` is unset (record_failure called outside a run) treat as 0.

Do NOT change the `bd update --append-notes` text (out of scope), the attempt counter, or
`handle_outcome`.

## Error cases
- Empty/absent stderr and stream: cause is just the exit-status / "ended without closing" phrase.
- `jq` failure on malformed stream: ignore (`2>/dev/null`), excerpt empty.
- Message containing `%` or backslashes: always use `printf '%s'`, never as a format.

## Acceptance mapping
AC1-3: `one_line` + `alert()`. AC4: `log "ALERT: $msg"` and curl use collapsed `$msg`.
AC5-6: `LAST_RUN_RC`/`LAST_RUN_ERR` + `failure_cause`. AC7: suffix-only. AC8: cause built only inside the cap branch.

## Test strategy (QA)
Follow the existing pattern in `tests/` (source functions from `bin/agent-loop.sh` or run it with
stubbed `bd`/harness, as other `*_test.sh` do).
- `one_line`/`alert()` unit level with a temp `CONTROL`/`LOGDIR`: LF, CRLF, lone CR, leading/trailing/
  consecutive blank lines, plain message identical to the old format; `alerts.log` line count +1;
  `loop.log` and a stub `curl` (PATH shim capturing `-d`) get the same single-line text.
- `record_failure` with stubbed `bd`, `MAX_ATTEMPTS_PER_ISSUE=1`: set `LAST_RUN_RC=1`/`0`/`124` and
  `LAST_RUN_ERR` (incl. multi-line and >200-char) -> assert one alert line, prefix intact, cause text,
  excerpt bounded. Below cap: no alerts.log entry.
- `harness_error_excerpt` with fixture stderr and stream-json result files.
- One integration-style run of `run_harness_session` with a stub `claude` on PATH that prints an
  error to stderr and exits 3, asserting `LAST_RUN_RC=3` and a non-empty `LAST_RUN_ERR`.
