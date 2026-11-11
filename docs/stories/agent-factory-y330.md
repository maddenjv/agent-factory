# agent-factory-y330: System 1 via llama.cpp server container and the `/v1/systemone` API

## Story
As the operator of the factory, I want System 1 to run its model in a llama.cpp server container
and talk to it through llama.cpp's `POST /v1/systemone` endpoint, so that System 1 works even
though Docker Model Runner (DMR) does not support System 1 models.

## Context
- System 1 (`SYSTEM1_ENABLED=1`) currently serves its small model through DMR
  (`SYSTEM1_LOCAL=1` makes `bin/init.sh` pull it via `docker model`) and calls an OpenAI-style
  `.../chat/completions` URL (`bin/system1.sh` for team-lead decisions, `bin/system1-class.sh` for
  model-tier classification). See `docs/ARCHITECTURE.md` (73cw, hcql) and the n2jj/73cw designs.
- DMR cannot serve System 1 models, so that path does not work for them.
- The operator verified the alternative by hand:
  `docker run -d --name decider --gpus all -p 8080:8080 -v ~/.cache/llama.cpp:/root/.cache/llama.cpp
  ghcr.io/ggml-org/llama.cpp:server-cuda -hf ggml-org/vllm-d3-mini-GGUF --host 0.0.0.0 --port 8080`,
  then `curl -X POST http://localhost:8080/v1/systemone -H "Content-Type: application/json"
  -d '{"model":"ai/d3","state":"<query details>","questions":{}}'`.
- The endpoint's request/response contract is the llama.cpp server README section
  "POST /v1/systemone (TypeSafe compatible System One API)"
  (https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md). The design must code
  to that spec; the architect decides how decisions map onto `state`/`questions`.

## Acceptance criteria
1. Given `SYSTEM1_ENABLED=1` and `SYSTEM1_LOCAL=1`, when `bin/init.sh` runs, then the System 1 model
   is made available by starting (or reusing, if already running) a llama.cpp server container
   (`ghcr.io/ggml-org/llama.cpp:server-cuda`, model from `SYSTEM1_MODEL` via `-hf`, port 8080,
   persistent `~/.cache/llama.cpp` cache) and it no longer requires Docker Model Runner
   (`docker model`) to be available.
2. Given System 1 is enabled with the default local configuration, when team-lead makes an
   issue-driven decision via `bin/system1.sh`, then the request is a POST to the llama.cpp
   `/v1/systemone` endpoint (not `/chat/completions`) and the decision (route / po / direct / human)
   is obtained from its response.
3. Given System 1 is enabled, when `bin/agent-loop.sh` classifies an issue into high/medium/low via
   `bin/system1-class.sh`, then that request also uses `/v1/systemone` and yields the same class
   values as before.
4. Given the System 1 endpoint is unreachable, returns an HTTP error, or returns a response that
   cannot be interpreted, when a decision is requested, then behaviour is unchanged from today:
   team-lead decisions end in `needs-human` with a note, and classification falls back to
   `MODEL_MEDIUM`.
5. Given a hosted/remote System 1 endpoint configured via the existing `SYSTEM1_URL` /
   `SYSTEM1_API_KEY` settings, when a decision is requested, then it is still honoured (the URL
   setting continues to select where requests go).
6. Given `SYSTEM1_ENABLED` is unset or 0, when `bin/init.sh` and the agent loop run, then no
   System 1 container is started and no System 1 request is made.
7. Given the change, when a reader consults `docs/ARCHITECTURE.md` and the README System 1
   settings, then they describe the llama.cpp container and `/v1/systemone` instead of DMR.

## Out of scope
- Changing which decisions System 1 makes, or the decision/classification prompts' intent.
- Adding new System 1 decision types.
- CPU-only/non-NVIDIA container variants beyond what is needed to keep init from failing
  clearly (GPU tuning is a follow-up).
- Supporting DMR as a second backend.
