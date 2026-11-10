# agent-factory-hcql: Per-task model class selection (System 1)

## Story
As a factory operator, I want each agent loop to ask a small System 1 model which cost class
(high, medium, low) of model a task needs, so that cheap models handle simple work, capable models
handle hard work, and I don't overspend or under-power sessions.

## Context
- Today each role runs a fixed model: team-lead on the capable tier, the other five roles on a
  lower tier, overridable per role with `MODEL_<ROLE>` in `.env` (`bin/agent-loop.sh`, "model resolution").
- System 1 already exists (`agent-factory-73cw`): `SYSTEM1_ENABLED`, `SYSTEM1_URL`, `SYSTEM1_MODEL`,
  `SYSTEM1_API_KEY`, `SYSTEM1_TIMEOUT` and `bin/system1.sh` call a small OpenAI-compatible model, used
  today only for team-lead routing decisions.
- This story extends System 1 to a new decision: before each session in any role's loop, classify the
  claimed issue's complexity and pick the model class for that session.
- Three class models are configured in `.env` as `MODEL_HIGH`, `MODEL_MEDIUM`, `MODEL_LOW`
  (documented in `.env.example`). Empty = unset.
- The decision uses the issue (title, description, labels, role/stage) as input. Which tier each class
  maps to for the harness is the operator's choice via those values.

## Acceptance criteria
1. Given System 1 is enabled and reachable and `MODEL_HIGH`/`MODEL_MEDIUM`/`MODEL_LOW` are set, when any
   role's loop starts a session on an issue and System 1 answers `high`, `medium` or `low`, then the
   session runs with the model configured for that class.
2. Given System 1 is not enabled or not configured, when a session starts, then it runs with
   `MODEL_MEDIUM` and no System 1 request is made.
3. Given System 1 is enabled but the request fails (unreachable, timeout, HTTP error), or answers
   something that is not one of `high`/`medium`/`low`, when a session starts, then it runs with
   `MODEL_MEDIUM`, the loop log records the fallback and reason, and the issue is not labelled
   `needs-human` because of it.
4. Given the chosen class's model variable is empty (or `MODEL_MEDIUM` is empty on the fallback path),
   when a session starts, then it runs with the role's existing default model (current behaviour), and
   the log says so.
5. Given an explicit `MODEL_<ROLE>` is set for the role, when a session starts, then that model is used
   and System 1 is not consulted (an explicit per-role pin wins).
6. Given a session starts, when the model is chosen, then the loop log records the issue id, the class
   chosen, whether it came from System 1 or a fallback, and the resulting model name.
7. Given none of the new variables are set and System 1 is disabled, when the factory runs, then
   behaviour is unchanged from today (no regression for existing `.env` files).
8. Given the change is delivered, then `.env.example` documents `MODEL_HIGH`, `MODEL_MEDIUM`,
   `MODEL_LOW` and the fallback rule, and the README/ARCHITECTURE System 1 sections mention the
   new decision.

## Out of scope
- Switching model mid-session or re-classifying after rework.
- Learning from outcomes or tuning the classifier prompt beyond a working first version.
- Throttle assessment sessions and team-lead's existing System 1 routing decisions (unchanged).
- Per-class settings other than the model name (turn limits, timeouts).
- Cost accounting or budget changes.
