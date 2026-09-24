# Design: Reviewer routes merge conflicts to rework (agent-factory-h71)

Prompt-only change: edit `agents/reviewer.md`, `agents/engineer.md`, `agents/qa.md`. No scripts,
no Dockerfile. (Branch note: git cannot hold both `story/<id>` and `story/<id>/design`, so this
story's design branch is `story/agent-factory-h71-design`, matching the stg/tox/vzt precedent.
Engineer: merge that branch into `story/agent-factory-h71` at the end.)

## Approach
Replace the reviewer's "conflict -> needs-human" sentence in the **Approve** paragraph with a
conflict procedure that reuses the request-changes mechanism.

### reviewer.md - new conflict procedure (replaces the last two lines of Approve)
If `git merge --no-ff story/<story-id>` reports conflicts:
1. Collect data before aborting: `git diff --name-only --diff-filter=U` (conflicting files) and
   `git log --oneline origin/main..story/<story-id>` plus
   `git log --oneline story/<story-id>..origin/main -- <conflicting files>` (commits involved on each side).
2. `git merge --abort`, then confirm `git status` is clean and `git log origin/main..main` is empty. Never
   `git push` after a failed merge (AC7). If the abort leaves main dirty, `git reset --hard origin/main`.
3. Classify each conflicting file as **test** if its path starts with `tests/` or `test/`, or its basename
   matches `*_test.*`, `test_*` or `*.test.*`; everything else (code, docs, scripts) is **non-test**.
   - all non-test -> `role:engineer`
   - all test -> `role:qa`
   - mixed -> `role:engineer` (AC2-4)
4. File the issue:
   `bd create "Merge conflict: bring story/<story-id> up to date with origin/main" -t task -p 1 -l <role:X>,stage:rework,story:<story-id>,merge-conflict -d "<description>"`
   Description must name the conflicting files, the commits on both sides (from step 1), and ask to merge
   `origin/main` into `story/<story-id>`, resolve conflicts, re-run the full suite, and push (AC5).
5. `bd dep add <new> <your-issue> --type discovered-from`, `bd dep add <your-issue> <new>`,
   `bd update <your-issue> --status open`, `bd comment` the conflict summary, stop (AC6). Do NOT label
   `needs-human` (AC1).

### Rework cap
The existing "2 or more `stage:rework` issues -> needs-human" rule must not trip on routine conflicts.
Conflict rework issues carry the extra label `merge-conflict` and are **excluded from the count**
(reviewer.md cap paragraph, qa.md step 4). A conflict rework is filed before the cap check is consulted.
Request-changes flow otherwise unchanged.

### engineer.md - stage:rework
Add a case above "Otherwise": if the issue has label `merge-conflict` (or its title starts with "Merge
conflict:"), check out `story/<story-id>`, pull, `git fetch origin main && git merge origin/main`
(rebase not allowed: the branch is shared and pushed), resolve conflicts preserving both sides' intent,
never edit QA acceptance tests' assertions to make them pass (only textual conflict resolution), re-run
the full suite and linter, commit, push `story/<story-id>` (AC8). No regression test needed. If a
conflict cannot be resolved sensibly, `--append-notes` + `needs-human` (existing fallback).

### qa.md - stage:rework
Same case, at step 1: if `merge-conflict` label, check out `story/<story-id>`, pull, merge `origin/main`,
resolve the test-file conflicts, re-run the full suite, push, comment, close. The "real implementation
defect" step 4 still applies if tests fail afterwards.

## Acceptance criteria mapping
1: no `needs-human` in conflict path. 2-4: step 3 classification. 5: step 4 description. 6: step 5.
7: step 2. 8: engineer/qa rework additions.

## Test strategy (QA)
Prompt files are text, so tests are shell greps in `tests/agent-factory-h71_test.sh` (style of the
existing `tests/*_test.sh`), asserting: reviewer.md no longer pairs "conflict" with `needs-human`; mentions
`git merge --abort`, `discovered-from`, `--status open`, `role:qa`, `role:engineer`, `merge-conflict`,
`origin/main`; classification rules (all tests -> qa, mixed -> engineer); cap excludes `merge-conflict`;
engineer.md and qa.md each mention merging `origin/main`, resolving conflicts, re-running the suite,
pushing. Optionally a scratch-repo scenario that creates a real conflict and checks the abort recipe
leaves main clean and `--diff-filter=U` lists the files.
