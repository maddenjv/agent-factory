# agent-factory

Five Claude Code agents (po, architect, qa, engineer, reviewer), each its own Docker container,
coordinated through Beads and git. Agents run with `--dangerously-skip-permissions` inside their
container. The status board and all 5 agents show as panes in one tmux window; `ops` — the shell
you type into — is a separate window.

```
                       shared Dolt server (container "dolt")  <- the only Beads database
                                   ^   ^   ^   ^   ^
   tmux "agents" window, one pane each:   board | po | architect | qa | engineer | reviewer
   (+ separate "ops" window)
   container: each has its own git clone of YOUR PROJECT (see Setup) - only the reviewer pushes
   back to it directly; stories, designs and the beads database all live inside it, under
   <project>/.agent-factory/
```

## Flow
1. You: `feature.sh "Title" "description"` (from the **ops** window). Creates an issue labelled `role:po`.
2. **po** writes `docs/stories/<id>.md` on branch `story/<id>` and runs `new-story.sh`, which creates the chain
   `design -> tests -> implement -> verify -> review` linked with `blocks` dependencies.
3. With `HUMAN_APPROVE_STORIES=1` the design issue starts labelled `needs-human`: read the story, then `approve.sh <design-issue>`.
4. Each agent polls `bd ready --label role:<me>`, claims one issue, runs one fresh Claude session on it, and
   closes it, which unblocks the next stage. Everyone commits to `story/<id>`; only the reviewer merges to `main`.
5. QA/reviewer defects become `stage:rework` issues for the engineer that block the QA/review issue; it re-opens
   when they close. After 2 rework rounds a story goes to `needs-human`.

## Setup
**Self-contained** — `docker-compose.yml` builds the `agent` image from this repo's own
`Dockerfile` (the Claude Code + beads toolchain lives there). Its container user is `john`;
agent-loop.sh runs in place of the image's default entrypoint (a plain shell), and does its own
host-`~/.claude` sync on startup so each role reuses your logged-in Claude Code plan session — no
API key or token needed by default.

**Two directories, kept separate (see `bin/lib.sh`):**
- **KIT_DIR** — this repo (`docker-compose.yml`, `bin/`, `agents/`), wherever it's checked out.
- **PROJECT_DIR** — the real project you're pointing agent-factory at. Every `bin/*.sh` script
  below takes this from **your current directory**, not from where this kit lives — `cd` into
  your project first, every time. It must already be an existing git repo on branch `main`.
  All of agent-factory's own runtime state (workspaces, control, logs, claude config, the Dolt
  database, and its own `.env`) lives under `<project>/.agent-factory/` (gitignored), not inside
  this kit — so it travels with the project, and pointing this kit at a different project next
  time starts clean.

**`.env` resolution**: if `<project>/.agent-factory/.env` exists, that's the only `.env` used for
that project. Otherwise it falls back to `KIT_DIR/.env`. The two are never merged — whichever one
is in effect supplies all settings for that run, so a project `.env` that only sets a few
variables won't quietly inherit the rest from the kit-level file. Running more than one project
from the same kit checkout? Give each project its own `<project>/.agent-factory/.env` so their
settings (model choice, budget caps, notification URL, etc.) don't leak into each other.

```bash
cd ~/path/to/your/project    # NOT this kit's directory - this is the repo agents will work on
/path/to/agent-factory/bin/init.sh    # first run creates <project>/.agent-factory/.env; defaults need no auth (reuses host ~/.claude); run again
/path/to/agent-factory/bin/start.sh   # tmux session "factory": window "agents" (panes: board po architect qa engineer reviewer), window "ops"
tmux attach -t factory
```
`bin/init.sh` also sets `receive.denyCurrentBranch=updateInstead` on your project so the
reviewer's final `git push origin main` can update its checked-out files directly (standard git
feature - it refuses loudly, not silently, if your project has uncommitted changes at that
moment). It commits initial scaffolding (`docs/stories/`, `docs/design/`, beads init, and either
a new `CLAUDE.md` or an appended section on your existing one) straight to your project's `main`
— it refuses to run at all if your project isn't already clean on `main` first.

**Before running unattended**, in the `ops` window: `smoke-test.sh`. It closes 8 issues concurrently and checks
every close persisted. Beads has open reports of lost writes under concurrent agents in embedded mode; this kit
uses server mode, but verify on your bd version.

## Day to day
| Want to | Do |
|---|---|
| See state | `board` pane in the `agents` window; `bd ready`, `bd blocked`, `bd dep tree <id>` in the `ops` window, or `bd` directly from your own host shell in the project directory — no container needed (see Security notes) |
| Watch an agent | its pane in the `agents` window (rendered tool calls/text; Ctrl-b o to cycle, Ctrl-b q to jump by number); raw stream in `<project>/.agent-factory/logs/<role>/*.jsonl` |
| Review-by-exception | `needs-human` list on the board; `bd show <id>` — the agent (or agent-loop.sh itself, on an attempt-cap/failure escalation) leaves a note on the issue explaining exactly what it needs; set `NOTIFY_URL` for push alerts |
| Unstick an issue | answer what the issue's note asked for, then `approve.sh <id>` |
| Pause / resume | `bin/stop.sh` (graceful) / `bin/stop.sh clear` then `bin/start.sh` — run from the same project directory |
| Hard stop | `bin/stop.sh now` |
| Restart one agent | `tmux list-panes -t factory:agents` for its index, then `tmux respawn-pane -k -t factory:agents.<index>` |
| Publish | Nothing special — the reviewer already merged straight into your project's `main`. Push it to your own remote the way you normally would. |

## Guardrails built in
Per-session turn cap and wall-clock timeout; per-issue attempt cap (then `needs-human`); circuit breaker that stops
an agent after N consecutive failed sessions and alerts; daily spend cap (`DAILY_BUDGET_USD`); WIP limit on the PO;
STOP flags; startup preflight (bd reachable, credentials work); clean git slate every session, so unpushed work
is discarded.

Hitting your Claude Code plan's usage limit is treated separately from a real failure: it never counts
against the per-issue attempt cap or the circuit breaker, at startup (preflight) or mid-issue. The agent
parses a reset time when the CLI reports one and sleeps until then; otherwise it polls every
`QUOTA_RETRY_INTERVAL` (default 900s) and keeps retrying the same issue indefinitely.

## Security notes
- The container is the only thing between the agent and your machine. Nothing sensitive is mounted (no docker
  socket, `~/.ssh`, or home). Keep it that way. A `CLAUDE_CODE_OAUTH_TOKEN` shares your plan's usage limits
  across all five agents (no spend cap of its own — watch `DAILY_BUDGET_USD`); if using `ANTHROPIC_API_KEY`
  instead, use one with a spend limit. Either way, put no other credentials in `.env`.
- Containers have full outbound network access. Agents can install packages and reach the internet, which is
  useful and also the exfiltration path. If that matters, add an egress allowlist (Anthropic's reference
  devcontainer uses an iptables firewall) before running unattended on anything sensitive.
- Dolt is published on `127.0.0.1:3306` (override with `DOLT_HOST_PORT` in `.env`) so `bd` also works from
  your own host shell in the project directory, not just from inside a container pane - loopback only, never
  your LAN, but still no password. Any agent can already rewrite the tracker, so this is a consistency
  boundary, not a security one. `bin/init-project.sh` points a fresh project's `.beads/metadata.json` at that
  loopback address; containers override it back to the Docker-internal `dolt` hostname via
  `BEADS_DOLT_SERVER_HOST` (`bin/env.sh`), so both paths keep working regardless of which one is stored.
- "Origin" is your actual project directory, not a throwaway relay repo - all 5 agents clone from
  it, and the reviewer pushes straight into its checked-out `main` (see Setup). Agents cannot
  reach your project's own remote (GitHub, etc.) - only the local push to your working tree - so
  publishing beyond that stays a separate, manual step under your own control.

## Things I could not test (Docker unavailable where this was written) - check first
1. `dolthub/dolt-sql-server` honouring `DOLT_ROOT_HOST=%` with no root password, and listening on 3306 (env.sh assumes 3306).
2. `bd init --server --server-host dolt` writing config that the other clones inherit from git (`.beads/`
   is committed by init-project.sh). If a clone reports it cannot find the database, run `bd doctor`.
3. Exact `bd` flags used: `ready --label/--limit/--json`, `update --claim --assignee/--status`, `create -l -d -t --json`,
   `dep add`, `label add/remove`, `close --reason`, `list --json`. Confirm with `bd --help` on your version.
4. Claude Code flags: `--dangerously-skip-permissions`, `--max-turns`, `--output-format stream-json --verbose`, `--model`.
5. If `bd init` creates git hooks that break commits in the clones, `git config core.hooksPath /dev/null` in those clones.
