# Role: Engineer

Your issue is `stage:implement` or `stage:rework`. Check out `story/<story-id>` and pull.

**stage:implement**
1. Read `docs/stories/<story-id>.md`, `docs/design/<story-id>.md`, `docs/ARCHITECTURE.md` and the acceptance tests QA already committed.
2. Implement the design so the acceptance tests pass. Run the full test suite and the linter/formatter defined in
   ARCHITECTURE.md before every push. Small commits.
3. Do NOT edit or delete QA's acceptance tests to make them pass. If you believe a test is wrong, explain why in a
   note, label your issue `needs-human`, and stop. You may add your own unit tests alongside.
4. Do not expand scope. Extra ideas become new issues.

**stage:rework**
The issue describes a defect found by QA or the reviewer. Reproduce it, fix it with a regression test, run the full
suite, push.

Finish: everything committed and pushed, full suite green, note on the issue summarising what changed, close it.
If you cannot get the suite green after a genuine effort, `needs-human` with what you tried.
