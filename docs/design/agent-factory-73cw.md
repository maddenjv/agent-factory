# Design: agent-factory-73cw - System 1 model for team-lead

## Resolved story ambiguities (architect decisions)
- **"JEV"** = the OpenAI-compatible chat-completions API (`POST {base}/chat/completions`), which is what
  Docker Model Runner (DMR) serves at `/engines/v1`. Remote hosted endpoints use the same spec + Bearer key.
- **AC3 contradiction.** AC3 / the Context bullet say the model decides whether a chain "includes a PO stage".
  A `needs-chain` issue is only filed by po *after* it wrote `docs/stories/<id>.md`, and `bin/new-story.sh`
  has no po stage, so that decision is vacuous there. The only place "skip PO" means something is the
  **unrouted-issue sweep** (feature.sh issues, bug reports with logs). Human approved proceeding via
  `approve.sh` without choosing; architect picks option **A** (the story's intent - a bug with logs
  bypasses PO): AC3 is **re-read** as:
  > AC3'. Given the flag is set, when team-lead picks up an *unrouted issue with no story*, the model
  > decides `po` (route to po as today), `direct` (no PO: a script builds the story from the issue text and
  > the full five-stage chain) or `human`. Given a `needs-chain` issue, the model decides only
  > `skip_design` / `skip_tests` (same rule as `agents/team-lead.md`), and the script runs `new-story.sh`.
  PO should amend AC3 in the story file to this wording (filed as a follow-up, see handoff comment);
  this design is authoritative meanwhile.

## Approach
A 2B model cannot drive a tool loop. For an issue-driven team-lead session with `SYSTEM1_ENABLED=1`,
`agent-loop.sh` does **not** start the harness: it runs `bin/system1.sh <issue-id>`, which (1) classifies
the issue deterministically, (2) asks the model for ONE JSON decision, (3) validates it, (4) applies it
with `bd`/git. Any failure -> `needs-human`. The throttle session (no issue) is untouched and still uses
the capable model. Flag unset -> byte-for-byte today's behaviour (AC1).

## Files
- **new `bin/system1.sh`** - all logic (below). Sources `bin/bdjson.sh`. `set -uo pipefail`; always exits 0
  once the issue has been given a terminal outcome (decision applied or `needs-human`), so the loop treats
  it as handled. Functions are individually testable; guard `main` with
  `[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"` so tests can `source` it.
- **`bin/agent-loop.sh`** - `run_agent()`: if `ROLE=team-lead`, `SYSTEM1_ENABLED=1` and a harness-less path
  applies, call `"$KIT_DIR/bin/system1.sh" "$1" >>"$LOGDIR/loop.log" 2>&1`, set `LAST_RUN_QUOTA_MSG=""`,
  `LAST_RUN_RC=0`, write no cost file; else existing `run_harness_session`. `run_throttle_assessment`
  unchanged. `handle_outcome` needs no change: closed (chain/direct) -> handled; rerouted -> the existing
  team-lead branch hands back; `needs-human` -> the existing backstop (system1.sh always writes a note).
- **`.env.example`** - add a `# ---- System 1 ----` block (all commented/empty default):
  `SYSTEM1_ENABLED=` (set `1` to enable), `SYSTEM1_URL=` (base URL incl. `/v1`, default
  `http://host.docker.internal:12434/engines/v1` = DMR host TCP), `SYSTEM1_MODEL=` (default
  `hf.co/LiquidAI/d1-2B`), `SYSTEM1_API_KEY=` (optional; sent as `Authorization: Bearer`),
  `SYSTEM1_TIMEOUT=60` (seconds), `SYSTEM1_LOCAL=` (`1` = init.sh pulls the model via DMR).
  Same empty-value/no-trailing-comment rule as `DAILY_BUDGET_USD`.
- **`docker-compose.yml`** - `agent` service: `extra_hosts: ["host.docker.internal:host-gateway"]` (needed on
  Linux for the default URL); pass the `SYSTEM1_*` vars through (they arrive via `env_file`, so no change if
  `.env` is already the env_file).
- **`bin/init.sh`** - after env setup: if `SYSTEM1_ENABLED=1` **and** `SYSTEM1_LOCAL=1`: require
  `docker model version` (else print an error naming Docker Model Runner and exit non-zero), then
  `docker model pull "${SYSTEM1_MODEL:-hf.co/LiquidAI/d1-2B}"`. Flag unset or `SYSTEM1_LOCAL` unset -> no
  `docker model` call at all (AC7). README: document the vars, DMR TCP enablement (`docker desktop enable
  model-runner --tcp 12434` on Desktop; Engine users install `docker-model-plugin`), the remote setup
  (URL + key), and the failure semantics.
- **`agents/team-lead.md`** - one paragraph noting that with `SYSTEM1_ENABLED=1` these decisions are made
  by `bin/system1.sh` instead and this prompt then only runs for the throttle session.
- **`docs/ARCHITECTURE.md`** - add System 1 to the team-lead paragraph + layout (`bin/system1.sh`).

## `bin/system1.sh <issue-id>`
1. **Config check**: `SYSTEM1_ENABLED=1` and `SYSTEM1_URL`/`SYSTEM1_MODEL` resolvable (defaults above) else
   `fail "System 1 enabled but not configured: ..."`.
2. **Classify** from `bd show <id> --json` (via `bd_unwrap`):
   | labels | kind | allowed decisions |
   |---|---|---|
   | `needs-chain` | `chain` | `{skip_design,skip_tests}` |
   | `needs-team-lead` | `route` | route / human |
   | no `role:*`, has `story:*` | `route` | route / human |
   | no `role:*`, no `story:*` | `intake` | `po` / `direct` / `human` |
3. **Prompt** (`system` = short fixed instruction per kind, "reply with exactly one JSON object, no prose";
   `user` = issue title, description, labels, notes, last 10 comments, each field and the total capped at
   ~6000 chars; for `chain` also the story doc (capped) and `ls tests/` names; for `route` also the
   `story:` doc header and list of the story's issues with role/stage/status). Request body:
   `{"model":M,"messages":[...],"temperature":0,"stream":false}` via `curl -sS --max-time $SYSTEM1_TIMEOUT
   -H 'Content-Type: application/json' [-H "Authorization: Bearer $KEY"] -d @- "$URL/chat/completions"`.
   Reply text = `.choices[0].message.content`; strip ``` fences and take the first `{...}` object (`jq`).
4. **Schemas & validation** (anything else -> `fail`):
   - route: `{"decision":"route","role":R,"stage":S,"reason":"..."}` or `{"decision":"human","reason":"..."}`.
     `R in po|architect|engineer|qa|reviewer`; `S in design|tests|implement|verify|review|rework`; pair must
     be consistent (po has no stage -> `""`; design<->architect, tests/verify<->qa, implement<->engineer,
     review<->reviewer, rework<->architect|engineer|qa|reviewer). `reason` non-empty.
   - intake: `{"decision":"po|direct|human","reason":"..."}`.
   - chain: `{"skip_design":bool,"skip_tests":bool,"reason":"..."}`; both fields must be JSON booleans and
     `reason` non-empty, else invalid -> `fail`. Deterministic guard (favour inclusion): `skip_tests` is
     honoured only if `tests/` is non-empty; otherwise it is forced to false.
5. **Apply** (`provenance="System 1 (<model> @ <url-host>)"`):
   - *route*: `bd update <id> --remove-label needs-team-lead` (if present), remove existing `role:*`/`stage:*`
     labels, add `role:R` (+ `stage:S`), `bd comment <id> "$provenance routed to role:R stage:S - <reason>"`,
     then `bd unclaim <id>` last. `po` for a story-labelled issue is allowed.
   - *human*: `bd update --append-notes "$provenance: needs a human - <reason>"`, remove `needs-team-lead`,
     add `needs-human`; no unclaim.
   - *intake po*: `bd label add role:po`, comment, `bd unclaim` (exactly today's sweep outcome).
   - *intake direct* (no PO): in `$REPO` (team-lead's clone): `git fetch origin`; if
     `origin/story/<id>` exists reuse it, else `git checkout -B story/<id> origin/main`; write
     `docs/stories/<id>.md` from a fixed template - **title + the issue description verbatim as Context,
     one generic AC ("Given the request in Context, when the work is done, then what it describes is
     resolved; QA derives testable criteria from Context"), Out of scope: "anything the issue does not
     state"; first line flags `Generated without PO from issue <id> - System 1 judged the issue had enough
     context`** (no model-authored content in the doc); `git add` that path only; commit
     `[<id>] Story generated without PO`; `git push -u origin story/<id>`; return to `main`. Then
     `"$KIT_DIR/bin/new-story.sh" <id> "<title>"` (full chain, no skips - sizing is not asked of a 2B model
     here; `HUMAN_APPROVE_STORIES` gating applies as usual), `bd label add <id> story:<id>`, `bd comment`
     (provenance, reason, chain ids from new-story.sh output), `bd close <id>`. A failure at any step ->
     `fail` (leave no half-built chain: git steps happen before `new-story.sh`; if `new-story.sh` fails,
     note the partial output in the `fail` note).
   - *chain*: `git checkout story/<id>` not required; run `new-story.sh <story-id> "<title>" [--skip-design]
     [--skip-tests]`, `bd comment` (provenance, which stages skipped, reason), `bd close`. `<story-id>`
     from the `story:` label; title = issue title with the `<id>: Decide stage chain for ` prefix removed.
6. **`fail "<msg>"`**: `bd update <id> --append-notes "System 1 (<model>) failed: <msg>. Raw output: <first
   2000 chars or '(none)'>"`, remove `needs-team-lead`, add `needs-human`; log; return. The capable
   session is never started (AC5). Covers: curl non-zero/timeout/HTTP error, non-JSON body, empty content,
   no object, schema/enum violation, unconfigured flag, git/new-story failure.

## AC mapping
1: flag unset -> `run_agent` unchanged. 2/AC3': kinds above. 4: URL/model/key from env, same code for DMR
and remote. 5: `fail`. 6: every outcome adds a `bd comment`/note naming model + host + reason. 7: init.sh
pull + README + `.env.example`.

## Error cases
Model returns valid JSON with a hallucinated role -> fail (needs-human, raw output kept). Duplicate run on
an already-handled issue (crash between apply steps): `route`/`human` re-apply idempotently; `direct`
reuses an existing `story/<id>` branch and `docs/stories/<id>.md`; chain: if `bd list --label story:<sid>`
already shows a design/implement issue, `fail` instead of building a second chain.

## Test strategy (QA)
Shell tests with a fake OpenAI server (e.g. `python3 -m http.server`-style or `nc`-driven; tests may reuse
the existing 73cw test's fake) and a stub `bd`/`claude` on PATH, as tests/agent-factory-73cw_test.sh does:
flag-off parity; each kind x each decision; invalid role/stage pair; HTTP 500 / timeout / non-JSON / fenced
JSON accepted; Bearer header only when key set; request path `/chat/completions`, model name; direct intake
creates branch + doc + five issues and closes the original; chain skip flags map to `new-story.sh` flags;
init.sh calls `docker model pull` only when both flags set (stub `docker`). **The existing tests' AC3 cases
assume a po stage in the chain and the old chain schema - they must be rewritten to AC3' above
(`skip_design`/`skip_tests` for chain, `decision: po|direct|human` for intake). Response key names in the
existing test (`role/stage/reason`, `decision`, `needs_human`) already match this design for route.**
