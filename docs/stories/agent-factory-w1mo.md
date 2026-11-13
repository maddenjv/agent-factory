# agent-factory-w1mo: System 1 llama.cpp context and batch size

## Story
As a factory operator running the local System 1 model, I want the llama.cpp server container to
start with a context size of 8192 and batch and micro-batch sizes of 4096, so that System 1
requests have room for their prompts and the server is not limited by the default batch settings.

## Context
- With `SYSTEM1_ENABLED=1` and `SYSTEM1_LOCAL=1`, `bin/init.sh` starts the `factory-s1-llama`
  container (`ghcr.io/ggml-org/llama.cpp:server-cuda`) with `docker run ... -hf "$s1_model" --host 0.0.0.0 --port 8080`.
  No context or batch flags are passed today, so llama.cpp uses its defaults.
- `bin/init.sh` reuses an already-running container whose `-hf` model matches
  (`s1_args` / `docker inspect`), and recreates it only when the model differs. A container started
  before this change would therefore keep the old settings after a re-run of `init.sh` unless the
  reuse check also considers these flags.
- Remote System 1 (`SYSTEM1_LOCAL` unset) is not affected: the factory never starts a container there.

## Acceptance criteria
1. Given `SYSTEM1_ENABLED=1` and `SYSTEM1_LOCAL=1` and no `factory-s1-llama` container exists, when
   `bin/init.sh` runs, then the `docker run` that starts `factory-s1-llama` includes the arguments
   `-c 8192 -b 4096 -ub 4096` in addition to the existing `-hf`, `--host`, `--port` arguments.
2. Given `factory-s1-llama` is running with the expected model and already has `-c 8192 -b 4096
   -ub 4096` in its arguments, when `bin/init.sh` runs, then the container is reused (not recreated)
   and the log says so, as today.
3. Given `factory-s1-llama` exists with the expected model but without `-c 8192 -b 4096 -ub 4096`
   (for example a container created before this change), when `bin/init.sh` runs, then the container
   is removed and recreated with those arguments, and the log says it is being recreated for the
   new settings.
4. Given `factory-s1-llama` exists but is stopped and has the expected model and arguments, when
   `bin/init.sh` runs, then it is started (not recreated), as today.
5. Given `SYSTEM1_ENABLED` or `SYSTEM1_LOCAL` is not `1`, when `bin/init.sh` runs, then no docker
   command is issued for the llama.cpp container, as today.
6. Given `SYSTEM1_LOCAL=1` and the `-hf` model differs from the running container's, when
   `bin/init.sh` runs, then the container is recreated for the new model, as today, and the new
   container is started with `-c 8192 -b 4096 -ub 4096`.
7. Given the change is delivered, then the container start sequence documented in README's
   "System 1 team-lead" section (the `SYSTEM1_LOCAL` paragraph) mentions the context and batch
   sizes the container uses.

## Out of scope
- Making the context size or batch sizes configurable through `.env` or new variables. The values
  are fixed in this story.
- Changing the llama.cpp image, the model, the port, or the GPU flags.
- Tuning these values for any particular GPU or memory size, or checking that the host has enough
  VRAM for them. If the server fails to start with these values, that is an operator issue to
  report separately.
- Changes to the System 1 request format or to `bin/system1.sh` / `bin/system1-class.sh`.
