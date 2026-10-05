# agent-factory-8j3y: Copilot agents can run kit scripts outside their workspace

## Story
As an agent-factory operator running the factory with `HARNESS=copilot`, I want every role,
team-lead in particular, to be able to read and run the kit's scripts under `$KIT_DIR/bin`, so
that Copilot-driven agents can do the same work as Claude Code-driven ones.

## Context
Each agent session runs with its working directory set to its own clone (`$REPO`), while the kit
(`$KIT_DIR`, holding `bin/` and `agents/`) lives elsewhere. Team-lead's prompt tells it to run
scripts such as `"$KIT_DIR/bin/set-throttle.sh"`, `bin/new-story.sh` and `bin/restart-story.sh`
by absolute path. Under Claude Code (`--dangerously-skip-permissions`) this works. Under
Copilot (`HARNESS=copilot`) the session is started with tool approval granted but, in testing, a
Copilot-driven team-lead reported "Running scripts outside the workspace is blocked." and could
not read or execute anything in `$KIT_DIR/bin`. The throttle decision and chain building are
therefore impossible under Copilot. The sandboxing applies to paths, not just tools, so
approving all tools is not enough.

## Acceptance criteria
1. **Given** `HARNESS=copilot`, **when** a team-lead session needs to run a script in
   `$KIT_DIR/bin` (e.g. `set-throttle.sh`), **then** the script executes and its output is
   returned to the agent, with no "outside the workspace" refusal.
2. **Given** `HARNESS=copilot`, **when** any role's session reads a file under `$KIT_DIR`
   (e.g. `$KIT_DIR/bin/*.sh`, `$KIT_DIR/agents/*.md`), **then** the read succeeds.
3. **Given** `HARNESS=copilot`, **when** an agent session starts, **then** it is still run
   non-interactively (no approval prompts), still inside its own clone as the working directory,
   with the same model and timeout handling as before.
4. **Given** `HARNESS=claude-code`, **when** an agent session starts, **then** its invocation is
   unchanged.
5. **Given** `HARNESS=copilot`, **when** the startup preflight check runs, **then** it still
   succeeds and its behaviour (including quota-hit handling) is unchanged.

## Out of scope
- Restricting which paths Copilot agents may touch (no tightening or loosening beyond the
  access needed to run and read kit files).
- Per-role differences in access; the fix applies to all roles equally.
- Other Copilot vs Claude Code parity gaps (cost reporting, model tier defaults).
