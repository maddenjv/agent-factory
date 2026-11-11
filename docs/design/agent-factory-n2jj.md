# Design: agent-factory-n2jj - revert System 1 local backend to Docker Model Runner (llama.cpp)

Story: `docs/stories/agent-factory-n2jj.md`. This undoes `agent-factory-lxo0`/`bwal` (vLLM container) and
restores the pre-`5f6a94d` Docker Model Runner (DMR) flow, with a new default model and URL.

## Decisions
- **Endpoint (AC7).** The requester (john, approved on this issue) states the model card at
  hub.docker.com/r/ai/d3 serves the decision model via `/v1/systemone`, so on DMR it is
  `/engines/v1/systemone`. Default `SYSTEM1_URL=http://host.docker.internal:12434/engines/v1/systemone`.
  Both scripts already append `/chat/completions` (`"${SYSTEM1_URL%/}/chat/completions"`, no code change),
  so the request path is **`/engines/v1/systemone/chat/completions`**. No docker exists in the architect
  container, so this path is taken from the requester, not tested; DMR's public docs list only
  `/engines/v1/...` and `/engines/<backend>/v1/...`. If it 404s in real use the fix is one default
  string (and `SYSTEM1_URL` overrides it meanwhile). Do not add fallback logic.
- **Model (AC2).** Default `SYSTEM1_MODEL=hf.co/ggml-org/vllm-d3-mini-GGUF` everywhere (sent in the
  request body, pulled by init).
- vLLM is removed entirely (no selectable backend). Remote path unchanged.

## Changes
1. `bin/init.sh` (lines ~74-94, the `s1_val` block): restore the DMR block as it was before `5f6a94d`:
   ```bash
   # System 1 (agent-factory-n2jj): with SYSTEM1_ENABLED=1 and SYSTEM1_LOCAL=1, pull the model via
   # Docker Model Runner (llama.cpp backend). Anything else touches no `docker model`.
   s1_val() { ...unchanged... }
   if [ "$(s1_val SYSTEM1_ENABLED)" = 1 ] && [ "$(s1_val SYSTEM1_LOCAL)" = 1 ]; then
     s1_model="$(s1_val SYSTEM1_MODEL)"; s1_model="${s1_model:-hf.co/ggml-org/vllm-d3-mini-GGUF}"
     if ! docker model version >/dev/null 2>&1; then
       echo "error: SYSTEM1_LOCAL=1 needs Docker Model Runner ('docker model' is unavailable). Enable it in Docker Desktop (with TCP on port 12434), or install docker-model-plugin on Docker Engine, then re-run bin/init.sh." >&2
       exit 1
     fi
     echo "Pulling System 1 model $s1_model via Docker Model Runner..."
     docker model pull "$s1_model" || { echo "error: Docker Model Runner: docker model pull $s1_model failed" >&2; exit 1; }
   fi
   ```
   Remove `S1_IMAGE`, `S1_NAME`, `docker inspect/run/rm`, the `HF_TOKEN` handling. Re-run is idempotent
   because `docker model pull` of a present model succeeds (AC4). Errors name "Docker Model Runner" (AC5).
   Flag unset runs no `docker model` and starts no container (AC6).
2. `bin/system1.sh`, `bin/system1-class.sh`: change the two default lines (`SYSTEM1_URL`, `SYSTEM1_MODEL`) as
   above; in `system1.sh` header comment say "Docker Model Runner (llama.cpp) locally" not "vLLM locally".
3. `.env.example`: `SYSTEM1_URL` comment -> default `http://host.docker.internal:12434/engines/v1/systemone`
   (DMR on the host); `SYSTEM1_MODEL` -> default `hf.co/ggml-org/vllm-d3-mini-GGUF`, "also what bin/init.sh
   pulls"; `SYSTEM1_LOCAL` -> "1 = bin/init.sh pulls SYSTEM1_MODEL via Docker Model Runner (llama.cpp backend)";
   delete the `HF_TOKEN` lines.
4. `README.md` "System 1" section: model default, `SYSTEM1_URL` row (default above, "Docker Model Runner on the
   host"), `SYSTEM1_LOCAL` row (`docker model pull $SYSTEM1_MODEL`), and the **Local:** paragraph back to:
   enable DMR with TCP (`docker desktop enable model-runner --tcp 12434` on Docker Desktop; install
   `docker-model-plugin` on Docker Engine; llama.cpp is DMR's backend), set `SYSTEM1_ENABLED=1` and
   `SYSTEM1_LOCAL=1`, run `bin/init.sh` (pulls the model; flag unset pulls nothing). Remove the vLLM/GPU/
   `docker logs`/`docker rm -f factory-system1` text. Remote paragraph unchanged.
5. `docs/ARCHITECTURE.md` line ~31: "(Docker Model Runner (llama.cpp) locally, pulled by `bin/init.sh`, or a hosted endpoint)".
6. `docker-compose.yml` line 64 comment: "System 1 default URL (Docker Model Runner on the host, port 12434)".
7. Docs history: leave `docs/design|stories/agent-factory-lxo0.md` and `-73cw.md` as historical records (AC8 does
   not cover them). Add one line to the top of `docs/design/agent-factory-lxo0.md`: "Superseded by
   agent-factory-n2jj (reverted to Docker Model Runner)." The engineer must not edit the 73cw design.

## Tests (QA)
- Delete `tests/agent-factory-lxo0_test.sh` (it asserts vLLM behaviour) and replace with
  `tests/agent-factory-n2jj_test.sh` covering AC1-AC8 using the existing fake-`docker` log approach in
  `tests/agent-factory-73cw_test.sh` (init section ~l.395-430):
  AC1 `docker model pull <model>` logged, no `docker run`/`vllm` anywhere; AC2 default pull arg is
  `hf.co/ggml-org/vllm-d3-mini-GGUF`; AC3 override; AC4 re-run exit 0; AC5 fake `docker model pull` fails and
  `docker model version` fails -> non-zero, stderr contains "Docker Model Runner"; AC6 flag unset -> docker log
  has no `model` call; AC7 a fake curl or local HTTP stub asserts the URL requested with `SYSTEM1_URL` unset ends
  `/engines/v1/systemone/chat/completions` for both `system1.sh` and `system1-class.sh`, and that a set
  `SYSTEM1_URL` still overrides it; AC8 grep for `vllm|vllm-openai|factory-system1|d1-2B` (case-insensitive)
  over README.md, .env.example, docs/ARCHITECTURE.md, bin/, docker-compose.yml, tests/ (excluding the n2jj test
  itself, which may name them in its grep), plus README/.env.example mention DMR/llama.cpp.
- Update `tests/agent-factory-73cw_test.sh`: the header comments (l.9-12), the `docker run vllm...` assertions
  (l.~400-410, back to `docker model pull`), and the README default-model check (l.425) to the new model.
  Local HTTP stub tests using `http://127.0.0.1:PORT/v1` are unaffected.
- Run the existing suite (`make test` per ARCHITECTURE.md) to confirm no other System 1 test regressed.

## Engineer notes
Single task; no extra issues. Search `grep -rniE 'vllm|factory-system1|d1-2B' bin README.md .env.example docs/ARCHITECTURE.md docker-compose.yml tests` returns nothing at the end (except possibly the n2jj test's own AC8 pattern).
