# agent-factory-is2h: Agent model hierarchy

## Story
As a factory operator, I want System 1's per-task model choice to take priority over a per-role model
override, with `MODEL_<ROLE>` and then `MODEL_MEDIUM` as fallbacks, so that enabling System 1 actually
picks the model per task, and a role pin only applies when System 1 gives no usable answer.

## Context
`bin/agent-loop.sh` `choose_model` asks System 1 (`bin/system1-class.sh`) to classify the claimed issue as
`high|medium|low` and runs the session with `MODEL_HIGH|MODEL_MEDIUM|MODEL_LOW`. Today an explicit
`MODEL_<ROLE>` wins and skips System 1 entirely (see `docs/ARCHITECTURE.md`, README "Per-task model class",
`.env.example`). The request reverses that precedence. Role tier defaults (story agent-factory-250) are
unchanged and remain the last resort when none of the variables below yields a model.

Resulting order, highest priority first:
1. System 1 (when `SYSTEM1_ENABLED=1`) classifies the issue and the chosen class's variable (`MODEL_HIGH|MEDIUM|LOW`) is non-empty.
2. `MODEL_<ROLE>`.
3. `MODEL_MEDIUM`.
4. The role's tier default (existing behaviour).

## Acceptance criteria
1. **Given** System 1 is enabled and answers a valid class whose `MODEL_<CLASS>` is set, and `MODEL_<ROLE>` is also set, **when** a session starts for that role, **then** it runs with the class model, not `MODEL_<ROLE>`.
2. **Given** System 1 is enabled but fails, times out, answers an invalid class, or the chosen class's `MODEL_<CLASS>` is empty, and `MODEL_<ROLE>` is set, **when** a session starts, **then** it runs with `MODEL_<ROLE>`.
3. **Given** System 1 is disabled and `MODEL_<ROLE>` is set, **when** a session starts, **then** it runs with `MODEL_<ROLE>` and no System 1 request is made.
4. **Given** System 1 gives no usable model and `MODEL_<ROLE>` is unset but `MODEL_MEDIUM` is set, **when** a session starts, **then** it runs with `MODEL_MEDIUM`.
5. **Given** none of System 1's model, `MODEL_<ROLE>` or `MODEL_MEDIUM` yields a model, **when** a session starts, **then** it runs with the role's tier default as before.
6. **Given** any of the above, **when** the choice is made, **then** the loop log records which source supplied the model (System 1 class, `MODEL_<ROLE>`, `MODEL_MEDIUM` or role default) and, for fallbacks, the reason.
7. **Given** an operator reads README, `.env.example` and `docs/ARCHITECTURE.md`, **when** they look up model selection, **then** all three state the order above and no longer say `MODEL_<ROLE>` wins over System 1.

## Out of scope
- Changing how System 1 classifies issues or the `/v1/systemone` endpoint.
- Changing team-lead's own System 1 routing or the role tier defaults.
- New environment variables.
