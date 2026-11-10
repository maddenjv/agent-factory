# Design: agent-factory-hcql - per-task model class selection (System 1)

## Approach
Before each issue session, `bin/agent-loop.sh` picks the harness `--model` from three operator-configured
class models (`MODEL_HIGH` / `MODEL_MEDIUM` / `MODEL_LOW`). A small System 1 model classifies the issue as
`high|medium|low`; any problem degrades to `MODEL_MEDIUM`, then to the role's existing default. Selection
is per session, in the loop, not in the harness; nothing mid-session.

## Files
- **new `bin/system1-class.sh <issue-id>`** - classifier only. Contract: prints exactly one of
  `high|medium|low` on stdout and exits 0; on ANY problem prints nothing on stdout, one-line reason on
  stderr, exits 1. It never touches bd labels/notes (so AC3 "not needs-human" holds by construction) and
  never exits the loop. Standalone (do NOT `source` `system1.sh`: it ends with an unconditional `exit 0`).
  - Config: same defaults as system1.sh (`SYSTEM1_URL` default `http://host.docker.internal:12434/engines/v1`,
    `SYSTEM1_MODEL` default `hf.co/LiquidAI/d1-2B`, `SYSTEM1_API_KEY`, `SYSTEM1_TIMEOUT` default 60).
    Empty URL or model after defaults -> reason `not configured`.
  - Input: `bd show <id> --json | bd_unwrap | jq` (as system1.sh): id, title, labels (incl. role/stage),
    description and notes, each capped at 6000 chars. No story doc, no comments (keep prompt small, fast).
  - Request: identical transport to `system1.sh` `ask_model` (`POST $URL/chat/completions`, `temperature:0`,
    `stream:false`, Bearer key if set, `curl -sS -f --connect-timeout 10 --max-time $SYSTEM1_TIMEOUT`).
    System prompt (first working version): "You choose which cost class of model a software task needs.
    low = trivial/mechanical (doc or comment edit, one-line fix, rename, config tweak). medium = ordinary
    feature, bug fix or test work in a known area. high = hard: new architecture or cross-cutting design,
    subtle debugging, security, large refactor. Reply with exactly one word: high, medium or low."
  - Parse: reply text = `.choices[0].message.content`; lowercase, strip ``` fences, whitespace, quotes and
    trailing punctuation; accept only if the whole result equals `high`, `medium` or `low` (a leading
    `class:`/JSON is NOT accepted; stay strict). Anything else (empty, prose, other word) -> reason
    `unparseable answer: <first 80 chars>`. Transport failure -> `request failed (curl exit N)`; non-chat
    body -> `response is not a chat completion`.
  - Guard `main` with `[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"` and do not end with a bare `exit`
    after it, so tests may source it.
- **`bin/agent-loop.sh`**
  1. Model resolution block (lines ~58-63): keep as is, but also record `MODEL_PINNED=1` when
     `${!model_var}` is non-empty (explicit `MODEL_<ROLE>`), else `0`. `MODEL` stays the role default.
  2. New `choose_model ID` (define near `run_agent`): echoes nothing; sets global `SESSION_MODEL` and logs
     one line. Algorithm:
     ```
     if MODEL_PINNED=1:            SESSION_MODEL=$MODEL; log "model: $id class=- source=pinned(MODEL_<ROLE>) model=$MODEL"
     elif no MODEL_HIGH/MEDIUM/LOW set (all empty):  SESSION_MODEL=$MODEL; log "... source=default (no class models set) ..."
                                   # no System 1 request: class is irrelevant (AC7, saves a call)
     else
       class=""; src=""
       if SYSTEM1_ENABLED=1:  class=$("$KIT_DIR/bin/system1-class.sh" "$id" 2>$errtmp); rc=$?
           rc=0 -> src=system1
           rc!=0 -> class=medium; src="fallback(<stderr reason>)"
       else:                   class=medium; src="fallback(system1 disabled)"   # no request made (AC2)
       m=${!class_var}                       # MODEL_HIGH|MEDIUM|LOW
       if m empty: SESSION_MODEL=$MODEL; log "... class=$class source=$src model=<default: ${MODEL:-harness default}> (MODEL_$CLASS empty, using role default)"
       else:       SESSION_MODEL=$m;   log "... class=$class source=$src model=$m"
     ```
     Log format (single line, via `log`, one_line-sanitised reason): 
     `model: <id> class=<high|medium|low|-> source=<system1|fallback(<reason>)|pinned|default> model=<name>`.
     When the class var was empty the line also contains `MODEL_<CLASS> empty, using role default` (AC4).
     "System 1 enabled" for this purpose = `SYSTEM1_ENABLED=1` only; URL/model defaults make the rest resolvable,
     and empty URL/model is reported by system1-class.sh as a fallback reason.
  3. `run_agent`: team-lead with `SYSTEM1_ENABLED=1` keeps its system1.sh branch untouched (no harness, no
     choose_model). Otherwise call `choose_model "$1"` then run the harness with the chosen model. Because
     `run_harness_session` also serves `run_throttle_assessment`, which must NOT be affected, pass the model
     explicitly: `run_harness_session` takes the model from `${SESSION_MODEL-$MODEL}` and `run_agent` sets
     `SESSION_MODEL` before and `unset SESSION_MODEL` after the call; the throttle path never sets it, so it
     uses `$MODEL` as today. Both `--model` sites (copilot, claude) use that value; `[ -n ... ]` guard kept so
     an empty value means "no --model flag" (harness default), as today.
  4. Startup log line (`started: ... model=`) unchanged (shows role default).
- **`.env.example`** - new block after the per-role models: `MODEL_HIGH=`, `MODEL_MEDIUM=`, `MODEL_LOW=`
  (empty, no trailing comments on value lines), comments stating: class models are consulted per session
  when System 1 is enabled; fallback rule (System 1 off/failing/invalid -> MEDIUM; chosen class empty ->
  role default); explicit `MODEL_<ROLE>` wins and skips System 1; values are harness model names.
  Check `docker-compose.yml` passes `.env` via `env_file` (SYSTEM1_* already do); no change expected.
- **`README.md`** System 1 section: add a "Per-task model class" paragraph + the three vars in the table.
- **`docs/ARCHITECTURE.md`** System 1 paragraph (done in this design commit): mention the classification
  decision and `bin/system1-class.sh`.

## Acceptance criteria mapping
1. enabled + set + answer -> `choose_model` uses `${MODEL_<CLASS>}` -> `--model`.
2. not enabled -> class=medium, no curl (system1-class.sh not called); `MODEL_MEDIUM` used.
3. non-zero exit from the classifier (curl failure/timeout/HTTP error/unparseable) -> medium; log contains
   `fallback(<reason>)`; the classifier touches no labels.
4. empty class model -> `$MODEL` (role default), log says so.
5. `MODEL_PINNED=1` -> classifier not called.
6. one log line per session (format above) via `log` (to loop.log).
7. nothing set -> all-empty branch -> `SESSION_MODEL=$MODEL`, no request, identical `--model` as today.
8. docs as listed.

## Error cases
Empty/odd `bd show` output -> classifier reason `cannot read issue`; fallback medium. `jq`/`curl` missing ->
treated as failure, fallback. Reason strings are logged only, never put in bd.

## Test strategy (QA)
Shell tests in `tests/` style of `agent-factory-73cw_test.sh` (stub `curl` and `bd` on PATH, stub
`claude`/`copilot` to record argv).
- Unit, `system1-class.sh`: stub curl replying `high`, ` Medium. `, `"low"`, fenced; prose, empty, `HIGH or low`
  -> exit 1; curl exit non-zero; HTTP error; non-JSON body; empty URL; request body contains issue title and
  Bearer header only when key set.
- Unit, `choose_model` (source agent-loop functions the way existing tests do, or run the loop one iteration
  with stubs): AC1 each class; AC2 asserts curl stub never invoked; AC3 each failure kind logs fallback and
  uses MEDIUM and no `needs-human` label; AC4 empty class var and empty MEDIUM; AC5 pinned role var, stub
  curl not called; AC6 log line fields; AC7 clean env -> `--model` argv identical to today (sonnet/opus) and
  no curl; team-lead with `SYSTEM1_ENABLED=1` still goes to system1.sh; throttle assessment argv uses role
  default even when class vars are set.
- Docs (AC8): grep `.env.example` for the three vars, README and ARCHITECTURE for the decision.
