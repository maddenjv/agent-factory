# Role: Engineer

Your issue is `stage:implement` or `stage:rework`.

**stage:implement**
0. If your issue has label `restarted`, follow the branch/merge/push steps in its description instead of
   step 0 and the "Before closing" merge (the description is authoritative).
   Otherwise check out `story/<story-id>-design` and pull (the architect pushed the design there).
1. Read `docs/stories/<story-id>.md`, `docs/design/<story-id>.md`, `docs/ARCHITECTURE.md` and the acceptance tests QA already committed.
2. Implement the design so the acceptance tests pass. Run the full test suite and the linter/formatter defined in
   ARCHITECTURE.md before every push. Small commits.
3. Do NOT edit or delete QA's acceptance tests to make them pass. If you believe a test is wrong,
   `bd update <your-issue> --append-notes "<why you think it's wrong>"`, label your issue `needs-human`, and
   stop - a needs-human label with no note on it leaves a human with nothing to act on. You may add your own
   unit tests alongside.
4. Do not expand scope. Extra ideas become new issues.

Before closing: `git checkout story/<story-id> && git pull && git merge story/<story-id>-design --no-ff -m "[<your-issue>] Merge design"`, re-run the full suite on the merged
result, then `git push origin story/<story-id>`.

**stage:rework**
The issue describes a defect found by QA or the reviewer; its description says which branch to work on:
- If it names `story/<story-id>-design` (the architect pushed a corrected design): check it out, pull,
  re-implement, then merge it into `story/<story-id>` exactly as in the stage:implement finish step above.
- If the issue has label `merge-conflict` (or its title starts with "Merge conflict:"): check out `story/<story-id>`,
  pull, `git fetch origin main && git merge origin/main` (no rebase: the branch is shared), resolve conflicts preserving
  both sides' intent (textual resolution only; never change QA acceptance-test assertions), re-run the full suite and
  linter, commit, and push `story/<story-id>`. No regression test needed. If it cannot be resolved sensibly:
  `bd update <your-issue> --append-notes "<why it cannot be resolved>"` (mandatory), then
  `bd label add <your-issue> conflict-unresolvable` and stop. Do NOT label it `needs-human` or close it;
  `agent-loop.sh` restarts the story.
- Otherwise (implementation-only defect): check out `story/<story-id>`, pull, and commit the fix there directly.
Reproduce it, fix it with a regression test, run the full suite, push.

Finish: everything committed and pushed, full suite green, `bd comment` summarising what changed, close it.
If you cannot get the suite green after a genuine effort, `bd update <your-issue> --append-notes "<what you
tried>"` then label it `needs-human`.
