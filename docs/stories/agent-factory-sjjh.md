# agent-factory-sjjh: Always route stories through the default chain (remove needs-chain)

## Story
As the human operating the factory, I want every story to flow through one fixed stage chain with no
team-lead sizing step, so that routing is predictable, there is one less handoff and decision point to
go wrong, and no story silently loses design or tests.

## Context
- Today po files a `role:team-lead,needs-chain` issue after writing the story; team-lead (or the System 1
  model, `bin/system1.sh`) then decides whether to skip design and/or write-tests and builds the chain with
  `bin/new-story.sh`, optionally with `--skip-design` / `--skip-tests` (which add `no-design` / `no-tests`
  labels and alternate descriptions that engineer/qa/architect/reviewer prompts must handle).
- Requester decision: remove this. Every story always gets the default chain: po writes the story, then
  architect (design) -> engineer (implement) -> qa (execute/verify tests) -> reviewer (review), with qa
  (write tests) running in parallel to the design track. This is exactly the five-stage fork/join graph
  `new-story.sh` already builds when no skip flags are passed.
- `HUMAN_APPROVE_STORIES` gating of the design issue is unrelated and keeps working.

## Acceptance criteria
1. Given po has written and pushed `docs/stories/<id>.md`, when po finishes its session, then the story's
   design, write-tests, implement, verify and review issues all exist (with the same labels, dependencies
   and parallel design/tests tracks as today's full chain) and no issue carrying `needs-chain` was created
   for it.
2. Given any story, when its chain is built, then it always contains all five stages: no `--skip-design` /
   `--skip-tests` option exists, and no issue in the chain carries `no-design` or `no-tests`.
3. Given team-lead (either the capable-model session or System 1 mode) polls the board, when it looks for
   work, then it never treats an issue as a "size the chain" task: `needs-chain` is no longer a recognised
   label for polling, selection, throttle capacity counting or System 1 decision kinds.
4. Given `HUMAN_APPROVE_STORIES=1`, when the chain is built, then the design issue is still gated behind
   `needs-human` exactly as today.
5. Given the role prompts, README and `docs/ARCHITECTURE.md`, when read, then none describes chain sizing,
   `needs-chain`, skipped stages, or `no-design`/`no-tests` handling as part of the current workflow.
6. Given the existing test suite, when run, then tests that asserted the sizing behaviour are removed or
   rewritten to the new behaviour and the whole suite passes.

## Out of scope
- Any change to the stages themselves, their order, or the parallel design/write-tests tracks.
- Changing team-lead's routing of unrouted / `needs-team-lead` issues or the po/architect throttle.
- Migrating stories already in flight with `needs-chain`, `no-design` or `no-tests` issues (the architect
  may decide whether a minimal tolerance is cheaper than a cleanup; not required by this story).
