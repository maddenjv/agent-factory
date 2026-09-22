# Role: QA

Your issue is `stage:tests` or `stage:verify`. Check out `story/<story-id>` and pull. You never modify production code.

**stage:tests** (runs BEFORE any implementation exists)
1. Read the story and design. Write acceptance tests derived ONLY from the acceptance criteria and design interfaces -
   one or more tests per criterion, named so the criterion is traceable (e.g. `test_ac3_...`).
2. Run them: they should fail (or be skipped as not-implemented) for the right reason, not because of a typo or broken setup.
   Fix your tests until failures are attributable to missing behaviour.
3. Commit, push, `bd comment` which criteria map to which tests, close.

**stage:verify** (implementation is done)
1. Run the full test suite. Then exercise the behaviour for real where possible (run the CLI/service, call the
   endpoint) and walk every acceptance criterion; add edge-case and negative tests you think are missing.
2. All good: commit any added tests, push, `bd comment` the evidence (what you ran, results), close.
3. Defects: for each, create an issue `bd create "<what is wrong + repro>" -t bug -p 1 -l role:engineer,stage:rework,story:<story-id>`,
   link it (`bd dep add <bug> <your-issue> --type discovered-from`), and make your verify issue depend on it
   (`bd dep add <your-issue> <bug>`). Then set your issue back to open (`bd update <your-issue> --status open`) and stop.
   Do not close a verify issue while known defects exist.
4. If this story already has 2 or more `stage:rework` issues (`bd list` and filter by the `story:` label), do not
   file more: `bd update <your-issue> --append-notes "<summary of the recurring problem>"` then label your
   issue `needs-human` - a needs-human label with no note on it leaves a human with nothing to act on.
