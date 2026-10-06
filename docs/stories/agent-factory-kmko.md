# agent-factory-kmko: bin/init.sh succeeds on a machine with no git identity configured

## Story
As a new agent-factory user on a clean machine, I want `bin/init.sh` to complete without my having
to configure a global git identity first, so that setting up a test project is not derailed by a
"Author identity unknown" failure.

## Context
Reported: cloning agent-factory and running `bin/init.sh` in a new, clean project fails right after
the Dolt server (`factory-dolt`) is started, with git's "Author identity unknown / Please tell me who
you are" message. `bin/init.sh` ends by committing the scaffolding (stories/design dirs, `.gitignore`,
`.beads`, `CLAUDE.md`) to the project's `main` on the user's behalf (`bin/init-project.sh`); with no
`user.name` / `user.email` set in the user's git config, that commit aborts. Inside the agent
containers an identity is already set per role (`bin/agent-loop.sh`); the host-side init is the gap.
Init must not change the user's own git config, and must not override an identity they have set.

## Acceptance criteria
1. Given a clean git project on a machine with no git `user.name` or `user.email` configured at any
   level, when the user runs `bin/init.sh`, then it completes successfully (exit 0) and the
   scaffolding commit exists on `main`.
2. Given the scenario in 1, when init finishes, then the user's git configuration (global, system and
   the project's local config) is unchanged: no identity has been written to it.
3. Given a machine where the user has a git identity configured, when the user runs `bin/init.sh`,
   then the scaffolding commit is authored by that identity (not by a factory-default one).
4. Given only one of `user.name` / `user.email` is configured, when the user runs `bin/init.sh`, then
   it completes successfully.
5. Given `bin/init.sh` has already completed once, when it is re-run with nothing to commit, then it
   still succeeds and reports that scaffolding is already present (existing behaviour preserved).

## Out of scope
- Any other host-side git operations by the factory outside `bin/init.sh` / `bin/init-project.sh`.
- Prompting the user to set up their git identity.
- Changes to the identity agents use inside containers.
