# agent-factory-lxo0: Run System 1's local model on vLLM in Docker instead of Docker Model Runner

## Story
As an agent-factory operator, I want the local System 1 model to be served by the
`vllm/vllm-openai:latest` Docker image running directly, so that local hosting no longer depends on
Docker Model Runner (which fails for me) and still serves `LiquidAI/d1-2B` over an
OpenAI-compatible API.

## Context
System 1 (`bin/system1.sh`, `bin/system1-class.sh`) talks to an OpenAI-compatible endpoint at
`SYSTEM1_URL`. Today the local default is Docker Model Runner on the host
(`http://host.docker.internal:12434/engines/v1`, model `hf.co/LiquidAI/d1-2B`), and with
`SYSTEM1_ENABLED=1` + `SYSTEM1_LOCAL=1` `bin/init.sh` runs `docker model pull`. Docker Model Runner
fails, so local hosting is unusable. The replacement is the vLLM OpenAI server image
`vllm/vllm-openai:latest` serving the same model, now named by its Hugging Face id
`LiquidAI/d1-2B` (no `hf.co/` prefix). The requests System 1 sends are unchanged; only the backend,
the default URL/model name and how `init.sh` brings the backend up change. The remote-endpoint path
(`SYSTEM1_URL` + `SYSTEM1_API_KEY`, `SYSTEM1_LOCAL` unset) is unaffected. The port is the engineer's
call (vLLM listens on 8000 inside the container); if it differs from 12434, every mention must be
updated: `README.md`, `.env.example`, `docs/ARCHITECTURE.md`, `bin/system1.sh`, `bin/system1-class.sh`,
`docker-compose.yml` comments, `bin/init.sh` messages.

## Acceptance criteria

1. **Given** `SYSTEM1_ENABLED=1` and `SYSTEM1_LOCAL=1` in `.agent-factory/.env`, **When** `bin/init.sh`
   runs, **Then** a container from image `vllm/vllm-openai:latest` serving `SYSTEM1_MODEL` is
   running and reachable from the agent containers at the default `SYSTEM1_URL`, and `init.sh` never
   invokes `docker model`.
2. **Given** `SYSTEM1_LOCAL=1` and `SYSTEM1_MODEL` unset, **When** `bin/init.sh` runs, **Then** the
   model served is `LiquidAI/d1-2B`, and that is also the default model name used by `bin/system1.sh`
   and `bin/system1-class.sh`.
3. **Given** `SYSTEM1_LOCAL=1` and `SYSTEM1_MODEL=<other HF id>`, **When** `bin/init.sh` runs,
   **Then** vLLM serves that model instead.
4. **Given** the vLLM container is already running from a previous `bin/init.sh`, **When**
   `bin/init.sh` is re-run, **Then** it succeeds without error and leaves exactly one vLLM
   container serving the model.
5. **Given** `SYSTEM1_LOCAL=1` but the vLLM container cannot be started (e.g. docker run fails),
   **When** `bin/init.sh` runs, **Then** it exits non-zero with an error message naming the vLLM
   image and the failure.
6. **Given** `SYSTEM1_LOCAL` is unset (flag off or remote endpoint), **When** `bin/init.sh` runs,
   **Then** no vLLM container is started and no `docker model` command is run.
7. **Given** `SYSTEM1_URL` is unset, **When** `bin/system1.sh` and `bin/system1-class.sh` build their
   request, **Then** they target the vLLM endpoint's `/v1/chat/completions`; a set `SYSTEM1_URL`
   still overrides it.
8. **Given** the repository after this change, **When** searching `README.md`, `.env.example`,
   `docs/ARCHITECTURE.md`, `bin/` and `docker-compose.yml`, **Then** there is no remaining reference
   to Docker Model Runner, `docker model`, `hf.co/LiquidAI/d1-2B`, or a port that disagrees with the
   actual default URL's port, and README and `.env.example` describe how to enable local vLLM hosting.

## Out of scope
- GPU/CPU tuning beyond what is needed to make the container serve `LiquidAI/d1-2B`.
- Changing System 1's prompts, decision logic or the remote-endpoint behaviour.
- Pinning or upgrading the vLLM image version (stays `latest`) or changing the model.
- Adding vLLM to `docker-compose.yml` as a mandatory service for users who don't enable System 1.
