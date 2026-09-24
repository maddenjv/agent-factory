# Design: agent-factory-kvy - approval sentence on its own line

## Approach
One-line change in `bin/approve.sh`: in the `-m` branch, build the note as a single multi-line string
so the fixed approval sentence sits on its own line directly after the answer. Still ONE
`bd update --append-notes` call (keeps ordering unambiguous, as in f6g).

```bash
if [ "$have_msg" -eq 1 ]; then
  note="Human answer via approve.sh by $(whoami) at $(date -u +%FT%TZ): $msg"$'\n'"Approved; any note above is stale; proceed using this answer."
else
  ...unchanged...
fi
```

- The answer (`$msg`) is inserted verbatim, no trimming, no trailing dash/space added. A single `\n`
  (not a blank line) separates it, so the sentence is "the line immediately after the answer" (AC2).
- Sentence text is exactly `Approved; any note above is stale; proceed using this answer.` (AC1, AC3) and is
  independent of the answer's punctuation or dashes.
- The no-`-m` branch is not touched (AC4). Validation of empty `-m` / multiple ids is above the loop and not
  touched (AC5).
- Multi-line answers: the sentence is still the last line and directly follows the answer's last line.
- No README change needed (grep finds no mention of the old wording); update the explanatory comment only if it
  names the old format (it does not).

## Files
- Change: `bin/approve.sh` (the one `note=` assignment in the `-m` branch).
- Add: `tests/agent-factory-kvy_test.sh` (QA).

## Interfaces / data shape
Note stored by `bd` after `approve.sh -m "use B." <id>`:
```
Human answer via approve.sh by <user> at <ts>: use B.
Approved; any note above is stale; proceed using this answer.
```
Note that `bd --append-notes` may join with an existing note via newline; the two lines above stay adjacent.

## Error cases
Unchanged: `-m` without value, empty/whitespace message, `-m` with 0 or >1 ids exit 2 with existing messages.

## Acceptance criteria mapping
1, 2, 3: the note assignment above. 4, 5: code untouched.

## Test strategy (QA)
Shell test using a stub `bd` on PATH (as tests/acceptance/agent-factory-f6g.sh does) capturing the `--append-notes` argument:
- AC1/2: with `-m "use option B"`, captured note's last line equals the exact sentence; the line before it ends with
  `use option B`; note has exactly 2 lines.
- AC3: answers `done.`, `pick A - not B`, `ends with dash -` each: last line exact sentence, previous line ends with the answer verbatim.
- Multi-line answer (`$'a\nb'`): last line still the sentence, line before is `b`.
- AC4: no `-m` note equals the old generic wording, single line.
- AC5: `-m ""`, `-m "  "`, and `-m x id1 id2` exit non-zero with existing error text.
- Regression: run existing `tests/acceptance/agent-factory-f6g.sh` (still passes; it checks only `Human answer` + message).
