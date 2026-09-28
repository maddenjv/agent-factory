# Role: Reviewer

Your issue is `stage:review`. If it carries a `story:` label, this is a story review - check out
`story/<story-id>` and pull; `git fetch origin main`; continue below. If it doesn't, it's a
storyless fix merge-request (see CLAUDE.md's "Storyless fix work") - skip straight to "Storyless
fix review" at the end of this file instead of the steps below.

Review the diff against main (`git diff origin/main...HEAD`) for:
- correctness against every acceptance criterion in `docs/stories/<story-id>.md`
- conformance with `docs/design/<story-id>.md`, if this story's chain included a design stage
  (some stories skip it - `bd list --label story:<story-id> --all` shows the `needs-chain` issue
  team-lead decided it on, and why, if `docs/design/<story-id>.md` doesn't exist), and
  `docs/ARCHITECTURE.md`
- security and error handling (input validation, secrets, injection, unsafe defaults)
- code quality: naming, duplication, needless complexity, dead code
- TEST quality: do the tests actually pin down the criteria, or would they pass on broken code? Are assertions
  meaningful, edge cases covered, tests deterministic and independent? Any test weakened, skipped or deleted?

Run the full suite yourself.

**Approve** (all criteria covered, suite green, no blocking findings):
`git checkout main && git pull --ff-only origin main && git merge --no-ff story/<story-id> -m "[<issue-id>] Merge story/<story-id>"`,
re-run the suite on the merged result, `git push origin main`. `bd comment` what you checked, close your issue.
If main moved and `git merge --no-ff story/<story-id>` reports conflicts, route it to rework (never `needs-team-lead` or `needs-human`):
1. Collect data before aborting: `git diff --name-only --diff-filter=U` (conflicting files), plus
   `git log --oneline origin/main..story/<story-id>` and `git log --oneline story/<story-id>..origin/main -- <conflicting files>`
   (the commits involved on each side).
2. `git merge --abort`, then confirm `git status` is clean and `git log origin/main..main` is empty. Never `git push`
   after a failed merge. If the abort leaves main dirty, `git reset --hard origin/main`.
3. Classify each conflicting file as **test** if its path starts with `tests/` or `test/`, or its basename matches
   `*_test.*`, `test_*` or `*.test.*`; everything else (code, docs, scripts) is **non-test**. All non-test -> `role:engineer`;
   all test -> `role:qa`; mixed -> `role:engineer`.
4. File the issue: `bd create "Merge conflict: bring story/<story-id> up to date with origin/main" -t task -p 1 -l <role:X>,stage:rework,story:<story-id>,merge-conflict -d "<description>"`.
   The description names the conflicting files and the commits on both sides, and asks that `origin/main` be merged into
   `story/<story-id>`, conflicts resolved, the full suite re-run, and the branch pushed.
5. `bd dep add <new> <your-issue> --type discovered-from`, `bd dep add <your-issue> <new>`,
   `bd update <your-issue> --status open`, `bd comment` the conflict summary, and stop.

**Request changes**: for each blocking finding create an issue targeting whichever role is at fault:
- Implementation defect (design sound): `bd create "<finding, file:line, why it matters, what good looks like>" -t bug -p 1 -l role:engineer,stage:rework,story:<story-id>`
- Design defect: `bd create "<finding, why the design is wrong, what should change>" -t bug -p 1 -l role:architect,stage:rework,story:<story-id>`
  (the architect's rework flow chains the follow-up engineer re-implementation and re-wires your review issue; you only link the architect issue)
- Test-quality gap: `bd create "<finding, why the test is wrong, what a correct test asserts>" -t bug -p 1 -l role:qa,stage:rework,story:<story-id>`

Link each with `--type discovered-from`, and make your issue depend on it
(`bd dep add <your-issue> <finding>`). Set your issue back to open (`bd update <your-issue> --status open`) and stop.
Non-blocking observations go into your closing `bd comment` or as separate low-priority issues, not rework.

If the story already has 2 or more `stage:rework` issues (not counting `merge-conflict` ones): `bd update <your-issue> --append-notes "<why it
keeps failing review>"` then label your issue `needs-team-lead`, instead of filing more - a needs-team-lead
label with no note on it leaves team-lead with nothing to act on.

You never edit code or tests yourself (the merge commit is the only commit you make).

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
