# agent-factory-bki: Select the harness every role runs via a command-line flag

## Story
As the operator starting agent-factory, I want to choose which harness CLI all five roles (plus
team-lead) run on - Claude Code (today's only option) or GitHub Copilot CLI - via a command-line
flag at setup time, so that I can run the factory with GitHub Copilot instead of being locked to
Claude Code, without agent-factory trying to auto-detect anything installed on my host.

## Context
Today the harness is hardcoded everywhere: `Dockerfile` installs only `@anthropic-ai/claude-code`,
and `bin/agent-loop.sh`'s `run_claude_session()` invokes `claude` directly with Claude-Code-specific
flags (`-p`, `--dangerously-skip-permissions`, `--max-turns`, `--output-format stream-json
--verbose`, `--model`), parses Claude's `stream-json` event shape for the tmux pane render and for
cost/quota extraction, and its preflight check (`claude -p "Reply with the single word OK." ...`)
assumes the same CLI. The per-role prompts under `agents/` are plain markdown, harness-agnostic in
content, but how they're delivered to the CLI (as a `-p` argument, expected output format, auth
model) is Claude-Code-specific.

The human clarified scope directly on this issue (2026-09-28): a command-line flag, not host-side
detection; every role uses the same harness for a given run (no per-role mixing); the only
additional harness to support right now is GitHub Copilot CLI; default to Claude Code when no
flag is given.

This repo has no existing CLI-flag-parsing convention (`bin/*.sh` scripts take all configuration
from `.env`, populated once by `bin/init.sh` - see `docs/ARCHITECTURE.md`'s "Layout" and
`.env.example`). The architect should follow that existing pattern: a flag on `bin/init.sh`
(the one-time setup script) that persists the choice into `.env` alongside `HOST_UID`/`HOST_GID`/
`HOST_USER`/`CONTAINER_HOME`, for `agent-loop.sh` and the `Dockerfile` build to read from there -
rather than inventing a new per-invocation flag on `bin/start.sh` or `bin/agent-loop.sh`. The
architect owns the exact flag name/spelling, the `.env` variable name, and the invocation details
for GitHub Copilot CLI (its actual binary name, non-interactive/headless flags, auth mechanism,
and output format) - this story only specifies the observable behaviour.

## Acceptance criteria

1. **Given** a fresh project with no prior harness choice, **when** `bin/init.sh` is run with no
   harness flag, **then** the factory is configured to use Claude Code (today's behaviour) for
   every role - no flag is required to keep working exactly as before.

2. **Given** `bin/init.sh` is run with a flag selecting GitHub Copilot CLI, **when** setup
   completes, **then** the chosen harness is persisted (e.g. into `.env`) so that every later
   `bin/start.sh` / `bin/agent-loop.sh` run for this project uses it without repeating the flag.

3. **Given** a project configured for GitHub Copilot CLI, **when** any of the five roles or
   team-lead runs a session, **then** `agent-loop.sh` invokes the GitHub Copilot CLI (not `claude`)
   to run that session, feeding it the same role prompt content from `agents/<role>.md` that
   Claude Code sessions receive today.

4. **Given** a project configured for GitHub Copilot CLI, **when** the `agent` image is built,
   **then** the GitHub Copilot CLI is installed and usable inside the image (`docker compose build
   agent` succeeds; the CLI runs inside a container).

5. **Given** either harness is configured, **when** a role's session finishes, **then** the
   existing per-session behaviours that don't depend on harness-specific output format still work
   end to end: the tmux pane shows readable progress output, a cost/usage figure is recorded for
   the day under `$CONTROL/cost/<role>.<date>` (or the harness's closest equivalent, documented if
   it differs), and a usage-limit/quota condition is still detected and handled the same way
   `run_claude_session()` handles a Claude Code quota hit today (see `quota_hit_message`/
   `quota_hit_from_stream` in `bin/agent-loop.sh`).

6. **Given** an unrecognized value is passed to the harness flag, **when** `bin/init.sh` runs,
   **then** it fails with an error naming the accepted values, and does not silently fall back to
   a default or half-configure the project.

7. **Given** the preflight check `agent-loop.sh` runs before starting a role's session (today:
   `claude -p "Reply with the single word OK." ...`), **when** the project is configured for
   GitHub Copilot CLI, **then** the preflight check uses that harness's equivalent invocation, and
   still alerts the operator the same way on failure (e.g. bad/missing auth).

## Out of scope
- Any on-host detection of installed harness CLIs - explicitly ruled out by the human's answer.
- Per-role harness selection (different roles using different harnesses in the same run).
- Any harness other than Claude Code and GitHub Copilot CLI.
- Changing how the per-role prompts under `agents/` are written (they remain harness-agnostic
  markdown); only how they're delivered to the CLI is in scope.
- A UI/interactive picker - this is a plain command-line flag with a documented default.
