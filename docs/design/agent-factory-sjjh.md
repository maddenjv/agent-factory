# Design: agent-factory-sjjh - always the default chain (remove `needs-chain`)

## Approach
Delete the sizing step rather than hiding it. `bin/new-story.sh` already builds the full five-stage
fork/join graph when given no flags; after this story that is its only behaviour, and **po calls it
directly** at the end of its session (as it did before `agent-factory-x8wj`). The `needs-chain`
label, the `role:team-lead,needs-chain` issue, team-lead's "Size a new story's chain" section,
System 1's `chain` decision kind, and every `no-design` / `no-tests` special case in the role prompts
go away. No new mechanism is introduced.

In-flight legacy issues (`needs-chain`, `no-design`, `no-tests`) are **not migrated and not tolerated
in code** (cheaper than a cleanup; story says not required). Consequence to document in the
handoff comment: a leftover `role:team-lead,needs-chain` issue is no longer polled (it has a `role:`
label, so the no-role sweep skips it too) and must be closed by hand; leftover `no-design`/`no-tests`
implement/verify issues still carry self-contained descriptions, so they remain workable by the
agents following the description, which is already authoritative for `restarted` issues too.

## Changes by file

### `bin/new-story.sh`
- Usage becomes `new-story.sh <story-id> "<short title>"`. Remove the flag loop, `skip_design`,
  `skip_tests`, `impl_suffix`, `verify_suffix`, the alternate `impl_desc`/`verify_desc`, and the
  `[ -n "$d" ]` / `[ -n "$t" ]` conditionals (design and tests always exist).
- Any extra argument (including the old `--skip-design`/`--skip-tests`) -> `echo "new-story.sh: unexpected argument '$arg'" >&2; exit 1` before any `bd` call. (AC2: no such option exists.)
- `gate=",needs-human"` iff `HUMAN_APPROVE_STORIES=1`, with the same `--append-notes` explanation on the design issue (AC4, unchanged).
- Final echo: `story $sid: design=$d tests=$t implement=$i verify=$v review=$r`.
- Header comment: no mention of team-lead or sizing; called by po (agents/po.md step 6).
- Labels/deps unchanged: implement dep design; verify dep implement and tests; review dep verify.

### `agents/po.md` step 6
Replace the chain-sizing issue with:
1. Idempotency guard (a crashed/restarted session must not duplicate the chain):
   `bd list --label story:$id --all --json` - if any issue with a `stage:` label already exists, skip to step 7.
2. `bin/new-story.sh $id "<short title>"`; if it exits non-zero, follow the blocked path
   (`--append-notes` + `needs-team-lead`) and stop.
3. Step 7's `bd comment` includes the script's one-line output (the new issue ids).
Also drop "do not run new-story.sh yourself" wording.

### `agents/team-lead.md`
- Intro: remove "decide a new story's stage chain", "size the chain", the `needs-chain` kind; the
  poll now runs one of **three** kinds (needs-team-lead, no-role sweep, no-issue throttle). Remove
  "if it carries `needs-chain`, skip to ..." sentence. Remove the whole "## Size a new story's chain" section.
- Throttle section: delete the "stories that only have a `needs-chain` issue ... not built yet" bullet text
  (and the sentence about "judgment call as sizing a story's stage chain" - reword to "a judgment call").
- Keep note about SYSTEM1 but drop "chain sizing".

### `bin/agent-loop.sh`
- team-lead `next_issue`: the select condition becomes
  `((no role: label)) and (assignee empty or me)` - drop the `or index("needs-chain")` arm (line ~144).
- Role `next_issue`: drop `or index("needs-chain") != null` from the exclusion (line ~165).
- `claim()`: drop `&& ! has_label "$id" needs-chain` (line ~193).
- Grep `needs-chain` in the file must return nothing.

### `bin/system1.sh`
- Delete `chain)` in `system_prompt`, the `chain` branch in `user_prompt` (keep the non-intake else-branch body; drop the `[ "$KIND" = chain ]` split and the "Existing test files" listing), `do_chain`, the `chain)` case in `main`, and `if has_label needs-chain; then KIND=chain` in `classify` (first `elif` becomes `if`).
- `direct_build` is unchanged (already calls `new-story.sh` without flags).
- Header/`.env.example` comment (line 49): "routing / no-story-intake decisions".

### `agents/engineer.md`
Remove every `no-design` mention (step 0, step 1, "Before closing"); keep `restarted` handling. Step 1 no
longer says the design "if it exists" nor that write-tests may have been skipped: design doc and QA tests always exist.

### `agents/qa.md` (verify stage)
Remove the `no-tests` paragraphs: always merge `story/<story-id>-tests`. Keep the rest.

### `agents/architect.md` (rework)
Drop the "if it doesn't exist - the chain originally skipped the design stage (`needs-chain`...)" branch and the "write it from scratch if it didn't exist" clause; `story/<story-id>-design` always exists.

### `agents/reviewer.md`
Replace "if this story's chain included a design stage (some stories skip it ...)" with an unconditional
conformance-with-`docs/design/<story-id>.md` bullet.

### Docs
- `docs/ARCHITECTURE.md`: team-lead paragraph (lines ~10-40): remove the `x8wj` needs-chain entry point,
  "find all three" -> "both" (needs-team-lead + no-role), `needs-chain` in the zf0i exclusion list, "sizes a new story's chain", the q4tj "(including stories that only have a `needs-chain` issue open)" parenthetical, and "size a `needs-chain` story" in the System 1 paragraph. "Getting work to main": story path is always design -> tests -> implement -> verify -> review; po runs `bin/new-story.sh`; delete the skip sentence.
- `README.md`: Flow step 2 (po writes story and runs `new-story.sh`, always the full fork/join chain; delete the "Simple stories can skip" sentences), System 1 paragraph (~line 125), the table row (~line 153: drop "and every new story's `needs-chain` sizing request").
- `CLAUDE.md` / `AGENTS.md` / `agents/CLAUDE.project.md`: only mention `bin/new-story.sh` as the branch-cutter; no change required.
- Do **not** edit historical `docs/design/*` or `docs/stories/*` of other stories.

## Error cases
- `new-story.sh` with unknown/legacy flag: exit 1, nothing created.
- po crash after `new-story.sh` but before closing: rerun hits the idempotency guard, no duplicate chain.
- `new-story.sh` fails halfway: po escalates via `needs-team-lead` with the error in `--append-notes` (a partial chain is a human/team-lead cleanup; same exposure as before).

## Acceptance criteria mapping
1. po runs `new-story.sh`, five stage issues, no `needs-chain` issue created anywhere (po.md, system1 `direct_build`).
2. `new-story.sh` rejects flags; no `no-design`/`no-tests` label strings remain in the script.
3. `needs-chain` absent from agent-loop.sh polling/selection/claim exclusion, throttle prose and System 1 kinds.
4. Gate logic kept verbatim.
5. Prompt/doc edits above; final repo-wide `grep -rn "needs-chain\|no-design\|no-tests\|skip-design\|skip-tests"` over `agents/ bin/ README.md docs/ARCHITECTURE.md .env.example` must be empty.
6. Test updates below.

## Test strategy (QA)
Existing tests asserting sizing must be removed or rewritten (they will fail otherwise):
- `tests/agent-factory-x8wj_test.sh`: delete whole file (all of it tests sizing/skip flags/needs-chain wiring). Its useful cases are re-created in the new test (full chain, dependencies).
- `tests/agent-factory-73cw_test.sh`: remove the `chain` fixtures/cases (`CHAIN_*`, `test_ac3_chain_*`, `chain.json` loop entries at lines ~162, 212, 313-,  399); keep route/intake/direct cases.
- `tests/agent-factory-q4tj_test.sh`: drop `test_ac5_needs_chain_only_story_counts_as_occupying_capacity` (and header mention).
- `tests/agent-factory-zf0i_test.sh` line ~130: loop over `needs-team-lead needs-human` only.
- `tests/agent-factory-ab62_test.sh` line ~117: reword the comment/fixture so it no longer uses a needs-chain sizing issue as the example (use a needs-team-lead issue).
- `tests/agent-factory-r7m5_test.sh`: check for flagged lines and adjust the same way.
New `tests/agent-factory-sjjh_test.sh` (stubbed `bd`, like the x8wj/73cw harnesses):
- AC1/AC2: `new-story.sh s "T"` creates exactly design/tests/implement/verify/review with correct roles, `story:` labels, and deps (implement->design, verify->implement+tests, review->verify); `--skip-design`, `--skip-tests`, any extra arg -> exit non-zero and zero `bd create`; no created label equals `no-design`/`no-tests`/`needs-chain`.
- AC4: `HUMAN_APPROVE_STORIES=1` -> design issue has `needs-human`; unset -> not.
- AC1 prompt-level: `agents/po.md` mentions `bin/new-story.sh` and not `needs-chain`.
- AC3: `grep -c needs-chain bin/agent-loop.sh bin/system1.sh` = 0; stubbed team-lead `next_issue` ignores an issue labelled `role:team-lead,needs-chain` (has a role label, so not picked); system1 has no `do_chain`.
- AC5: repo-wide grep (command above) empty.
- AC6: whole suite passes.
