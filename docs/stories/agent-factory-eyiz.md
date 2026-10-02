# agent-factory-eyiz: bin/init.sh messages name the chosen harness's auth, not just Claude Code's

## Story
As a user running `bin/init.sh --harness=copilot`, I want the messages it prints to talk about
GitHub Copilot CLI's login and tokens, so that I'm not told to check `~/.claude` or set an
Anthropic API key for a harness I'm not using.

## Context
`bin/init.sh` takes `--harness=<claude-code|copilot>` and records `HARNESS=` in the project's
`.agent-factory/.env`. Its one auth-related message, printed when it creates the starter `.env`,
is Claude Code specific: "reuses your host ~/.claude login ... CLAUDE_CODE_OAUTH_TOKEN /
ANTHROPIC_API_KEY ...". Under copilot the relevant facts are different: it reuses the host
`~/.copilot` login (`copilot login`), and the optional tokens are `COPILOT_GITHUB_TOKEN` /
`GH_TOKEN` / `GITHUB_TOKEN` (see `.env.example` and README "Harness"). The harness "in effect"
is the `--harness` flag if given, else the `HARNESS=` already in `.env`, else `claude-code`.

## Acceptance criteria
1. Given no `.env` exists and `--harness=copilot` (or none/`claude-code`) is passed, when
   `bin/init.sh` creates the starter `.env`, then the "Created ..." message mentions the host
   login directory and optional token variables of the chosen harness only: for copilot
   `~/.copilot` / `copilot login` and `COPILOT_GITHUB_TOKEN`/`GH_TOKEN`/`GITHUB_TOKEN`; for
   claude-code `~/.claude` and `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`.
2. Given the copilot harness is chosen, when the message is printed, then its output contains none
   of `~/.claude`, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`, or "Claude".
3. Given the claude-code harness is chosen, when the message is printed, then its output contains
   none of `~/.copilot`, `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`.
4. Given any other message `bin/init.sh` prints (success, "Done", errors) mentions an
   agent-specific login, key or config directory, then it names the harness in effect, not
   Claude Code unconditionally. Messages that mention none stay unchanged.
5. Given the claude-code default path, when `bin/init.sh` runs, then behaviour, exit status and
   the resulting `.env` are unchanged from today (message wording aside).

## Out of scope
- Changing which files/variables the harnesses actually use, or `.env.example` / README content.
- Auth checks or validation that a login/token actually exists.
- Messages from scripts other than `bin/init.sh`.
