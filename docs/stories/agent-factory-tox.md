# agent-factory-tox: Track branches must not nest under the story branch name

## Story
As an agent-factory operator, I want the per-track branches to be named `story/<id>-design` and
`story/<id>-tests` instead of `story/<id>/design` and `story/<id>/tests`, so that agents can
actually create them and the parallel-tracks flow works.

## Context
Git stores branch refs as files, so `story/<id>` (a branch) and `story/<id>/design` (which needs
`story/<id>` to be a directory) cannot coexist; creating the track branch fails once the story
branch exists. The parallel design/write-tests story (agent-factory-icv) introduced the nested
names in the role prompts (`agents/*.md`), README "Flow", `docs/design/agent-factory-icv.md`, and
the acceptance test `tests/agent-factory-icv_test.sh`. Any other place naming a track branch is
affected too. Requested rename: `story/<id>-design`, `story/<id>-tests`.

## Acceptance criteria
1. Given the architect (design) and engineer (implement) role prompts, when they tell the agent
   which branch holds the design track, then the name is `story/<story-id>-design` and no prompt
   contains `story/<story-id>/design`.
2. Given the qa role prompt for write-tests, when it tells the agent which branch to commit tests
   on, then the name is `story/<story-id>-tests` and no prompt contains `story/<story-id>/tests`.
3. Given a story branch `story/X` already exists locally or on origin, when an agent follows the
   prompts to create `story/X-design` and `story/X-tests` from it and push them, then both
   creations and pushes succeed.
4. Given the engineer finishing implement and qa starting verify, when each follows its prompt to
   merge its track into `story/<story-id>`, then the merge commands reference the hyphenated
   branch names and the merge behaviour is otherwise unchanged.
5. Given README and current docs (README "Flow", `docs/ARCHITECTURE.md` if it mentions tracks),
   when read, then they use the hyphenated names only.
6. Given the existing acceptance test for parallel tracks, when run, then it asserts the
   hyphenated names and passes.

## Out of scope
- Any change to the chain shape, dependencies, rework routing or merge semantics.
- Rewriting historical design docs' rationale beyond the branch names.
- Cleaning up any nested-name branches that already exist on origin.
