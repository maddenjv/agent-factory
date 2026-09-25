# agent-factory-250: Per-role model tiers, with team-lead on the most capable model

## Story
As an agent-factory operator running the fleet unattended, I want each role to start with a
sensible default model tier - the coordination-focused team-lead role on the most capable model,
the five execution roles on a lower-capability tier - so that I get good routing/escalation
judgment where it matters without paying top-tier rates on every container, while still being
able to override any single role's model explicitly when I want to.

## Context
`bin/agent-loop.sh` already supports a per-role override: it reads `MODEL_<ROLE>` (uppercased) at
startup and, if set, passes it to `claude` via `--model` (bin/agent-loop.sh:34-35,183). Today
there is no default at all - if `MODEL_<ROLE>` is unset, no `--model` flag is passed and every
role silently falls back to whatever the `claude` CLI's own default happens to be, uniformly
across roles. The startup log line records this as `model=default` (bin/agent-loop.sh:300),
giving no visibility into which model actually ran.

A separate story (agent-factory-dx0) introduces the `team-lead` role itself - its prompt file,
docker wiring, and routing behavior. This story only adds the tiered default for model
*selection* and is independent of that work landing first: `ROLE` is a plain env var read at
startup (bin/agent-loop.sh:8), and the model-resolution lines run before anything that requires
`agents/team-lead.md` or other team-lead-specific wiring to exist. So the tier default for
`team-lead` can be added and verified (by checking what model it *would* resolve to) before the
team-lead agent is otherwise functional, and is simply ready the moment it is.

"Most capable" and "lower-capability" map to Opus and Sonnet today per the request, but the
concrete model names will drift over time - the design should make that mapping easy to change in
one place rather than hardcoding it at every call site.

## Acceptance criteria

1. **Given** `ROLE=team-lead` and `MODEL_TEAM_LEAD` is not set, **when** `agent-loop.sh` starts,
   **then** it resolves and uses the most capable available model (currently Opus) as team-lead's
   model.
2. **Given** `ROLE` is one of `po`, `architect`, `engineer`, `qa`, or `reviewer`, and the
   corresponding `MODEL_<ROLE>` is not set, **when** `agent-loop.sh` starts, **then** it resolves
   and uses the lower-capability tier default (currently Sonnet) for that role.
3. **Given** any role, **when** the operator sets `MODEL_<ROLE>` explicitly (e.g.
   `MODEL_QA=opus`), **when** `agent-loop.sh` starts, **then** it uses that explicit value instead
   of the role's tier default.
4. **Given** a role starting up, **when** the startup log line is written, **then** it records the
   actual model resolved for that run (tier default or explicit override) rather than the literal
   string "default".
5. **Given** the README or other docs covering `agent-loop.sh` configuration, **when** an operator
   looks up how to control which model a role runs, **then** they find the default tier for
   team-lead vs. the other five roles stated explicitly, and how `MODEL_<ROLE>` overrides it.

## Out of scope
- The team-lead role's own behavior, prompt file, docker-compose wiring, or tmux pane placement
  (agent-factory-dx0, agent-factory-uhc).
- Switching agents from `needs-human` to `needs-team-lead` labelling (agent-factory-ulq).
- Any model other than the current two tiers (Opus/Sonnet), or automatic selection based on task
  complexity - this story is static, role-keyed defaults only.
- Cost/budget accounting changes beyond the existing `DAILY_BUDGET_USD` mechanism.
