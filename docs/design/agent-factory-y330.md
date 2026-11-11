# Design: agent-factory-y330 - System 1 via llama.cpp server container and `POST /v1/systemone`

Story: `docs/stories/agent-factory-y330.md`. Supersedes the DMR backend of `n2jj` and the
`/chat/completions` client of `73cw`/`hcql`. Remote hosted endpoints keep working (AC5).

## API contract used (llama.cpp server README, "POST /v1/systemone")
Request: `{"model":..., "state": <string|object|array>, "questions": {"<id>": {"type":"choice"|"score"|"noul",
"instructions":"...", "criteria": {...}}}}`. For `choice`, `criteria` is an object `{option: description}`.
Response: `{"answers": {"<id>": {"choice": "<option>", "probabilities": {...}, "confidence": <num>}}, "usage": {...}}`.
No streaming, no free text (`output_tokens` is always 0). Errors: `400` invalid request, `501` not a decision model.
Consequences: the model **cannot produce a free-text reason** and cannot emit JSON; every decision must be
modelled as one `choice` question. We use only `choice`.

## Decisions
- **Mapping.** `state` = the same issue text built today by `user_prompt` (system.sh) / `$user` (class.sh),
  as a string. The old system prompts become the question `instructions` (reworded, see below).
  One question per call; `questions` is never `{}`.
  - `system1.sh` route: question id `route`, `criteria` keys `po`, `architect/design`, `qa/tests`,
    `engineer/implement`, `qa/verify`, `reviewer/review`, `architect/rework`, `engineer/rework`, `qa/rework`,
    `reviewer/rework`, `human` (value = one-line description of when to pick it).
  - `system1.sh` intake: question id `intake`, keys `po`, `direct`, `human`.
  - `system1-class.sh`: question id `class`, keys `high`, `medium`, `low` (descriptions = the existing
    class definitions).
- **Reason.** There is no model-written reason. `system1.sh` synthesizes it: `REASON="System 1 chose
  <option> (confidence <c>)"` (confidence omitted if absent; formatted with jq `.confidence`). The
  `reason_ok` "decision has no reason" failure is dropped. The `PROV` comments/notes keep working unchanged.
- **Parsing.** `ask_model` stores the HTTP body in `RAW`, then `OPTION=$(jq -er --arg q "$QID"
  '.answers[$q].choice | select(type=="string")')`; failure -> existing "cannot interpret" `fail` path.
  `extract_json`, fence stripping and the old `choices[0].message.content` parsing are removed from
  `system1.sh`. The option is then validated against the allowed set for the question (route: via `stage_ok`
  after splitting `role/stage`; `po` alone = role po, empty stage; `human`; intake: po|direct|human);
  anything else -> `fail "invalid decision ..."`. `do_route`/`do_intake` keep their label/comment/bd logic,
  taking role/stage/decision from the option instead of from a JSON object. `RAW` in the failure note is the
  response body (truncated as today). In `system1-class.sh`, `parse_class` now just reads
  `.answers.class.choice` (still lower-case-trims and accepts only high|medium|low); the JSON-key/bare-word
  tolerance is removed.
- **Endpoint.** `SYSTEM1_URL` is now the **llama.cpp server base URL**; default `http://host.docker.internal:8080`
  (the container below, published on host port 8080; `docker-compose.yml` already has the `host.docker.internal`
  mapping). Both scripts compute (duplicate the 3 lines, no new lib):
  ```bash
  s1_base="${SYSTEM1_URL%/}"
  case "$s1_base" in */systemone) s1_ep="$s1_base" ;; *) s1_ep="$s1_base/v1/systemone" ;; esac
  ```
  so `SYSTEM1_URL` set to a base, to `.../v1/systemone`, or to a legacy DMR-style `.../engines/v1/systemone`
  all post to a `/systemone` path, never `/chat/completions` (AC2/3/5). Header `Authorization: Bearer
  $SYSTEM1_API_KEY` and `SYSTEM1_TIMEOUT` handling unchanged. Body: `jq -n --arg m "$SYSTEM1_MODEL" --arg st
  "$state" --argjson q "$questions" '{model:$m,state:$st,questions:$q}'`.
- **Model default.** `SYSTEM1_MODEL` default becomes `ggml-org/vllm-d3-mini-GGUF` (the `-hf` repo form that
  llama.cpp accepts; `hf.co/` prefix was DMR's form). It is passed to `-hf` by init and sent as `model`
  (the single-model llama.cpp server does not route on it). Change the default in `system1.sh`,
  `system1-class.sh`, `init.sh`, README, `.env.example`.
- **Failure behaviour (AC4).** Unchanged: curl `-f` failure (unreachable, 400/501/5xx) or a body without a
  string `answers.<id>.choice` -> `fail` (needs-human + note) in `system1.sh`; `die`/exit 1 -> `MODEL_MEDIUM`
  fallback in `system1-class.sh`. Off (`SYSTEM1_ENABLED` unset/0) path in `agent-loop.sh` is untouched (AC6).
- **No `agent-loop.sh` change.** It only calls the two scripts.

## `bin/init.sh` (AC1, AC6)
Replace the DMR block (the `s1_val` block, lines ~74-86), keeping `s1_val` and the same
`SYSTEM1_ENABLED=1 && SYSTEM1_LOCAL=1` gate. Container name `factory-s1-llama` (deliberately not
`factory-system1`, which the n2jj test greps for as a vLLM leftover).
```bash
S1_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda; S1_NAME=factory-s1-llama
s1_model="$(s1_val SYSTEM1_MODEL)"; s1_model="${s1_model:-ggml-org/vllm-d3-mini-GGUF}"
command -v docker >/dev/null 2>&1 || { echo "error: SYSTEM1_LOCAL=1 needs docker to run the llama.cpp server container..." >&2; exit 1; }
mkdir -p "$HOME/.cache/llama.cpp"
state=$(docker inspect -f '{{.State.Running}}|{{join .Args " "}}' "$S1_NAME" 2>/dev/null)
```
- `state` is `true|... -hf <model> ...` and contains `$s1_model` -> already running: print "reusing", do nothing.
- `false|...` containing the model -> `docker start "$S1_NAME"`.
- exists with a different model (args lack `$s1_model`) -> `docker rm -f "$S1_NAME"` then run (falls through).
- absent -> run:
  ```bash
  docker run -d --name "$S1_NAME" --restart unless-stopped --gpus all -p 8080:8080 \
    -v "$HOME/.cache/llama.cpp:/root/.cache/llama.cpp" "$S1_IMAGE" \
    -hf "$s1_model" --host 0.0.0.0 --port 8080
  ```
- Any docker failure -> `echo "error: llama.cpp System 1 container: <cmd> failed (needs NVIDIA GPU + nvidia-container-toolkit for --gpus all)" >&2; exit 1`
  (the clear failure the story asks for; no CPU variant). No `docker model` call anywhere. First start downloads
  the model (can take minutes); init does not wait - requests fail meanwhile and fall back as in AC4. Print
  a hint: `docker logs -f factory-s1-llama`.
- Flag unset: no `docker` call at all.

## Docs (AC7)
- `README.md` System 1 section: `SYSTEM1_URL` row = "llama.cpp server base URL (requests go to
  `<url>/v1/systemone`; a URL already ending in `/systemone` is used as is). Default
  `http://host.docker.internal:8080`"; `SYSTEM1_MODEL` default `ggml-org/vllm-d3-mini-GGUF`; `SYSTEM1_LOCAL` row =
  "`bin/init.sh` starts/reuses the `factory-s1-llama` llama.cpp container"; **Local:** paragraph = needs Docker +
  NVIDIA GPU/toolkit, set the two flags, run `bin/init.sh`, cache in `~/.cache/llama.cpp`, `docker logs -f
  factory-s1-llama`; no mention of Docker Model Runner. Mention that the model answers typed multiple-choice
  questions, so decision notes show the chosen option and confidence rather than prose. Remote paragraph: URL
  must serve llama.cpp's `/v1/systemone`.
- `.env.example`: same URL/MODEL/LOCAL comment updates.
- `docs/ARCHITECTURE.md` lines ~28-31: replace "small OpenAI-compatible chat model (Docker Model Runner ...)" with
  "small decision model served by a llama.cpp server container (started by `bin/init.sh`) or a hosted endpoint,
  asked one typed `choice` question via `POST /v1/systemone`"; add one sentence on the hcql classifier using the
  same endpoint.
- `docker-compose.yml` line 64 comment: "System 1 default URL (llama.cpp container published on the host, port 8080)".
- Historical designs (73cw, hcql, n2jj, lxo0) stay unedited.

## Acceptance criteria -> change
1 init.sh block. 2 system1.sh `ask_model`/mapping. 3 system1-class.sh. 4 fail/die paths retained. 5 endpoint
resolution accepts any `SYSTEM1_URL`, auth header kept. 6 gates unchanged. 7 docs above.

## Test strategy (QA)
Existing tests asserting the old contract must be updated, not just added to:
- `tests/agent-factory-73cw_test.sh`, `-hcql_test.sh`: their HTTP stubs return chat-completion JSON and assert
  `/chat/completions`. Change stubs to serve `POST .../v1/systemone` returning
  `{"answers":{"route":{"choice":"engineer/implement","confidence":0.9,"probabilities":{}}},"usage":{}}`
  (id by question: `route`/`intake`/`class`), and assert path ends `/v1/systemone`.
- `tests/agent-factory-n2jj_test.sh`: assertions for DMR (`docker model pull`, URL `.../12434/engines/...`,
  "Docker Model Runner" in README) are obsolete: delete/replace them with y330 equivalents; keep its
  "no vllm / d1-2B leftovers" check (our container name does not match it).
- New `tests/agent-factory-y330_test.sh`, using a local HTTP stub (as 73cw) and the fake-`docker` log approach:
  - request: path `/v1/systemone`, body has `model`, string `state` containing the issue id, non-empty
    `questions.<route|intake|class>.type=="choice"` with `criteria` keys exactly as listed above;
  - each route option -> expected labels (`role:`/`stage:`), `human` -> `needs-human`, intake po/direct/human,
    class high/medium/low; synthesized reason in the `bd comment` contains the option;
  - failures: connection refused, HTTP 400, 501, missing `answers`, `choice` not in allowed set (e.g. `"banana"`,
    `"qa/design"`) -> needs-human with note (system1.sh) / exit 1 + empty stdout (class.sh);
  - endpoint resolution: base URL, URL ending `/v1/systemone`, trailing slash, with/without `SYSTEM1_API_KEY`
    (Authorization header present only when set); default (URL unset) posts to
    `http://host.docker.internal:8080/v1/systemone` (use fake curl logging the URL);
  - init: with fake `docker`: absent container -> `docker run` args include `ghcr.io/ggml-org/llama.cpp:server-cuda`,
    `-hf <model>` (default and `SYSTEM1_MODEL` override), `-p 8080:8080`, `--gpus all`, the
    `.cache/llama.cpp` mount, `--host 0.0.0.0 --port 8080`; running with same model -> no `docker run`; stopped
    -> `docker start`; different model -> `rm -f` then `run`; no `docker model` call ever; `docker` missing or
    `docker run` failing -> non-zero with a clear stderr message; flag unset (or `SYSTEM1_LOCAL` unset) -> no
    docker call at all; re-run exit 0;
  - docs: grep README/.env.example/ARCHITECTURE.md for `systemone` and `llama.cpp`, and no `Docker Model Runner`/
    `docker model`/`12434` in README, `.env.example`, `docs/ARCHITECTURE.md`, `bin/`, `docker-compose.yml`.
- Run the full suite (`make test`) to confirm nothing else regressed.

## Engineer notes
Single implement task; no extra issues. Real-GPU behaviour (and the exact response for the chosen model) is
untestable in the container; the spec above is the contract, and `SYSTEM1_URL` lets the operator override.
