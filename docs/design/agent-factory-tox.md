# Design: hyphenated track branch names (agent-factory-tox)

## Approach
Pure rename, no behaviour change. Track branches become `story/<id>-design` and `story/<id>-tests`
(git cannot hold `story/<id>` as a branch and `story/<id>/design` at once). Rename is a mechanical
substitution of the exact strings `story/<story-id>/design` -> `story/<story-id>-design`,
`story/<story-id>/tests` -> `story/<story-id>-tests` (and the `<id>` forms). Do NOT touch
`docs/design/<story-id>.md` or `tests/` path references - only the `story/...` branch names.

## Files to change
- `agents/architect.md` (lines 4, 25, 28, 30, 31 - includes the rework `bd create -d` text, twice)
- `agents/engineer.md` (lines 6, 16 merge command, 21)
- `agents/qa.md` (lines 6, 13, 16 merge command)
- `agents/CLAUDE.project.md` (lines 29-30)
- `README.md` "Flow" (line 39)
- `docs/design/agent-factory-icv.md`: branch names only (~lines 15-21, 89-336); leave rationale as is.
- `tests/agent-factory-icv_test.sh`: lines 94-96, 103-104, 110-111 assert hyphenated names. Line 97
  (`grep -q '/design'` / `'/tests'` on CLAUDE.project.md) must become `-design` / `-tests`.
  Add a negative check: no file in `agents/*.md` matches `story/<story-id>/(design|tests)` (AC1, AC2).
- `docs/ARCHITECTURE.md`: no mention of tracks; no change needed.
- Leave `docs/stories/agent-factory-tox.md` alone (it quotes the old names deliberately).

Suggested one-liner: `sed -i -E 's#(story/<(story-)?id>)/(design|tests)#\1-\3#g' <files>`, then review
`git diff` (the `<id>` regex also covers `story/<story-id>`; check `docs/design/...` paths are untouched).

## Acceptance criteria
1-2: prompts contain only hyphenated names (grep negative check in the test).
3: verified by a git-level test - in a temp repo, create branch `story/X`, then `git checkout -b story/X-design`
   and `story/X-tests` from it and push to a bare origin; both succeed (this failed with nested names).
4: merge commands in engineer.md/qa.md use `story/<story-id>-design` / `-tests`; flags and messages unchanged.
5: README Flow and CLAUDE.project.md use hyphenated names only.
6: updated icv test passes.

## Error cases
Existing nested-name branches on origin are out of scope (not cleaned up). Note: nested branches cannot
exist alongside `story/<id>`, so in practice none should.

## Test strategy (QA)
- Shell: extend `tests/agent-factory-icv_test.sh` as above (string assertions incl. negative greps over
  `agents/` and `README.md`).
- Git-level test for AC3 in a temp bare repo, as described. Run with the project's existing test runner
  (see docs/ARCHITECTURE.md); the full suite must still pass.
