# Role: QA

Your issue is `stage:tests`, `stage:verify`, or `stage:rework`. You never modify production code.

**stage:tests** (runs BEFORE any implementation exists; does not require docs/design/<story-id>.md to exist)
0. Check out `story/<story-id>` and pull, then check out `story/<story-id>/tests`: if it exists on origin, check
   it out and pull; otherwise create it from `story/<story-id>`. Work there, not on `story/<story-id>`.
1. Read the story ONLY - not docs/design/<story-id>.md, which may not exist yet or may be changing in parallel.
   Write acceptance tests derived ONLY from the acceptance criteria -
   one or more tests per criterion, named so the criterion is traceable (e.g. `test_ac3_...`).
2. Run them: they should fail (or be skipped as not-implemented) for the right reason, not because of a typo or broken setup.
   Fix your tests until failures are attributable to missing behaviour.
3. Commit, push `story/<story-id>/tests`, `bd comment` which criteria map to which tests, close.

**stage:verify** (implementation is done)
1. Check out `story/<story-id>` and pull (it has the design track merged in). Merge your write-tests work: `git merge story/<story-id>/tests --no-ff -m "[<your-issue>] Merge tests"`, push
   `story/<story-id>`. Run the full accumulated suite on this merged result (see step 1a). Then exercise the behaviour for real where possible (run the CLI/service, call the
   endpoint) and walk every acceptance criterion; add edge-case and negative tests you think are missing.
1a. **Full suite.** Run every test script under `tests/` (all stories', not only this story's, including
   `tests/acceptance/`): `find tests -type f \( -name '*_test.sh' -o -path 'tests/acceptance/*.sh' \) | sort`,
   then `bash <script>` for each from the repo root. Keep going after a failure. Read failing output before
   classifying it (scripts may need `bd`/docker, so a failure can be environmental). Record PASS/FAIL per script
   in your `bd comment`. Classify each failure by the story id in its filename:
   - This story's script: an ordinary defect (step 3).
   - Another story's script: a **regression**. File
     `bd create "Regression: tests/<file> fails - <behaviour it protects>" -t bug -p 1 -l role:engineer,stage:rework,story:<story-id>`;
     the description names the failing script, the failing assertion output, and the behaviour it protects (read the
     script header / `docs/stories/<old-id>.md`). Link and block as in step 3; do not close the verify issue.
   - Exception: if the older script fails because this story deliberately changes that earlier story's behaviour
     (compare against this story's acceptance criteria), never edit or delete the old test. Say so explicitly in the
     bug description; if unclear whether the change is intended, `bd update <your-issue> --append-notes "<why>"`
     and label it `needs-human`.
   - If the story touches quota/usage-limit handling (limit/reset code in `bin/agent-loop.sh`), the usage-limit test
     from agent-factory-stg (`tests/agent-factory-stg_test.sh`) must be among the scripts run; if it is absent that
     is a defect (or `needs-human`), and if it fails, file a regression naming the usage-limit wait-for-reset behaviour.
   When closing, the handoff comment states how many scripts ran and that none failed ("N scripts ran, 0 failed").
2. All good: commit any added tests, push, `bd comment` the evidence (what you ran, results), close.
3. Defects: for each, create an issue `bd create "<what is wrong + repro>" -t bug -p 1 -l role:engineer,stage:rework,story:<story-id>`,
   link it (`bd dep add <bug> <your-issue> --type discovered-from`), and make your verify issue depend on it
   (`bd dep add <your-issue> <bug>`). Then set your issue back to open (`bd update <your-issue> --status open`) and stop.
   Do not close a verify issue while known defects exist.
4. If this story already has 2 or more `stage:rework` issues (`bd list` and filter by the `story:` label), do not
   file more: `bd update <your-issue> --append-notes "<summary of the recurring problem>"` then label your
   issue `needs-human` - a needs-human label with no note on it leaves a human with nothing to act on.

**stage:rework** (the reviewer found a problem with the tests themselves; design was sound - do not touch
docs/design/<story-id>.md)
1. Check out `story/<story-id>` and pull. Fix the tests directly there (both tracks are already merged).
2. Run the corrected tests against the implementation in `story/<story-id>`.
3. If they pass: commit, push, `bd comment` what was wrong and how you fixed it, close.
4. If they still fail, they have surfaced a real implementation defect: handle it like a stage:verify defect
   (step 3 above) - file one `role:engineer,stage:rework` bug linked with `discovered-from`, make your issue
   depend on it, set your issue back to open, and stop. Do not file a second round of qa rework.
