# Design: agent-factory-59gv - lint tests for hard-coded dates

## Approach
One new bash script, `bin/check-tests.sh`, a grep-based scan. No new dependencies. Plus fixing the
existing offenders and a doc update.

## `bin/check-tests.sh [dir]`
- `set -uo pipefail` (must not abort on grep's exit 1). Does not need `lib.sh`.
- `dir="${1:-tests}"`, relative to the caller's cwd (repo root by convention). If `dir` is not a
  directory: print `check-tests: not a directory: <dir>` to stderr, exit 2.
- Collect files: `find "$dir" -type f -name '*.sh' | sort` (recursive; covers `tests/*.sh` and
  `tests/acceptance/*.sh`; no exec-bit requirement).
- Per file: `grep -nE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$f"` (this already matches the date prefix of
  `YYYY-MM-DDTHH:MM:SS`, so the time suffix needs no separate handling; it also matches placeholders
  like `9999-99-99`, deliberately - they are date-shaped fixtures and must be marked).
  Drop lines matching `# fixed-date-ok[[:space:]]*$` (marker must be the end of the line). Print each
  remaining hit as `<file>:<line>: <text>` on stdout (path as found under `dir`, e.g.
  `tests/foo_test.sh:12:`). Use a single pass over all files (`while read` / awk), never exit early:
  every offender is reported in one run (AC4).
- Track a count; after scanning print a summary line `check-tests: N hard-coded date(s) in M file(s)`
  to stderr when N>0 and exit 1; when N=0 print `check-tests: ok` and exit 0. The OK line must not
  contain the word "violation" or a `path:line` (AC3 says nothing reported as a violation).
- Reported line text is for human context only; tests should assert on the `path:line` prefix.
- Empty dir / no `.sh` files: exit 0.
- Scope is whole-line: a date inside a comment, string or heredoc is still flagged (mechanical,
  no shell parsing). The marker is the escape hatch.

## Marker semantics
`# fixed-date-ok` at end of line (trailing whitespace allowed). Constraint to document: a marker
cannot follow a line-continuation backslash or sit inside a heredoc body/multi-line string. In such
cases, move the literal onto its own marked line, e.g. `TS="2026-09-28T00:00:00Z" # fixed-date-ok`,
and reference `$TS`.

## Fixing existing offenders (AC5)
Current hits (`grep -rnE '[0-9]{4}-[0-9]{2}-[0-9]{2}' tests`): 7yn3_engineer (48, 75), 7yn3 (89),
whtf (94, 116, 129, 136), 2do (97, 113, 130, 148, 237), 47q (138), q4tj (168, 172, 180, 190, 192,
233, 239), acceptance/0is (21 - a comment). Policy, per hit:
- Far-past/far-future sentinels (`2000-01-01`, `2020-01-01`, `2999-01-01`, `9999-99-99`) and fixed
  log/assessed_at timestamps that are genuinely the fixture whose parsing is under test: append
  `# fixed-date-ok`. Appending a bash comment after a complete command is safe; for a line inside a
  single-quoted jq/JSON multi-line argument or ending in `\`, hoist the literal into a marked
  variable (see above) instead.
- A timestamp whose value only has to be "recent" or relative to now (check each test's intent, e.g.
  q4tj/whtf `assessed_at` if freshness is what is being asserted): compute with
  `date -u +%Y-%m-%dT%H:%M:%SZ` / `date -u -d '5 minutes ago' ...`. If the test asserts a stale
  vs fresh result the computed form is required; if a fixed value is just echoed back, marking is fine.
- `acceptance/0is.sh:21`: reword the comment to drop the date (e.g. "captured at story start") or mark it.
Do not otherwise change test logic. Then run every script under `tests/` and confirm they still pass
(AC5); a test that fails for a pre-existing, unrelated reason is out of scope - note it.

## Docs (AC7)
`docs/ARCHITECTURE.md` "Test strategy": in the **Regression suite** bullet(s) (there are currently
two near-duplicate bullets; merge them into one while there), add that QA's verify stage first runs
`bin/check-tests.sh` (must exit 0) and that hard-coded `YYYY-MM-DD` literals in test scripts are
flagged unless the line ends in `# fixed-date-ok`, with the backslash/heredoc caveat above. Add
`check-tests.sh` to the Layout `bin/` list only if convenient; optional. Also add one line to
`agents/qa.md` verify stage and write-tests stage ("run `bin/check-tests.sh`") if it lists verify
steps - small, in scope as it is the documented process; do not wire it into the loop or hooks.

## Test strategy (QA: `tests/agent-factory-59gv_test.sh`)
Build scratch dirs under `mktemp -d` (no reliance on real tests/) and run `bin/check-tests.sh <dir>`:
- AC1: file with `2026-09-23` and with `2026-09-23T09:00:00Z`, unmarked -> exit non-zero, output has `file:LINE`.
- AC2: same lines ending `# fixed-date-ok` (and with trailing spaces) -> exit 0, not reported; a
  marker in the middle of the line (not at end) is still reported.
- AC3: clean tree -> exit 0, output contains no `path:line`.
- AC4: 2+ files (incl. nested subdir, a non-`.sh` file with a date that must be ignored) with
  several offenders -> every `path:line` present, exit non-zero.
- AC6: relative and absolute dir argument; default (no arg) scans `./tests` (run from a scratch cwd
  containing a `tests/` with one offender). Non-directory arg -> exit 2.
- AC5: `bin/check-tests.sh` from repo root exits 0; verify stage also runs all existing scripts.
- AC7: `grep` ARCHITECTURE.md for `check-tests.sh` and `fixed-date-ok`.
