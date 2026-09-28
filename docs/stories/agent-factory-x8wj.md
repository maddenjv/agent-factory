# agent-factory-x8wj: Team-lead sizes each story's stage chain to its complexity

## Story
As the agent-factory system, I want team-lead to decide, for every new story, which of the five
stages (design, write-tests, implement, verify, review) that story's chain actually needs, so that
simple work moves through fewer stages while complex work still gets full design/tests/verify
rigor - instead of every story automatically paying for the same fixed five-stage chain regardless
of size.

## Context
Today `bin/new-story.sh` (run by po immediately after writing `docs/stories/<id>.md`, per
`agents/po.md` step 6) always creates the same fixed chain: design (architect) and write-tests
(qa) in parallel, each feeding implement (engineer) and verify (qa), then review (reviewer) - see
`docs/ARCHITECTURE.md`'s "Getting work to main". There is no judgment call about whether design or
write-tests are actually needed for a given piece of work; every story pays for the full chain.

`team-lead` ([agents/team-lead.md](../../agents/team-lead.md)) is a distinct sixth role, but today
it is purely reactive: it only ever looks at issues already stuck (`needs-team-lead`, from
`agent-factory-dx0`) or unrouted (no `role:*` label at all, from `agent-factory-m7af`). It has no
part in shaping a story's chain when the story is first created. This story gives team-lead that
job: for every new story, before any of its stage issues becomes available to a role's queue,
team-lead reviews the story and decides which stages the chain actually needs. There is
deliberately no fixed rubric for "simple" vs "complex" here - team-lead uses judgment, and errs
toward including a stage whenever it's unsure, since missing design or tests on work that turns
out to be complex costs far more than running an unnecessary stage on work that turns out to be
simple. Write-tests specifically is expected to be skipped only when existing tests already cover
the behavior being changed - not as a general default.

This is a distinct mechanism from the existing storyless-fix path (`fix/<issue-id>`, see
CLAUDE.md's "Storyless fix work"): that path remains, unchanged, for small, fully-scoped
`discovered-from` follow-ups with no `docs/stories/` entry at all. This story is about the shape
of the chain for a genuine story that does get a `docs/stories/<id>.md`.

## Acceptance criteria

1. **Given** a po has written a new story's `docs/stories/<id>.md` and pushed its `story/<id>`
   branch, **when** that story's stage chain is set up, **then** team-lead - not po, and not a
   fixed default applied automatically - decides which of the five stages (design, write-tests,
   implement, verify, review) the chain includes, before any of that story's stage issues is
   ready for its role's queue.

2. **Given** team-lead is deciding a story's chain and judges the work complex, unclear in scope,
   or is simply unsure, **when** it decides, **then** it includes design and write-tests rather
   than skipping them - favoring inclusion whenever in doubt.

3. **Given** a story where existing tests already cover the behavior being changed, **when**
   team-lead decides the chain, **then** it may skip the write-tests stage - this is the only
   basis, within this story, for skipping write-tests.

4. **Given** a story judged simple enough that team-lead skips the design stage, **when** the
   chain is built, **then** implement proceeds without waiting on a design issue or on
   `docs/design/<id>.md` - there is no dependency left pointing at a stage that was never created.

5. **Given** any story's chain, regardless of which stages team-lead chose to skip, **then**
   implement, verify, and review are always present - this story never omits implementation,
   never omits verify, and never omits review.

6. **Given** team-lead has decided a story's chain, **when** any role or a human later reads that
   story's issues (`bd show`/`bd comments`), **then** the decision - which stages were included or
   skipped, and why - is recorded there, so it doesn't need to be re-derived from scratch.

7. **Given** a story team-lead judges fully complex, **when** its chain is built, **then** it ends
   up with exactly the same five-stage chain (design and write-tests in parallel, each feeding
   implement and verify, then review) that every story gets today - this story changes nothing
   about the chain for work that genuinely needs every stage.

## Out of scope
- A formal or numeric rubric for "simple" vs "complex" - deliberately a per-story judgment call
  for team-lead, with no fixed criteria.
- Any change to the storyless-fix path (`fix/<issue-id>`) - it remains a separate, unaffected
  mechanism for small, fully-scoped follow-ups.
- Any change to team-lead's existing `needs-team-lead` triage (`agent-factory-dx0`) or
  no-`role:*`-label sweep (`agent-factory-m7af`) - this story adds a new responsibility for
  team-lead, it does not change those existing ones.
- Introducing new stage types, or changing which five roles exist.
- Skipping verify or review under any circumstance.
