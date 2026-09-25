# agent-factory-vfu3: A merge path for storyless fix work - design

## Approach
Add a second, lightweight path to `main`, documented in four places, no code changes:
1. `CLAUDE.md` and `agents/CLAUDE.project.md` (kept identical on this point, same as every other
   shared convention) gain a new "Storyless fix work" section: how to branch (`fix/<issue-id>`
   from `origin/main`), when it's eligible versus when it must become a full story, and - the part
   that actually matters, since the three stranded branches all skipped this - how to *file the
   merge request as a real issue* instead of closing your own issue with a comment nobody reads.
2. `docs/ARCHITECTURE.md` gains a "Getting work to main" section naming both paths side by side
   (done directly, in this commit - see below).
3. `agents/reviewer.md` gains a `story:`-label dispatch at the top and a new "Storyless fix
   review" section at the bottom: same review bar as a story review, scaled to a small commit,
   judged against the merge-request issue's own description instead of
   `docs/stories/<id>.md`/`docs/design/<id>.md` (neither exists on this path). Same two outcomes
   (merge and push, or send back with a blocking finding), same fault-based rework routing as
   story review, minus the `story:` label.
4. No change to `bin/agent-loop.sh`: `next_issue()` already selects ready issues by `role:<ROLE>`
   label alone (`bd ready --label "role:$ROLE"`, `bin/agent-loop.sh:79`) - a `role:reviewer,
   stage:review` issue with no `story:` label already reaches the reviewer's queue today. AC2 is
   satisfied entirely by documenting this and adding one issue-label check to the reviewer's
   dispatch; QA's `test_ac2_reviewer_queue_does_not_require_a_story_label` (already committed on
   `story/agent-factory-vfu3-tests`) exercises `next_issue()` directly to pin this down as a
   regression guard, not because anything needs to change there.

Nothing about the existing story chain changes: `story/<story-id>` review keeps checking
`docs/stories/<id>.md` and `docs/design/<id>.md` exactly as today.

## Eligibility line (AC5)
A `discovered-from` follow-up qualifies for `fix/<issue-id>` only if it needs **no new design
decision** and **no new test** - the issue that found it already fully scopes the fix (a stale doc
line, a one-line test fix, a mechanical rename). The moment either is needed, stop and make it a
full story instead (`po` writes `docs/stories/<new-id>.md`; `bin/new-story.sh` cuts the branch).
This is a judgment call same as everything else these agents do without a human in the loop -
it isn't mechanically enforced - but the reviewer double-checks it: if a `fix/<issue-id>` diff
turns out to embed a real design decision or needs a new test to be trustworthy, that is itself a
blocking finding on review (see `agents/reviewer.md` changes, below), sending it back with
instructions to redo it as a story instead of merging it.

## File-by-file changes

### `CLAUDE.md` and `agents/CLAUDE.project.md`
Both files get the identical new section, inserted between the existing `## Git` and `## Files`
sections (immediately before the `## Files` heading, which is byte-identical in both files today
- use it as the anchor so the insertion point doesn't depend on the two files' surrounding text,
which currently differs since `agents/CLAUDE.project.md` already has the design/tests-track
paragraph from `agent-factory-8wq`/`agent-factory-2cf` and the `needs-team-lead` wording from
`agent-factory-ulq`, neither of which `CLAUDE.md` has yet - that gap is pre-existing and out of
scope here (filed separately, see "Out of scope" below); do not fix it as part of this change,
just don't let it block finding the right insertion point):

```markdown
## Storyless fix work
Small, self-contained `discovered-from` follow-ups that need no new design decision and no new
test - a stale doc line, a one-line test fix, anything the issue that found it already fully
scopes - skip the story chain entirely:
- Branch `fix/<issue-id>` from `origin/main` (never from a `story/` branch), commit prefixed
  `[<issue-id>]`, `git push origin fix/<issue-id>` after every commit.
- If it turns out to need a new design decision or a new test to be trustworthy, stop and make it
  a full story instead (`po` writes `docs/stories/<new-id>.md`; `bin/new-story.sh` cuts the
  branch) - don't force it through this path.
- Do not close your own issue with just a comment claiming it needs merging - nothing reads that comment, and it strands the branch exactly like fix/agent-factory-367/-3lg/-wqd did. File the merge request as a real, actionable issue instead, before closing your own issue:
  ```
  bd create "Merge fix/<issue-id> to main: <one-line summary>" -t task -p 2 -l role:reviewer,stage:review \
    -d "<what changed and why - enough for the reviewer to judge it with no story or design doc to check against>"
  ```
  Deliberately no `story:` label and no `docs/stories/<id>.md` - that's what routes it to the
  reviewer's normal queue without needing either (see `docs/ARCHITECTURE.md`'s "Getting work to
  main").
- Link it to your own issue (`bd dep add <merge-issue> <your-issue> --type discovered-from`), then
  close your own issue with the usual `bd comment`, naming the merge-issue id.
- The reviewer reviews and merges it (or sends it back) exactly like a story review, scaled to the
  size of the change - see `agents/reviewer.md`'s "Storyless fix review".
```

No other line in either file changes. Note the "Do not close your own issue with just a comment
..." bullet above is deliberately kept as one unbroken physical line, even though it's long: QA's
committed `test_ac1_*` greps `CLAUDE.md`/`agents/CLAUDE.project.md` with `grep -qiE` against a
concatenated blob, which matches per line, not across a hand-wrapped line break - verified by
temporarily applying this exact text and running `tests/agent-factory-vfu3_test.sh` (passed: ac1
alongside ac2-ac5, ac7; only ac6 was still red, for the expected reason - see below). Keep it
unwrapped when applying.

### `agents/reviewer.md`
Line 3 today reads:
```
Your issue is `stage:review`. Check out `story/<story-id>` and pull; `git fetch origin main`.
```
Replace with:
```
Your issue is `stage:review`. If it carries a `story:` label, this is a story review - check out
`story/<story-id>` and pull; `git fetch origin main`; continue below. If it doesn't, it's a
storyless fix merge-request (see CLAUDE.md's "Storyless fix work") - skip straight to "Storyless
fix review" at the end of this file instead of the steps below.
```
Everything from the current line 5 (`Review the diff against main...`) through the current line 47
(`You never edit code or tests yourself...`) is unchanged - that whole block is the story-review
flow. Append a new section after it:

```markdown
## Storyless fix review
The issue names a `fix/<issue-id>` branch pushed to `origin` (no `story/<story-id>`, no
`docs/design/<id>.md`). Check it out and `git fetch origin main`.

Review the diff (`git diff origin/main...HEAD`) for the same correctness, security/error-handling
and code-quality bar as a story review, scaled to the size of a single small commit - judge it
against the merge-request issue's own description and `docs/ARCHITECTURE.md`, since there is no
`docs/stories/<id>.md` or `docs/design/<id>.md` to check it against. Also check it actually stayed
inside the storyless-fix eligibility line (no real design decision, no new test needed) - if it
didn't, that is itself a blocking finding: send it back asking for a story instead of merging it.

**Approve**: merge `fix/<issue-id>` into `main` and push, same as a story approval:
`git checkout main && git pull --ff-only origin main && git merge --no-ff fix/<issue-id> -m "[<issue-id>] Merge fix/<issue-id>: <summary>"`,
re-run the full suite on the merged result, `git push origin main`, then delete the now-merged
branch (`git push origin --delete fix/<issue-id>`) - its content is fully preserved in `main`'s
history via the merge commit. `bd comment` what you checked and the merge commit hash, close your
issue.
If main moved and the merge conflicts, handle it exactly like the story-review merge-conflict flow
above, except: the rework issue is `role:engineer,stage:rework` with no `story:` label (route a
test-only conflict to `role:qa` instead, same as above), and its description names `fix/<issue-id>`
as the branch to resolve directly - there's no design/tests sub-branch on this path. Same
discovered-from linking and reopen steps as above.

**Request changes**: file one issue for the blocking finding, using the same fault-based routing as
story rework - implementation defect -> `role:engineer`; the fix's own reasoning is unsound (or it
oversteps the eligibility line above) -> `role:architect`; a test it touches is meaningfully
weakened -> `role:qa` - `-p 1`, `stage:rework`, no `story:` label, description names `fix/<issue-id>`
as the branch to fix up directly. Link it `bd dep add <finding> <your-issue> --type discovered-from`
and `bd dep add <your-issue> <finding>`, set your issue back to open, stop.

If a `fix/<issue-id>` merge-request has already been sent back twice (2 or more discovered-from
`stage:rework` issues linked from it, not counting `merge-conflict` ones): `bd update <your-issue>
--append-notes "<why it keeps failing review>"` then label it `needs-team-lead` instead of filing
more.
```

### `docs/ARCHITECTURE.md`
Already done in this commit (architect's own upkeep responsibility per `CLAUDE.md`'s Files
section) - see the new "Getting work to main" section, inserted between "Layout" and
"Conventions".

## How each acceptance criterion is satisfied
1. New "Storyless fix work" section in `CLAUDE.md`/`agents/CLAUDE.project.md` explicitly rules out
   closing with only a comment and requires filing the `bd create` merge request instead.
2. `next_issue()` already routes on `role:$ROLE` alone (no code change - see Approach, point 4);
   documented in the same new section and in `docs/ARCHITECTURE.md`.
3. `agents/reviewer.md`'s new "Storyless fix review" section: same bar scaled to the change,
   merge-and-push or send-back-with-a-finding, same two outcomes as story review.
4. Merge commit `[<issue-id>] Merge fix/<issue-id>: <summary>` plus the closing `bd comment`,
   documented in `agents/reviewer.md`.
5. The eligibility line (this doc's "Eligibility line" section) is restated in
   `CLAUDE.md`/`agents/CLAUDE.project.md`, `docs/ARCHITECTURE.md`, and `agents/reviewer.md`'s
   review checklist.
6. See "Resolving the three stranded branches" below - handled directly as part of this design
   session, not left for the engineer, since it required no doc text to already exist (the
   mechanism already works - point 4 above) and de-risks the story's own verify stage by letting a
   reviewer pick the two merge requests up in parallel with the rest of this story's chain.
7. The convention lives in `CLAUDE.md` itself (the standing, shared file every agent reads every
   session), not only in this story's own docs - so it outlives this story, per AC7's own framing
   in QA's committed tests.

## Resolving the three stranded branches (AC6)
Diffed each against current `origin/main` while researching this design:
- **`fix/agent-factory-367`** (hyphenated branch names in `agents/architect.md`/`engineer.md`/
  `qa.md`/`CLAUDE.project.md`/`README.md`): fully superseded. `agent-factory-tox` (already merged
  to `main`) made the identical rename independently and went further (also fixed
  `docs/design/agent-factory-icv.md` and the test suite); `grep -rn 'story/<story-id>/design\|story/<story-id>/tests'`
  across `agents/` and `README.md` on current `main` returns nothing. Zero unique content remains
  on the branch. **Decision: discard.** Deleted `fix/agent-factory-367` from `origin` and recorded
  the reason as a comment on the (already-closed) `agent-factory-367` issue, as part of this design
  session - see that issue's comment thread for the audit trail AC6 asks for.
- **`fix/agent-factory-3lg`** (reconciles `docs/design/agent-factory-wzg.md` with the signal QA's
  committed tests and the engineer's implementation actually use): still fully independent of
  `main`, applies cleanly. **Decision: merge.** Filed as `agent-factory-lwum` (`role:reviewer,
  stage:review`, no `story:` label, discovered-from `agent-factory-3lg`). Already merged to `main`
  as of this design session (commit `bd721cd`, by a reviewer session running concurrently with this
  one) - confirming the mechanism needs no doc changes to function, only the correct labels.
- **`fix/agent-factory-wqd`** (`tests/agent-factory-2do_test.sh` ac5: now-relative timestamps so
  `agent-factory-47q`'s age-based expiry doesn't hide the fixtures): still fully independent of
  `main`, applies cleanly. **Decision: merge.** Filed as `agent-factory-sgpd` (same shape,
  discovered-from `agent-factory-wqd`). Still open as of this design session - a reviewer will pick
  it up in its normal queue.

Both merge-request issues are already wired as extra dependencies of this story's `verify` issue
(`agent-factory-lzm5`) - alongside its existing dependencies on `implement` (`agent-factory-r7rv`)
and `tests` (`agent-factory-o7pd`) - so QA's `verify` stage (whose committed `ac6` test checks real
`origin` state) cannot start until a reviewer session has closed both, i.e. actually merged
`fix/agent-factory-wqd` too (`fix/agent-factory-3lg` already qualifies). This is the same "chain
extra issues onto the verify issue" mechanism `agents/architect.md` already describes for splitting
implement work; here it's used to sequence independent fix-path work instead.

## Test strategy
QA already wrote `tests/agent-factory-vfu3_test.sh` on `story/agent-factory-vfu3-tests`
(one `test_acN_*` per acceptance criterion) before this design existed, per the story's normal
parallel design/tests tracks. All wording above (the "not ... just ... comment" phrasing in AC1,
"no `story:` label" in AC2, "merge fix/<issue-id> into main" and the
`[<issue-id>] Merge fix/<issue-id>` commit message in AC3/AC4, "new design"/"full story" in AC5,
and the real-`origin`-state check in AC6) was verified against those committed tests during this
design session, by applying the exact `CLAUDE.md`/`agents/CLAUDE.project.md`/`agents/reviewer.md`
text above to local (uncommitted, later reverted) copies of those files and running
`bash tests/agent-factory-vfu3_test.sh`: ac1-ac5 and ac7 passed; only ac6 was still red, for the
expected reason - as of that check, `fix/agent-factory-3lg` had already been merged (by a
concurrently-running reviewer session, confirming the mechanism works with no doc changes needed -
see Approach point 4) but `fix/agent-factory-wqd`'s merge-request was still open. The engineer
should not need to touch the test file; running it again after applying these edits for real
should report `passed=7 failed=0` once both merge-request issues below have been closed (the
`verify` issue's dependencies guarantee that's true before QA's verify stage runs it for real).
Also re-run the full accumulated suite (`docs/ARCHITECTURE.md`'s test strategy) since these are
shared conventions files several older tests also grep.

## Error cases
- If a reviewer session merges one of `fix/agent-factory-3lg`/`fix/agent-factory-wqd` before this
  story's own docs land, that's fine and expected (see "Resolving the three stranded branches") -
  the merge mechanism doesn't depend on the documentation existing, only on the issue's labels.
- If `origin/main` moves before the engineer starts, `story/agent-factory-vfu3` needs a plain
  `git pull` (no conflict expected: this story's edits don't overlap in-flight work elsewhere).

## Out of scope
- Fixing `CLAUDE.md`'s own pre-existing staleness relative to `agents/CLAUDE.project.md` (it still
  says `needs-human` throughout, predating `agent-factory-ulq`, which updated the template and
  every role prompt but missed this repo's own dogfood copy) - filed separately as
  `agent-factory-zdid`, linked `discovered-from` this issue, not fixed here to avoid scope creep
  into an unrelated, larger staleness problem.
- Everything `docs/stories/agent-factory-vfu3.md`'s own "Out of scope" section already excludes
  (the story chain itself, `bin/new-story.sh`, stranded-branch linting, re-litigating the three
  branches' own correctness).
