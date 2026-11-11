# agent-factory-n2jj: Revert System 1's local backend from vLLM to Docker Model Runner (llama.cpp)

## Story
As an agent-factory operator, I want the local System 1 model to be served by Docker Model Runner
(llama.cpp backend) with the GGUF model `hf.co/ggml-org/vllm-d3-mini-GGUF`, so that local hosting
uses DMR only and no vLLM container is involved.

## Context
Story `agent-factory-lxo0` (merged) moved local System 1 hosting from Docker Model Runner (DMR) to
the `vllm/vllm-openai:latest` container (`factory-system1`, host port 12434, model
`LiquidAI/d1-2B`). The requester has decided (approved answers on `agent-factory-n2jj`):
1. vLLM is **reverted**; DMR is the only local backend (not a selectable alternative).
2. The API endpoint is `/engines/v1/systemone` on the DMR host (i.e.
   `http://host.docker.internal:12434/engines/v1/systemone`, same host and port as today). This
   is the base URL; System 1 appends the OpenAI-style `/chat/completions` as it does today. The architect
   must verify the exact resulting request path against how DMR serves it and record it in the
   design; if it cannot be made to work as stated, escalate with `needs-team-lead`.
3. The model `hf.co/ggml-org/vllm-d3-mini-GGUF` exists and is the new default.

The remote-endpoint path (`SYSTEM1_URL` + `SYSTEM1_API_KEY`, `SYSTEM1_LOCAL` unset) is unaffected.
Affected places: `bin/init.sh`, `bin/system1.sh`, `bin/system1-class.sh`, `README.md`, `.env.example`,
`docs/ARCHITECTURE.md`, `docker-compose.yml` comments, and the existing System 1 tests that
`agent-factory-62sg`/`lxo0` updated to vLLM.

## Acceptance criteria

1. **Given** `SYSTEM1_ENABLED=1` and `SYSTEM1_LOCAL=1`, **When** `bin/init.sh` runs, **Then** it
   pulls `SYSTEM1_MODEL` through Docker Model Runner (`docker model pull`) and does not start any
   vLLM container or reference the `vllm/vllm-openai` image.
2. **Given** `SYSTEM1_LOCAL=1` and `SYSTEM1_MODEL` unset, **When** `bin/init.sh` runs, **Then** the
   model pulled is `hf.co/ggml-org/vllm-d3-mini-GGUF`, and that is also the default model name
   used by `bin/system1.sh` and `bin/system1-class.sh`.
3. **Given** `SYSTEM1_LOCAL=1` and `SYSTEM1_MODEL=<other model>`, **When** `bin/init.sh` runs,
   **Then** that model is pulled instead.
4. **Given** `SYSTEM1_LOCAL=1` and the model is already pulled, **When** `bin/init.sh` is re-run,
   **Then** it succeeds without error.
5. **Given** `SYSTEM1_LOCAL=1` but `docker model pull` fails (or DMR is unavailable), **When**
   `bin/init.sh` runs, **Then** it exits non-zero with an error naming Docker Model Runner and the
   failure.
6. **Given** `SYSTEM1_LOCAL` is unset, **When** `bin/init.sh` runs, **Then** no `docker model`
   command is run and no System 1 container is started.
7. **Given** `SYSTEM1_URL` is unset, **When** `bin/system1.sh` and `bin/system1-class.sh` build
   their request, **Then** they target `http://host.docker.internal:12434/engines/v1/systemone`
   (plus the chat-completions suffix as designed); a set `SYSTEM1_URL` still overrides it.
8. **Given** the repository after this change, **When** searching `README.md`, `.env.example`,
   `docs/ARCHITECTURE.md`, `bin/`, `docker-compose.yml` and the System 1 tests, **Then** there is
   no remaining reference to vLLM / `vllm/vllm-openai` / `factory-system1` / `LiquidAI/d1-2B`,
   and README and `.env.example` describe enabling local DMR hosting with the llama.cpp backend.

## Out of scope
- Keeping vLLM as an alternative or selectable backend.
- Changing System 1's prompts, decision logic or remote-endpoint behaviour.
- Changing the model beyond the new default, or tuning DMR/llama.cpp settings.
- Making DMR a mandatory service for users who don't enable System 1.
