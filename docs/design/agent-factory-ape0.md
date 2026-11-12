# Design: agent-factory-ape0 - Review and update README.md

Docs-only change to `README.md`. No scripts change. The engineer edits README.md against the checklist
below (each item was verified against the code on `main` at design time; re-check the cited source
before editing, since the code is the source of truth).

## Drift found (README says -> reality)

1. **Where the board lives.** Intro text and the ASCII diagram say the status board is a pane of the
   `agents` window ("board | po | architect | qa | engineer | reviewer"); Setup's `start.sh` comment says
   window "agents" has panes "board po architect qa engineer reviewer"; Day-to-day "See state" says
   "`board` pane in the `agents` window". Reality (`bin/start.sh`): window `agents` has **six** panes -
   `team-lead po architect qa engineer reviewer` (tiled); window `ops` has the `shell` pane with the
   `board` pane above it. Fix all four places; the diagram must show team-lead and move board/ops to the
   `ops` window. The intro sentence "five working agents ... plus a team-lead" is fine; the sentence
   "The status board and all the agents show as panes in one tmux window; ops is a separate window" must
   become: agents (six panes incl. team-lead) in `agents`; board + shell in `ops`.
   "Restart one agent" row: still correct as written.
2. **Operational tuning variables undocumented.** README documents only some `.env` knobs. Add a short
   "Configuration" subsection (end of Setup, before System 1) pointing at `.env.example` as the full,
   commented list and naming the loop knobs with defaults from `.env.example`/`bin/agent-loop.sh`:
   `MAX_TURNS` (60), `ITERATION_TIMEOUT` (45m), `IDLE_SLEEP` (60), `MAX_ATTEMPTS_PER_ISSUE` (2),
   `MAX_CONSECUTIVE_FAILURES` (3), `QUOTA_RETRY_INTERVAL` (900), `DAILY_BUDGET_USD`, `MAX_READY_ENGINEER_ISSUES`
   (5), `HUMAN_APPROVE_STORIES` (1 in `.env.example`), `NOTIFY_URL`, `ALERT_MAX_AGE_MINUTES` (60),
   `DOLT_HOST_PORT`. One line each, no more. Also mention `MODEL_TEAM_LEAD` alongside `MODEL_<ROLE>`.
3. **Optional image customisation missing.** Add a short "Customising the agent image" paragraph:
   `extra-ca/*.crt` (private CA) and `dotfiles/` (copied into the container user's home), both git-ignored,
   take effect after `docker compose build agent` and a restart; keep `.gitkeep`. Link to
   `docs/ARCHITECTURE.md` "Stack" for details. Also one line on the project venv: if
   `<project>/.venv` exists it is recreated as a container-local venv (`bin/project-venv.sh`), no-op otherwise.
4. **`smoke-test.sh` not documented.** `docs/ARCHITECTURE.md` refers to README "Before running
   unattended", which does not exist. Add that section (after Setup's code block / before Day to day):
   run `bin/smoke-test.sh` from the **ops** shell first; it checks concurrent Beads writes under Dolt
   server mode.
5. **Flow gaps.** In "Flow": (a) add a sentence that before the reviewer claims a `stage:review` issue,
   `bin/conflict-check.sh` checks for merge conflicts against `main` and files a `merge-conflict`
   rework issue if there is one; (b) mention the storyless `fix/<issue-id>` path (small follow-ups,
   reviewed and merged by the reviewer without design/tests) in one sentence; (c) mention
   `bin/restart-story.sh` (used when a merge-conflict rework can't be resolved: implement/verify/review are
   redone from current `main`; design/tests are kept) - one sentence, noting it is invoked by agents, not
   normally by the operator. Keep the mermaid diagram as is.
6. **Step 3 wording.** "`approve.sh <design-issue>`" - `.env.example` calls it the architect issue; use
   "design (architect) issue" consistently. Verify `bin/approve.sh` usage before wording.

## Out of scope
Rewriting prose that is accurate; changing scripts or `.env.example`; ARCHITECTURE.md (its pointer to
"Before running unattended" is satisfied by item 4).

## Acceptance mapping
Story AC is generic ("README in sync with implementation"). Satisfied when items 1-6 are applied, and no
README claim contradicts `bin/start.sh`, `.env.example`, or `docs/ARCHITECTURE.md`.

## Test strategy (QA)
Shell checks on README.md (grep-level, no containers):
- No line places `board` in the `agents` window: `! grep -nE 'board.*`agents` window|agents.*panes.*board' README.md`;
  README mentions `team-lead` as a pane of `agents` and `board` as a pane of `ops`.
- README contains `smoke-test.sh`, `conflict-check.sh`, `restart-story.sh`, `extra-ca`, `dotfiles`,
  `project-venv` (or "`.venv`"), `MAX_TURNS`, `ITERATION_TIMEOUT`, `QUOTA_RETRY_INTERVAL`, `MODEL_TEAM_LEAD`,
  and a heading containing "Before running unattended".
- Every `bin/<name>.sh` mentioned in README exists; every `.env` variable README names appears in
  `.env.example` or `bin/*.sh`/`docker-compose.yml`.
- Existing regression scripts under `tests/` that grep README still pass (run the whole suite).
