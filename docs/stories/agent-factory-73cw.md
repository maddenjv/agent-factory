# agent-factory-73cw: System 1 model for the team-lead harness

## Story
As the human operating the factory, I want team-lead's finite routing decisions to be made by a small
"System 1" model (e.g. LiquidAI d1-2B) - run locally by Docker Model Runner or hosted remotely - enabled
by an env flag, so that routine triage is cheap and fast, and anything the model cannot decide lands on me
where I can see what the model is missing.

## Context
- Today team-lead is a full agentic session (`bin/agent-loop.sh`, `agents/team-lead.md`) on the most capable model.
- Its issue-driven work is finite: (1) route an unrouted issue (no `role:*`) or a `needs-team-lead`
  escalation to a role/stage, or to a human; (2) size a story's chain for a `needs-chain` issue. The only real
  chain decision is whether a `po` stage is needed - an issue with enough context (e.g. a bug with log
  snippets or a log path) needs no PO but still needs architect, engineer, qa and reviewer.
- A 2B model cannot drive a tool loop, so in this mode the model is asked for ONE decision and the scripts
  apply it via `bd`.
- Requester decisions (2026-11-09): enabled via env flag; supports local and remote hosted models speaking the
  API spec the requester called "JEV" (assumed here to mean the OpenAI-compatible chat API that Docker Model
  Runner exposes - architect to confirm and note in the design); both routing and chain sizing go to the
  System 1 model; on any failure fall back to **needs-human** (not the capable-model session); local model is
  started with Docker Model Runner, e.g. `docker model run hf.co/LiquidAI/d1-2B`.
- The periodic throttle-judgment session is not an issue-driven decision and is out of scope.

## Acceptance criteria
1. Given the System 1 env flag is unset (default), when team-lead picks up any work, then behaviour is
   identical to today (capable-model agentic session).
2. Given the flag is set and the endpoint/model are configured, when team-lead picks up an unrouted issue or a
   `needs-team-lead` issue, then the System 1 model is asked for a single decision and the issue ends up
   labelled for the chosen role/stage (stale claim released) or `needs-human`, with a `bd comment` recording
   the decision and its reason.
3. Given the flag is set, when team-lead picks up an unrouted issue with no story, then the System 1 model
   decides `po` (route to po as today), `direct` (no PO: a script builds the story from the issue text and
   the full design/tests/implement/verify/review chain) or `human`; and given a `needs-chain` issue, the model
   decides only `skip_design` / `skip_tests` (same rule as `agents/team-lead.md`) and the script builds the chain.
   (Re-read per docs/design/agent-factory-73cw.md: a chain never has a PO stage.)
4. Given the endpoint is a local Docker Model Runner instance, then it works; given it is a remote hosted
   endpoint with an API key configured, then it works equally - the endpoint URL, model name and optional key
   are all configurable via `.env`.
5. Given the model is unreachable, times out, or returns output that is not a valid decision, when team-lead
   handles an issue, then the issue is labelled `needs-human` with a note explaining the failure and the raw
   model output (if any), and the capable-model session is NOT started.
6. Given the model's decision is applied, then a human can see from `bd show` which model made it and why.
7. Given a user sets the flag with local hosting, when they run `bin/init.sh` / start the factory, then the
   documented path starts or pulls the model via Docker Model Runner (`hf.co/LiquidAI/d1-2B` by default,
   overridable) and the README documents the env settings; with the flag unset nothing is pulled.

## Out of scope
- Throttle judgment (`set-throttle.sh` session) and any non-team-lead role.
- Fine-tuning or updating the System 1 model.
- Falling back to the capable model on failure (explicitly `needs-human` for now).
- Confidence thresholds beyond "valid decision or not".
