# agent-factory-hr7o: Move issue throttling from team-lead to PO (max ready engineering issues)

## Story
As the human operating the factory, I want the PO to stop starting new stories whenever the engineering
queue already holds a configurable maximum number of ready issues - and team-lead to no longer run any
throttling - so that team-lead stays a pure triage/answering role and the flow into engineering is bounded
by a simple, predictable, observable number instead of a periodic model judgment.

## Context
- Today team-lead periodically runs a no-issue "throttle assessment" session (`agents/team-lead.md`,
  `bin/agent-loop.sh` `throttle_ok()`/`throttle_age()`/`run_throttle_assessment()`, `bin/set-throttle.sh`,
  `.agent-factory/control/throttle.json`, `THROTTLE_STALE_SECS`, `THROTTLE_ALERT_STALE_SECS`, the board's
  `-- throttle --` section). It holds back both `po` and `architect`.
- The requester wants team-lead focused on answering other agents' ambiguous questions (the
  `needs-team-lead` path; team-lead is already the only role that applies `needs-human`), with throttling
  removed from it and owned by PO.
- Decisions made here where the request was silent: "ready issues for engineering" means issues that
  `bd ready --label role:engineer` would return (open, unblocked, unclaimed). The gate applies to `po` only;
  `architect` is no longer throttled by anything. The limit is read from `.env`; default 5; `0` or empty
  means no limit.

## Acceptance criteria
1. Given the factory is running with default config, when team-lead's queue is empty, then team-lead never
   starts a throttle-assessment session, and `agents/team-lead.md` no longer describes or requests one.
2. Given the old throttle machinery, when the change is complete, then `bin/set-throttle.sh`, the
   `THROTTLE_STALE_SECS` / `THROTTLE_ALERT_STALE_SECS` settings, the stale-assessment alert, and the board's
   `-- throttle (po/architect) --` section are gone, and README/ARCHITECTURE/`.env.example` no longer
   describe team-lead throttling.
3. Given `MAX_READY_ENGINEER_ISSUES=N` (N > 0) in `.env` and the number of ready `role:engineer` issues is
   at least N, when PO looks for work, then PO does not claim a new feature request, and logs once that it is
   idling because the engineering queue is full (including the count and the limit).
4. Given the same setting and the ready `role:engineer` count is below N, when PO looks for work, then PO
   claims and processes requests as normal.
5. Given the ready count drops back below N after PO was idling, when PO next polls, then PO resumes without
   a restart.
6. Given `MAX_READY_ENGINEER_ISSUES` is unset, then it defaults to 5; given it is `0` or empty, then PO is
   never held back.
7. Given the ready count cannot be determined (e.g. `bd` errors), when PO polls, then PO proceeds (fails
   open) rather than stalling.
8. Given any role other than `po`, when it polls, then it is never held back by this gate - architect,
   engineer, qa, reviewer and team-lead behave as if no throttle existed.
9. Given PO is idling because of the gate, when a human looks at the board, then the idle state and its
   count/limit are visible (board output or agent log).

## Out of scope
- Changing how team-lead triages, routes, sizes chains, or its System 1 mode (`agent-factory-73cw`).
- Throttling by budget/quota (`DAILY_BUDGET_USD` and usage-limit handling stay as they are).
- Counting issues other than ready `role:engineer` ones, or per-story limits.
- Extending team-lead to answer new kinds of questions (the existing `needs-team-lead` handling is unchanged).
