# agent-factory

Five Claude Code agents (po, architect, qa, engineer, reviewer), one tmux window and one Docker
container each, coordinated through Beads and git. Agents run with `--dangerously-skip-permissions`
inside their container.

```
                       shared Dolt server (container "dolt")  <- the only Beads database
                                   ^   ^   ^   ^   ^
   tmux window:   po     architect     qa     engineer     reviewer      (+ ops, board)
   container:    each has its own git clone of  data/origin.git  (bare repo on the host)
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
```bash
bin/init.sh          # first run creates .env; add ANTHROPIC_API_KEY (or CLAUDE_CODE_OAUTH_TOKEN); run again
bin/start.sh         # tmux session "factory": ops, board, po, architect, qa, engineer, reviewer
tmux attach -t factory
```
**Before running unattended**, in the `ops` window: `smoke-test.sh`. It closes 8 issues concurrently and checks
every close persisted. Beads has open reports of lost writes under concurrent agents in embedded mode; this kit
uses server mode, but verify on your bd version.

## Day to day
| Want to | Do |
|---|---|
| See state | `board` window; `bd ready`, `bd blocked`, `bd dep tree <id>` in `ops` |
| Watch an agent | its tmux window (rendered tool calls/text); raw stream in `data/logs/<role>/*.jsonl` |
| Review-by-exception | `needs-human` list on the board; set `NOTIFY_URL` for push alerts |
| Unstick an issue | fix/answer it, then `approve.sh <id>` |
| Pause / resume | `bin/stop.sh` (graceful) / `bin/stop.sh clear` then `bin/start.sh` |
| Hard stop | `bin/stop.sh now` |
| Restart one agent | `tmux respawn-pane -k -t factory:<role>` |
| Publish | `git -C data/origin.git remote add github <url>; git -C data/origin.git push github main` |

## Guardrails built in
Per-session turn cap and wall-clock timeout; per-issue attempt cap (then `needs-human`); circuit breaker that stops
an agent after N consecutive failed sessions and alerts; daily spend cap (`DAILY_BUDGET_USD`); WIP limit on the PO;
STOP flags; startup preflight (bd reachable, credentials work); clean git slate every session, so unpushed work
is discarded.

## Security notes
- The container is the only thing between the agent and your machine. Nothing sensitive is mounted (no docker
  socket, `~/.ssh`, or home). Keep it that way. Use an API key with a spend limit, and no other credentials in `.env`.
- Containers have full outbound network access. Agents can install packages and reach the internet, which is
  useful and also the exfiltration path. If that matters, add an egress allowlist (Anthropic's reference
  devcontainer uses an iptables firewall) before running unattended on anything sensitive.
- Dolt is only reachable on the compose network (no published port) and has no password. Any agent can already
  rewrite the tracker, so this is a consistency boundary, not a security one.
- The remote is a local bare repo, so agents cannot push to GitHub. You publish.

## Things I could not test (Docker unavailable where this was written) - check first
1. `dolthub/dolt-sql-server` honouring `DOLT_ROOT_HOST=%` with no root password, and listening on 3306 (env.sh assumes 3306).
2. `bd init --server --server-host dolt` writing config that the other clones inherit from git (`.beads/`
   is committed by init-project.sh). If a clone reports it cannot find the database, run `bd doctor`.
3. Exact `bd` flags used: `ready --label/--limit/--json`, `update --claim --assignee/--status`, `create -l -d -t --json`,
   `dep add`, `label add/remove`, `close --reason`, `list --json`. Confirm with `bd --help` on your version.
4. Claude Code flags: `--dangerously-skip-permissions`, `--max-turns`, `--output-format stream-json --verbose`, `--model`.
5. If `bd init` creates git hooks that break commits in the clones, `git config core.hooksPath /dev/null` in those clones.
