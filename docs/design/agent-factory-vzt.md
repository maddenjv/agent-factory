# Design: agent-factory-vzt - QA runs the whole accumulated suite on verify

## Approach
Pure prompt change. Edit `agents/qa.md` **stage:verify** only (story: stage:tests / stage:rework are out of
scope) so "run the full test suite" becomes a concrete, systematic procedure. No new scripts, no
`make test`, no framework (out of scope; see ARCHITECTURE "Test strategy").

## Facts about the suite today
- Scripts live in two layouts: `tests/<story-id>_test.sh` (newer) and `tests/acceptance/<story-id>.sh`
  (older). "Every script under `tests/`" therefore means **recursive**, both layouts. The story text only
  names the first; the wording in qa.md must not.
- Each script is standalone bash, run as `bash <script>`, exit 0 = pass. No shared runner.
- Scripts may need `bd`/docker, so a failure can be environmental; qa must read the output before
  classifying it.

## Change to `agents/qa.md` (stage:verify, step 1 and following)
Replace "Run the full test suite on this merged result." with a step containing, in this order:

1. **Enumerate**: `find tests -type f \( -name '*_test.sh' -o -path 'tests/acceptance/*.sh' \) | sort`
   (after the tests-track merge, on `story/<story-id>`). Run each as `bash <script>` from the repo root,
   record exit status and keep going after a failure (do not stop at the first).
2. **Record**: the `bd comment` lists every script with PASS/FAIL (AC1).
3. **Classify each failure** by the story id in the filename:
   - Current story's script -> ordinary defect (existing step 3).
   - Another story's script -> **regression**. File
     `bd create "Regression: tests/<file> fails - <behaviour it protects>" -t bug -p 1 -l role:engineer,stage:rework,story:<story-id>`
     whose description names the script, the failing assertion output, and the behaviour protected
     (read the script's header comment / `docs/stories/<old-id>.md`). Link and block as in step 3; do not close (AC2).
   - Exception: if the older script fails because the current story **deliberately changes** that earlier
     story's behaviour (compare against the current story's acceptance criteria), qa must NOT edit or delete
     the old test. State this explicitly in the bug description, or, if unclear whether the change is
     intended, `bd update --append-notes` + label `needs-human` (AC3). The old test's update is then a
     decision for the engineer/human, not silent qa work.
4. **Close message** when everything passes: the handoff comment says "N scripts ran, 0 failed" with N
   the real count (AC4).
5. **Quota story**: usage-limit test from agent-factory-stg (`tests/agent-factory-stg_test.sh` once
   merged) is picked up automatically by the enumeration. If the story touches quota/usage-limit
   handling (`bin/agent-loop.sh` limit/reset code) and that script is absent from `tests/`, that is
   itself a defect/needs-human (AC5); a failure of it is filed as a regression naming the
   usage-limit wait-for-reset behaviour.

Existing rework-cap rule (step 4: >=2 rework issues -> needs-human) still applies to regression bugs.

## Files
- change: `agents/qa.md` (stage:verify only)
- change: `docs/ARCHITECTURE.md` Test strategy: one bullet stating verify runs every script under `tests/`
  (both layouts) and that new stories should use `tests/<story-id>_test.sh`.
- no other files.

## Acceptance criteria mapping
AC1 steps 1-2; AC2/AC3 step 3; AC4 step 4; AC5 step 5.

## Test strategy (QA)
Content checks on `agents/qa.md` with grep against the stage:verify section: mentions running all scripts
under `tests/` incl. `tests/acceptance`; per-script pass/fail recorded; regression bug with
`role:engineer,stage:rework`, names script + protected behaviour, not closing verify; deliberate-change case
requires explicit statement/needs-human and forbids editing/deleting old tests; "N scripts ran, none failed"
wording; usage-limit test mention; stage:tests and stage:rework sections byte-identical to main. Also run the
documented `find` command and assert it lists all 9 current scripts. Behavioural check is not automatable.

## Note on branch name
`story/<id>/design` cannot exist in git while `story/<id>` exists (ref path clash), so this design is on
`story/agent-factory-vzt-design` (precedent: `story/agent-factory-stg-design`). Engineer merges that branch.
