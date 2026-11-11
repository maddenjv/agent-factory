> Superseded by agent-factory-n2jj (System 1 local backend reverted to Docker Model Runner).

# Design: agent-factory-lxo0 - System 1 local model on vLLM in Docker

Story: `docs/stories/agent-factory-lxo0.md`. Replaces Docker Model Runner (DMR) with the
`vllm/vllm-openai:latest` container, started by `bin/init.sh`. System 1's requests are unchanged.

## Decisions
- **Host port stays 12434** (published `-p 12434:8000`; vLLM listens on 8000 inside). Agent containers reach it through the
  existing `host.docker.internal:host-gateway` mapping. Keeping 12434 means no port edits anywhere (AC8 "port agrees" holds trivially).
- **Default URL** becomes `http://host.docker.internal:12434/v1` (vLLM serves under `/v1`, not DMR's `/engines/v1`);
  requests go to `<url>/chat/completions` as before.
- **Default model** `LiquidAI/d1-2B` (HF id, no `hf.co/`); vLLM's served model name equals the `--model` id, which is what
  System 1 sends in the request body, so no `--served-model-name` is needed.
- **Container name** `factory-system1` (matches `factory-dolt` style). Not added to `docker-compose.yml` (out of scope: it must not
  be mandatory); `init.sh` manages it with plain `docker run`.
- Image stays `vllm/vllm-openai:latest`; no pinning.

## Changes

### `bin/init.sh` (replace the System 1 block, lines ~74-85)
Condition unchanged: `SYSTEM1_ENABLED=1` and `SYSTEM1_LOCAL=1` (via `s1_val`). Otherwise nothing runs (AC6). `docker model` is
never invoked anywhere.

```bash
S1_IMAGE=vllm/vllm-openai:latest; S1_NAME=factory-system1
s1_model="$(s1_val SYSTEM1_MODEL)"; s1_model="${s1_model:-LiquidAI/d1-2B}"
# idempotent: already running with the same model label -> leave it alone
cur=$(docker inspect -f '{{.State.Running}} {{index .Config.Labels "agent-factory.system1.model"}}' "$S1_NAME" 2>/dev/null || true)
if [ "$cur" = "true $s1_model" ]; then
  echo "System 1: $S1_NAME already serving $s1_model."
else
  docker rm -f "$S1_NAME" >/dev/null 2>&1 || true        # stopped, or serving a different model
  gpu=(); docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia && gpu=(--gpus all)
  hf=(); [ -n "$(s1_val HF_TOKEN)" ] && hf=(-e "HF_TOKEN=$(s1_val HF_TOKEN)")
  echo "Starting System 1 model $s1_model via $S1_IMAGE (first start downloads the model; see: docker logs -f $S1_NAME)..."
  docker run -d --name "$S1_NAME" --restart unless-stopped "${gpu[@]}" --ipc=host \
      -p 12434:8000 -v factory-system1-hf:/root/.cache/huggingface \
      --label "agent-factory.system1.model=$s1_model" "${hf[@]}" \
      "$S1_IMAGE" --model "$s1_model" >/dev/null \
    || { echo "error: failed to start vLLM container ($S1_IMAGE) for $s1_model: docker run failed" >&2; exit 1; }
fi
```
Notes for the engineer: guard empty arrays under `set -u` (use `${gpu[@]+"${gpu[@]}"}`) if the script uses `set -u`.
The container name guarantees "exactly one" vLLM container (AC4); a re-run with the same model is a no-op, a changed model
recreates it. The error message must contain the image name and "failed" (AC5). The named volume avoids root-owned
files in the clone. Do not block waiting for readiness (model download can take minutes); `System 1` already fails safe
(needs-human / MEDIUM fallback) when the endpoint is not yet up. `HF_TOKEN` is optional (gated models) - document it in `.env.example`.

### `bin/system1.sh`, `bin/system1-class.sh`
- Default `SYSTEM1_URL` -> `http://host.docker.internal:12434/v1`; default `SYSTEM1_MODEL` -> `LiquidAI/d1-2B`.
- `system1.sh` header comment: "Docker Model Runner locally" -> "vLLM locally".

### Docs / config
- `.env.example`: update `SYSTEM1_URL`/`SYSTEM1_MODEL` comments and defaults, `SYSTEM1_LOCAL` = "1 = bin/init.sh runs
  `vllm/vllm-openai:latest` serving SYSTEM1_MODEL in container factory-system1 (port 12434)"; add commented optional `HF_TOKEN=`.
- `README.md` (lines ~121, 130-134, 144-148): replace DMR text; "Local" paragraph: set `SYSTEM1_ENABLED=1` + `SYSTEM1_LOCAL=1`, run
  `bin/init.sh`; needs Docker (NVIDIA container toolkit for GPU); first start downloads the model, follow with
  `docker logs -f factory-system1`; stop with `docker rm -f factory-system1`.
- `docs/ARCHITECTURE.md` line 31: "(Docker Model Runner locally, ...)" -> "(vLLM in Docker locally via `bin/init.sh`, ...)".
- `docker-compose.yml` line 64 comment: "(vLLM container on the host, port 12434)".
- Final check: `grep -rniE "model runner|docker model|hf\.co/|engines/v1" README.md .env.example docs/ARCHITECTURE.md bin docker-compose.yml`
  must return nothing.

## Acceptance criteria mapping
1: block above (docker run of image, `--model $s1_model`, port 12434 = default URL, no `docker model`). 2/3: `s1_model` default/override;
defaults in both scripts. 4: name + label check. 5: `|| { ... exit 1 }` message names image. 6: outer condition. 7: new default URL, env override kept.
8: doc edits + grep above.

## Test strategy (QA)
Shell tests with a stub `docker` on PATH logging its argv (pattern in `tests/agent-factory-73cw_test.sh`):
- AC1-3: init with flags -> log has `run ... vllm/vllm-openai:latest --model LiquidAI/d1-2B` (and override id), `-p 12434:8000`, no `docker model`.
- AC4: stub `inspect` returning `true LiquidAI/d1-2B` -> no `run`/`rm`; returning another model or `false x` -> `rm -f` then one `run`.
- AC5: stub `run` exiting 1 -> init exit non-zero, stderr mentions `vllm/vllm-openai`.
- AC6: flag unset / `SYSTEM1_LOCAL` unset -> no `run`, no `docker model`.
- AC7: with stub curl, unset `SYSTEM1_URL` -> request URL `http://host.docker.internal:12434/v1/chat/completions`; override honoured; same for system1-class.sh.
- AC8: the grep above, plus README/.env.example mention `SYSTEM1_LOCAL`.
- **Existing `tests/agent-factory-73cw_test.sh` (lines ~399-425, header comments) asserts `docker model pull hf.co/LiquidAI/d1-2B`
  and README containing `hf.co/LiquidAI/d1-2B`: it must be updated by QA to the vLLM behaviour** (it would otherwise fail and also
  trips AC8's "no remaining reference").
