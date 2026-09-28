# Design: agent-factory-x8wj - team-lead sizes each story's stage chain

## Context
Today `bin/new-story.sh`, run by po immediately after writing `docs/stories/<id>.md`
(`agents/po.md` step 6), always creates the same fixed five-stage chain - design and write-tests
in parallel, each feeding implement and verify, then review. There is no judgment call anywhere:
every story pays for the full chain regardless of size.

This story moves that judgment call to `team-lead`. `team-lead` already has two entry points
(`agent-factory-dx0`'s `needs-team-lead` triage, `agent-factory-m7af`'s no-`role:*`-label sweep),
both reactive: something has to already be stuck or unrouted. This story adds a third, proactive
entry point that fires for *every* new story, before any of its stage issues exist: team-lead
reads the story, decides which stages it needs, and is the one that actually builds the chain
(`bin/new-story.sh`). po no longer calls `new-story.sh` itself - it files a sizing request instead.

Deliberately reuses `agent-factory-dx0`/`m7af`'s mechanics (a label `next_issue()` in
`bin/agent-loop.sh` polls for, one investigate-decide-record-close cycle, `needs-human` for
genuine escalation) rather than inventing a new coordination primitive. The new label,
`needs-chain`, is a team-lead flag in the same family as `needs-team-lead`/`needs-human` - it is
**not** a sixth pipeline stage (the story's own "Out of scope" excludes introducing stage types),
which is why it carries no `stage:` label and sits outside the design/tests/implement/verify/review
vocabulary entirely.

Two tracks that don't need a new design decision to skip are called out explicitly so a reader
doesn't have to infer them from the mechanism: write-tests may be skipped only when existing tests
already cover the changed behaviour (AC3); design may be skipped only for work simple enough that
an engineer needs no further design decisions (AC2's "favor inclusion" default otherwise).
Everything downstream of chain-shape (engineer, qa, reviewer, and my own rework flow) has to keep
working correctly when a track is missing - that ripples into five of the six role prompts, not
just the chain-building script.

## Approach

### 1. `bin/new-story.sh` - the chain builder learns to omit a track
Two new optional flags, `--skip-design` and `--skip-tests`, added after the existing two
positionals; called with neither is byte-for-byte the same chain as today (AC7), which is exactly
what `tests/agent-factory-icv_test.sh`'s `run_new_story` (calls it with exactly two args) already
depends on - untouched by this change.

Full new file:
```bash
#!/usr/bin/env bash
# Usage: new-story.sh <story-id> "<short title>" [--skip-design] [--skip-tests]
# Creates the stage graph for a story (fork/join), sized by team-lead's decision:
#   design(architect) -> implement(engineer) --\
#                                               +-> verify(qa) -> review(reviewer)
#   tests(qa) ----------------------------------/
# design and tests have no dependency on each other and run in parallel. Either track can be
# omitted (--skip-design / --skip-tests) - implement/verify simply lose the corresponding
# dependency and get different description text; implement, verify and review always exist.
# <story-id> is the PO's feature-request issue id; it names the branch story/<id>. Called by
# team-lead after it decides the chain (agents/team-lead.md's "Size a new story's chain"), not by
# po directly - see agents/po.md step 6.
set -euo pipefail
sid=${1:?usage: new-story.sh <story-id> "<title>" [--skip-design] [--skip-tests]}
title=${2:?usage: new-story.sh <story-id> "<title>" [--skip-design] [--skip-tests]}
shift 2
skip_design=0; skip_tests=0
for arg in "$@"; do
  case "$arg" in
    --skip-design) skip_design=1 ;;
    --skip-tests)  skip_tests=1 ;;
    *) echo "new-story.sh: unknown flag '$arg'" >&2; exit 1 ;;
  esac
done
gate=""; [ "$skip_design" = 0 ] && [ "${HUMAN_APPROVE_STORIES:-0}" = 1 ] && gate=",needs-human"

mk() {  # role stage suffix-labels description
  bd create "$sid: $title [$2]" -t task -p 2 -l "role:$1,stage:$2,story:$sid$3" -d "$4" --json \
    | jq -r 'if type=="array" then .[0].id else .id end'
}
ctx="Story: docs/stories/$sid.md. Branch: story/$sid. Conventions: CLAUDE.md."

d=""
if [ "$skip_design" = 0 ]; then
  d=$(mk architect design "$gate" "Design the implementation. $ctx")
  # HUMAN_APPROVE_STORIES=1 gates the design issue behind needs-human from creation - a deliberate
  # checkpoint, not an agent stuck partway through. It's never touched by the architect (next_issue
  # excludes needs-human issues), so nobody ever explains it via --append-notes the way a stuck
  # agent would - do it here instead, so `bd show` doesn't look identical to a real stuck-agent case.
  [ -n "$gate" ] && bd update "$d" --append-notes "Gated by HUMAN_APPROVE_STORIES=1 - a deliberate checkpoint, not a stuck agent. Review docs/stories/$sid.md, then run 'approve.sh $d' to let the architect start design." >/dev/null
fi

t=""
if [ "$skip_tests" = 0 ]; then
  t=$(mk qa tests "" "Write acceptance tests from the story's acceptance criteria only - do not read or depend on docs/design/$sid.md, which may not exist yet or may still be changing. $ctx")
fi

impl_desc="Implement per docs/design/$sid.md until the acceptance tests pass. $ctx"
impl_suffix=""
if [ "$skip_design" = 1 ]; then
  impl_suffix=",no-design"
  impl_desc="No design stage for this story - team-lead judged it simple enough to skip (see bd comments on the story's needs-chain issue for why). Check out story/$sid directly (git checkout story/$sid && git pull) - there is no story/$sid-design branch, so there is nothing to merge before closing. Implement per the acceptance criteria in docs/stories/$sid.md and docs/ARCHITECTURE.md, run the full suite, push story/$sid directly, then close as usual. $ctx"
fi
i=$(mk engineer implement "$impl_suffix" "$impl_desc")

verify_desc="Verify the implementation against every acceptance criterion; add edge-case tests. $ctx"
verify_suffix=""
if [ "$skip_tests" = 1 ]; then
  verify_suffix=",no-tests"
  verify_desc="No write-tests stage for this story - team-lead judged existing tests already cover this behaviour (see bd comments on the story's needs-chain issue for why). There is no story/$sid-tests branch to merge. Verify the implementation against every acceptance criterion directly and add tests for any gap you find. $ctx"
fi
v=$(mk qa verify "$verify_suffix" "$verify_desc")

r=$(mk reviewer review "" "Review code and tests; merge story/$sid to main if approved. $ctx")

[ -n "$d" ] && bd dep add "$i" "$d"   # implement depends on design, if there is one
bd dep add "$v" "$i"                  # verify depends on implement
[ -n "$t" ] && bd dep add "$v" "$t"   # ...and on write-tests, if there is one
bd dep add "$r" "$v"                  # review depends on verify

echo "story $sid: design=${d:-skipped} tests=${t:-skipped} implement=$i verify=$v review=$r"
[ -n "$gate" ] && echo "design issue $d is gated: run approve.sh $d to release it"
```
`no-design`/`no-tests` are plain issue labels (not a new label *category* like `needs-team-lead`) -
they exist purely so engineer/qa can detect "this track doesn't exist" mechanically instead of
parsing prose, mirroring how `restart-story.sh` (`agent-factory-x8d`) uses the `restarted` label
for the same purpose on the implement issue it creates.

This satisfies AC4 (`[ -n "$d" ] && bd dep add "$i" "$d"` - no dependency edge when design is
skipped, and the implement description never mentions `docs/design/$sid.md` in that branch), AC5
(implement/verify/review are unconditional `mk` calls - no code path skips them), and AC7 (neither
flag set reproduces today's five `mk` calls, wiring and echo output exactly, since the two `if`
blocks fall through to the original unconditional text and the two `[ -n ... ] &&` dependency lines
are no-ops when `d`/`t` are non-empty).

### 2. `agents/po.md` - stop calling `new-story.sh`; ask team-lead to size the chain instead
Step 6 replaced (step 7 unchanged, still the last step):
```markdown
6. Create team-lead's chain-sizing issue - do not run `new-story.sh` yourself; team-lead decides
   which stages the chain needs and builds it (see `agents/team-lead.md`'s "Size a new story's
   chain"):
   ```
   bd create "$id: Decide stage chain for <short title>" -t task -p 2 -l role:team-lead,needs-chain,story:$id \
     -d "Story: docs/stories/$id.md. Branch: story/$id. Decide which of the five stages (design, write-tests, implement, verify, review) this story's chain needs, then build it with bin/new-story.sh. See agents/team-lead.md's 'Size a new story's chain'. Conventions: CLAUDE.md."
   ```
7. `bd comment` a one-line summary, close your issue.
```
This satisfies AC1's "not po, and not a fixed default applied automatically": po no longer invokes
the chain-building script at all, in any form.

### 3. `bin/agent-loop.sh` - `next_issue()` grows a third team-lead-poll condition
One line added to the existing `select`, same shape as `agent-factory-m7af`'s own addition
(a third `or` clause, nothing else in the file touched):
```bash
next_issue() {
  if [ "$ROLE" = "team-lead" ]; then
    bd list --limit 200 --json 2>>"$LOGDIR/bd-err.log" | jq -r --arg me "$AGENT_ID" '
      [ .[]?
        | select(.status != "closed")
        | select(((.labels // []) | index("needs-human")) | not)
        | select(((.assignee // "") == "") or (.assignee == $me))
        | select( ((.labels // []) | index("needs-team-lead"))
                  or (((.labels // []) | any(startswith("role:"))) | not)
                  or ((.labels // []) | index("needs-chain")) ) ]
      | .[0].id // empty' 2>/dev/null
    return
  fi
  ...
```
(`...` = rest of the function, unchanged.) No other function needs a change: `handle_outcome()`'s
team-lead branch already fires on *any* issue that isn't `needs-team-lead` once closed (the
`st == closed` check above it returns first for a successfully-sized story, same as it does today
for a sweep-routed issue - verified by re-reading `agent-factory-m7af`'s design, which established
exactly this "no `handle_outcome` change needed" reasoning for its own new poll condition), and the
existing `needs-human` escalation backstop (the `for esc in needs-human needs-team-lead` loop)
already covers a needs-chain issue team-lead escalates directly to `needs-human` without touching
`needs-team-lead` at all. This satisfies AC1 (the poll condition; issues aren't created until
team-lead runs `new-story.sh` in step 4 below, so nothing can be ready before that).

### 4. `agents/team-lead.md` - intro update + new "Size a new story's chain" section
Intro paragraph (the one describing the two entry points) replaced to describe three:
```markdown
Your job is triage, not implementation: diagnose why a piece of work is stuck, decide a new
story's stage chain, or find where an unrouted issue belongs, and either correct its routing, size
the chain, or hand it to a human - you never write story/design/code/test content yourself. Unlike
the other five roles, you have no ongoing `role:team-lead` work queue in the usual sense; you're
given (as "Your assigned issue" below) one of three kinds of issue, all surfaced by
`agent-loop.sh`'s team-lead poll: an issue that belongs to some *other* role's stage, already
labelled `needs-team-lead`, keeping whatever `role:`/`stage:` labels it also carries; a new
story's `role:team-lead,needs-chain` issue, created by po right after it writes
`docs/stories/<story-id>.md`, asking you to decide which stages that story's chain needs; or an
issue with no `role:*` label at all (and not `needs-human`), found by sweeping the board for work
that never got routed anywhere. `bd show <your-issue>` first: if it carries `needs-chain`, skip to
"Size a new story's chain" below instead of steps 1-5; if it carries `needs-team-lead`, follow
steps 1-5 below unchanged; if it carries no `role:*` label, skip to "Sweep: issues with no
`role:*` label" at the end of this file instead.
```
Steps 1-5 and the existing "Sweep" section: **unchanged**, byte-for-byte (out of scope per the
story: no change to either existing entry point's logic).

New section, inserted after step 5 and before "## Sweep: issues with no `role:*` label":
```markdown
## Size a new story's chain

Triggered by an issue labelled `role:team-lead,needs-chain` (one per story, no `stage:` label -
this is not one of the five chain stages), created by po immediately after it writes
`docs/stories/<story-id>.md` and pushes `story/<story-id>`. Before you decide, none of that
story's design/write-tests/implement/verify/review issues exist yet - there is nothing yet for any
other role's queue to pick up.

1. `git fetch origin && git checkout story/<story-id> && git pull`, then read
   `docs/stories/<story-id>.md` in full.
2. Decide which of the five stages this story's chain needs. There is no fixed rubric for "simple"
   vs "complex" - use judgment, and favor including a stage whenever you're unsure: missing design
   or tests on work that turns out to be complex costs far more than running an unnecessary stage
   on work that turns out to be simple.
   - **write-tests**: skip it ONLY when existing tests already cover the behaviour this story
     changes - check `tests/` yourself, don't guess. Any other reason to hesitate means keep it.
   - **design**: skip it only for work simple enough that an engineer needs no further design
     decisions to implement it correctly - e.g. a small, self-contained change with an obvious
     approach. If the story is complex, unclear in scope, or you're simply unsure, keep it.
   - implement, verify and review are never skipped.
3. Build the chain: `bin/new-story.sh <story-id> "<short title>" [--skip-design] [--skip-tests]`
   (use the same short title po used when filing this issue; omit both flags for a fully complex
   story - this produces exactly the five-stage chain every story got before this section existed).
4. `bd comment <your-issue> "<which stages you included or skipped, and why>"` - specific enough
   that nobody needs to re-derive the decision later from `bd show`/`bd comments` alone - then
   close your issue.

If the story itself is too ambiguous to size at all (not just complex - genuinely unclear what's
being asked, not something more reading can resolve): `bd update <your-issue> --append-notes
"<exactly what's unclear>"`, then `bd label add <your-issue> needs-human` and stop, without
building a chain or closing - same as step 4's escalation, direct to `needs-human` since there is
nothing upstream of team-lead to triage this further.
```
This satisfies AC1 (steps 1-2 happen before step 3 ever creates an issue), AC2 (step 2's explicit
favor-inclusion framing, both bullets), AC3 (write-tests bullet: existing coverage is the *only*
named basis to skip it), AC4/AC5 (delegated to `new-story.sh`'s own guarantees, section 1), AC6
(step 4's `bd comment`, explicitly required to be self-sufficient), AC7 (step 3's "omit both flags"
note).

### 5. `agents/engineer.md` - `no-design` track
`stage:implement` steps 0, 1 and the "Before closing" line:
```markdown
0. If your issue has label `restarted` or `no-design`, follow the branch/checkout steps in its
   description instead of step 0 and the "Before closing" merge (the description is authoritative -
   a `no-design` issue means this story's chain skipped the design stage, so there is no
   `story/<story-id>-design` branch to check out or merge).
   Otherwise check out `story/<story-id>-design` and pull (the architect pushed the design there).
1. Read `docs/stories/<story-id>.md`; `docs/design/<story-id>.md` if it exists (a `no-design`
   issue won't have one - implement from the story's acceptance criteria and
   `docs/ARCHITECTURE.md` instead); `docs/ARCHITECTURE.md`; and the acceptance tests QA already
   committed, if any (this story's chain may have skipped write-tests because existing tests
   already cover the behaviour - if so, none show up here; check `tests/` yourself).
```
(steps 2-4 unchanged.)
```markdown
Before closing (skip the merge below if your issue has label `restarted` or `no-design` - follow
its description instead): `git checkout story/<story-id> && git pull && git merge story/<story-id>-design --no-ff -m "[<your-issue>] Merge design"`, re-run the full suite on the merged
result, then `git push origin story/<story-id>`.
```
`stage:rework` section: unchanged (a rework issue that names `story/<story-id>-design` only exists
once the architect has created that branch - see section 8 below, which covers the case where it
didn't exist yet). Satisfies AC4: a `no-design` implement issue's own description is a complete,
self-contained set of instructions (checkout, implement, push - no merge step at all), so nothing
in the engineer's flow ever references a design issue or `docs/design/<story-id>.md` that doesn't
exist.

### 6. `agents/qa.md` - `no-tests` track
`stage:verify` step 1 only (step 1a onward, and `stage:tests`/`stage:rework`, unchanged):
```markdown
1. Check out `story/<story-id>` and pull (the design track, if this story's chain included one, is
   already merged in). If your issue has label `no-tests`, there is no `story/<story-id>-tests`
   branch - skip the merge below (existing tests were judged to already cover this behaviour;
   confirm that for yourself as you verify). Otherwise merge your write-tests work: `git merge story/<story-id>-tests --no-ff -m "[<your-issue>] Merge tests"`, push
   `story/<story-id>`. Run the full accumulated suite on this merged result (see step 1a). Then exercise the behaviour for real where possible (run the CLI/service, call the
   endpoint) and walk every acceptance criterion; add edge-case and negative tests you think are
   missing - this matters even more when `no-tests` skipped write-tests, since your own tests here
   may be the first ones pinning down this behaviour.
```
Satisfies AC3's other half: verify (never skipped, AC5) is exactly where "existing tests already
cover this behaviour" gets confirmed for real, and where gaps get filled if that judgment turns out
to be wrong - the story never leaves a `no-tests` story permanently untested, it just moves the
first real test-writing to verify instead of a dedicated write-tests stage.

### 7. `agents/reviewer.md` - conformance check becomes conditional
The bullet list under "Review the diff against main":
```markdown
- correctness against every acceptance criterion in `docs/stories/<story-id>.md`
- conformance with `docs/design/<story-id>.md`, if this story's chain included a design stage
  (some stories skip it - `bd list --label story:<story-id> --all` shows the `needs-chain` issue
  team-lead decided it on, and why, if `docs/design/<story-id>.md` doesn't exist), and
  `docs/ARCHITECTURE.md`
```
(remaining bullets, and everything else in the file, unchanged.) Without this, a reviewer reading
the checklist literally could read a missing `docs/design/<story-id>.md` as itself a defect on a
story that deliberately never had one.

### 8. `agents/architect.md` - rework when a design never existed
`stage:rework`'s opening sentence, replacing only the first two sentences:
```markdown
**stage:rework** (the reviewer found a design defect)
Reuse the existing `story/<story-id>-design` (do not recreate it) if it exists; pull
`story/<story-id>` into it first so you start from the latest code. If it doesn't exist - this
story's chain originally skipped the design stage (`needs-chain`, decided by team-lead) and the
reviewer has now found a defect serious enough to need one after all - create it fresh from
`story/<story-id>` instead, the same as a first-time `stage:design` branch. Fix
`docs/design/<story-id>.md` (and ARCHITECTURE.md if the mistake was there; write it from scratch
if it didn't exist), commit, push `story/<story-id>-design`. This always requires
re-implementation, so before closing:
```
(the four numbered steps that follow are unchanged - they already just say "re-implement against
the corrected `docs/design/<story-id>.md`", which now unconditionally exists either way once this
sentence has run). This is the one place a `no-design` story's missing design branch would
otherwise break an *existing* flow (reviewer routing a design-level finding to architect rework)
that this story doesn't otherwise touch.

### 9. `docs/ARCHITECTURE.md` / `README.md` - kept current, done directly in this commit
Same as `agent-factory-dx0`/`m7af`'s own design sessions: these are the architect's own files, and
the edits are small enough to make now. Done as part of this design commit (see the diff), not
left as an instruction for the engineer:
- `docs/ARCHITECTURE.md`'s team-lead paragraph: adds the `needs-chain` entry point, and - noticed
  while editing this exact paragraph - corrects two lines that have been stale since
  `agent-factory-250` and `agent-factory-uhc` landed (team-lead already has a non-default model
  tier and a tmux pane; the paragraph still said neither did).
- `README.md`'s Flow step 2 and mermaid-adjacent prose: po now files a sizing request, not a
  chain, and team-lead builds it. The "Day to day" table's team-lead row gets the same
  `agent-factory-250`/`uhc` staleness fix plus a one-line mention of the new automatic entry point.

## Error cases
- **A story sits between po closing and team-lead sizing it.** By design (AC1): no stage issue
  exists yet, so nothing is ready and nothing is lost - just later than today. Team-lead's poll
  (section 3) picks up `needs-chain` issues the same idle-loop cadence it already uses for its
  other two entry points; no new timeout/retry logic needed.
- **`new-story.sh` called twice for the same story** (e.g. a crashed team-lead session gets
  retried): out of scope for this story to guard against - `bin/new-story.sh` was never
  idempotent (a second run duplicates the whole chain) and this story doesn't change that. The
  existing safety net is unchanged: `agent-loop.sh`'s attempt cap only escalates a
  crashed-mid-session `needs-chain` issue to `needs-human` after `MAX_ATTEMPTS_PER_ISSUE` (default
  2) retries, and a human decides from there - the same guard every other role's scripted-mutation
  step (`restart-story.sh`, `feature.sh`) already relies on.
- **po's `wip_ok()`/`idle_downstream_role()` throttle** (`bin/agent-loop.sh`) counts a story as
  "in flight" once it has a `role:reviewer` issue, and counts a downstream role as "idle" if it has
  no ready/in-progress issue. A story waiting on `needs-chain` has neither yet, so it briefly
  doesn't count toward either check - po could in theory start one more concurrent story than
  `WIP_LIMIT` intends during that window. Real, but narrow (one team-lead poll cycle) and outside
  this story's acceptance criteria (all of which are about chain *shape*, not WIP accounting) -
  filed as a discovered-from follow-up (`agent-factory-x8wj` -> new issue) rather than folded in
  here, since fixing it properly means redefining what "in flight"/"idle" mean, which is its own
  design decision.
- **A story escalated via `needs-chain` -> `needs-human` (too ambiguous to size) gets approved.**
  `approve.sh` only removes `needs-human`; the issue reopens with `needs-chain` still on it (never
  removed), so it flows back through team-lead's same entry point once a human's note answers the
  ambiguity - no special-casing needed, this is the same pattern `agent-factory-dx0` already
  established for `needs-team-lead` issues that reopen after a human answer.

## Acceptance criteria mapping
1 -> sections 2-4 (po stops building the chain; team-lead's new entry point decides before any
stage issue exists). 2 -> section 4 step 2 (favor-inclusion framing). 3 -> section 4 step 2's
write-tests bullet (existing coverage is the only named basis). 4 -> section 1 (`no-design`
dependency/description) + section 5 (engineer never looks for a design that isn't there) + section
8 (rework doesn't break if design was never created). 5 -> section 1 (`mk` calls for implement/
verify/review are unconditional). 6 -> section 4 step 4 (`bd comment`, explicitly required to be
self-sufficient). 7 -> section 1 (no flags reproduces today's chain exactly) + section 4 step 3.

## Test strategy (QA)
New `tests/agent-factory-x8wj_test.sh`, one function per acceptance criterion, following
`tests/agent-factory-icv_test.sh`'s stub-`bd` technique for the graph-shape assertions (reuse its
stub verbatim rather than reinventing it) plus prose greps for the role-prompt changes:

- **AC7 (regression)**: `run_new_story` (icv's helper, called with exactly `smoke "smoke"`, no
  flags) still produces design+tests with no deps, implement depending only on design, verify
  depending on implement+tests, review depending only on verify - i.e. re-run
  `tests/agent-factory-icv_test.sh`'s own `test_ac1`/`test_ac3`/`test_ac4`/`test_ac5` bodies (or
  literally shell out to that script) against the new `new-story.sh` and confirm `failed=0`.
- **AC4/AC5 (`--skip-design`)**: run `new-story.sh smoke "smoke" --skip-design` against the same
  stub; assert no `create` line with `stage:design`; assert the `implement` issue's labels include
  `no-design` and its description contains neither `docs/design/` nor a dependency on a design
  issue; assert `deps_of "$I"` is empty; assert implement/verify/review are still created
  (`stage:implement`/`stage:verify`/`stage:review` all present) and their dependency shape
  (`verify` depends on `implement` [+`tests`], `review` depends on `verify`) is otherwise
  unchanged.
- **AC3/AC5 (`--skip-tests`)**: same shape, `--skip-tests`: no `stage:tests` issue created, `verify`
  issue carries `no-tests` and `deps_of "$V"` equals just `$I` (not `$I $T`), implement/verify/
  review still all present.
- **Both flags together**: no design, no tests, `deps_of "$I"` empty, `deps_of "$V"` equals `$I`,
  implement/verify/review present - confirms the two flags compose independently.
- **AC1 (poll wiring)**: grep `bin/agent-loop.sh`'s team-lead `next_issue()` branch for
  `needs-chain` inside the same `select` block that already has `needs-team-lead`; optionally,
  reuse `tests/agent-factory-dx0_test.sh`'s real-loop-with-stub-`bd`-and-stub-`claude` harness with
  a fixture issue carrying only `role:team-lead,needs-chain,story:x` (no `stage:`) and confirm it's
  claimed, mirroring that suite's existing per-label fixtures.
- **AC1 (po no longer builds the chain)**: grep `agents/po.md` step 6 - it must NOT contain
  `new-story.sh` and MUST contain `needs-chain`.
- **AC2/AC3/AC6 (team-lead prompt content)**: grep `agents/team-lead.md`'s new section for: "favor"
  or "favour" near "unsure"/"in doubt" (AC2); the write-tests bullet containing "existing tests"
  and "ONLY" or "only" (AC3's sole-basis wording); `bd comment` appearing before `close` in the
  happy path (AC6).
- **AC4/AC5 (engineer/qa prompt content)**: grep `agents/engineer.md` for `no-design` in both step
  0 and the "Before closing" line; grep `agents/qa.md`'s `stage:verify` section for `no-tests`.
- **Regression**: `tests/agent-factory-dx0_test.sh`, `tests/agent-factory-m7af_test.sh`,
  `tests/agent-factory-icv_test.sh`, `tests/agent-factory-x8d_test.sh` must all still report
  `failed=0` unmodified - verified during this design session by applying the exact text above to
  local (uncommitted, reverted) copies of `bin/agent-loop.sh`, `bin/new-story.sh`,
  `agents/*.md` and running all four: all passed, including `icv`'s `test_ac7`/`test_ac8` literal
  `git merge...story/<story-id>-design`/`-tests` greps (both lines are preserved verbatim, just
  wrapped in a new conditional sentence ahead of them).
- `shellcheck bin/new-story.sh bin/agent-loop.sh` on the diff.

## Out of scope
As the story states: a formal/numeric rubric for stage-skipping (team-lead's judgment call, by
design); any change to the storyless-fix path; any change to `needs-team-lead`/no-`role:*`-label
triage logic (both reused verbatim); new stage types or new roles (`needs-chain` is a team-lead
flag, not a stage - see Context); ever skipping verify or review. Also out of scope, noted above
as a real but narrow gap: `wip_ok()`/`idle_downstream_role()` not accounting for a story mid-sizing
(see Error cases) - left as a follow-up issue, not fixed here.
