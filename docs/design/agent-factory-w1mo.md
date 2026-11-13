# Design: agent-factory-w1mo - System 1 llama.cpp context and batch size

Story: `docs/stories/agent-factory-w1mo.md`. Builds on `docs/design/agent-factory-y330.md` (the
`factory-s1-llama` block in `bin/init.sh`). Change is confined to that block, README and tests.
No `.env` variable, no change to `bin/system1*.sh`, `agent-loop.sh`, `.env.example` or `docker-compose.yml`.

## Decisions
- **Fixed flags, one definition.** Inside the existing `SYSTEM1_ENABLED=1 && SYSTEM1_LOCAL=1` block, next to
  `S1_IMAGE`/`S1_NAME`, add
  ```bash
  S1_OPTS="-c 8192 -b 4096 -ub 4096"   # llama.cpp context / batch / micro-batch (agent-factory-w1mo)
  ```
  It is used both for `docker run` and for the reuse check, so they cannot drift. Short llama.cpp flag
  spellings (`-c`, `-b`, `-ub`) exactly as in the AC, in that order, space-separated.
- **`docker run`** (AC1, AC6): append the options after the existing server args, unquoted so they split
  into words (the value contains no globs):
  ```bash
  -hf "$s1_model" --host 0.0.0.0 --port 8080 $S1_OPTS >/dev/null || s1_fail "docker run $S1_IMAGE" ;;
  ```
  Image, `--gpus all`, `-p 8080:8080`, mount, `--restart`, name: unchanged.
- **Reuse check** (AC2-4, AC6). `s1_args` (from `docker inspect -f '{{join .Args " "}}'`) is already read.
  Keep the existing "only act on demonstrable differences" rule: if `s1_args` does not contain `-hf` (args
  unreadable/unknown) treat it as matching, exactly as the model check does today. Replace the `if [ -n
  "$s1_state" ]` body with:
  ```bash
  if [ -n "$s1_state" ]; then
    s1_recreate=""
    if [[ "$s1_args" == *-hf* ]]; then
      if [[ "$s1_args" != *"$s1_model"* ]]; then
        s1_recreate="for model $s1_model"
      elif [[ " $s1_args " != *" $S1_OPTS "* ]]; then
        s1_recreate="for new settings ($S1_OPTS)"
      fi
    fi
    if [ -n "$s1_recreate" ]; then
      echo "Recreating System 1 container $S1_NAME $s1_recreate."
      docker rm -f "$S1_NAME" >/dev/null || s1_fail "docker rm -f $S1_NAME"
    elif [ "$s1_state" = true ]; then
      echo "Reusing running System 1 container $S1_NAME ($s1_model)."; s1_start=none
    else
      s1_start=start
    fi
  fi
  ```
  `s1_start` stays `run` after a recreate, so the existing `run)` branch starts the new container (with
  `$S1_OPTS`). Model check comes first: a model change is the more important message; either way the new
  container gets both the new model and the options.
  - The settings match is a whole-word substring of the joined args (`" $s1_args "` padded so `-c 8192` cannot
    match e.g. `-c 81920`). A container whose args carry the same values in a different order or with long
    spellings (`--ctx-size`) is recreated once; acceptable, the factory only ever creates them in this form.
  - A **stopped** container with the right model but old settings is recreated (AC3 says "exists"), not started.
  - Log lines: AC2 keeps the existing "Reusing running System 1 container ..." text verbatim; AC3's message is
    `Recreating System 1 container factory-s1-llama for new settings (-c 8192 -b 4096 -ub 4096).`; AC6 gains
    `Recreating System 1 container factory-s1-llama for model <model>.` (previously silent; harmless addition).
    The following "Starting System 1 llama.cpp container ..." and `docker logs -f` hint are unchanged.
- **Gate** (AC5): unchanged - nothing new runs outside the `if`.
- Update the block's header comment to mention w1mo: "... start (or reuse) a llama.cpp server container
  (fixed -c/-b/-ub, agent-factory-w1mo) ...".

## Docs (AC7)
README "System 1 team-lead" section, the **Local:** paragraph: change the container description to
``(`ghcr.io/ggml-org/llama.cpp:server-cuda`, `-hf $SYSTEM1_MODEL`, context size 8192 (`-c 8192`), batch and
micro-batch size 4096 (`-b 4096 -ub 4096`), port 8080, model cache in `~/.cache/llama.cpp`)`` and append to
"re-running is safe": "; an existing container whose model or these settings differ is recreated". The
`SYSTEM1_LOCAL` table row may stay as is. `docs/ARCHITECTURE.md` needs no change (it does not list server flags).

## Acceptance criteria -> change
1 `S1_OPTS` on `docker run`. 2 reuse branch unchanged when args contain model + `S1_OPTS`. 3 settings
recreate branch + message. 4 `start` branch when stopped and matching. 5 gate untouched. 6 model recreate
branch, then `run` with `S1_OPTS`. 7 README Local paragraph.

## Test strategy (QA)
New `tests/agent-factory-w1mo_test.sh`, same harness style as `tests/agent-factory-y330_test.sh` (copy kit to a
temp dir, fake `docker` on `PATH`, `DOCKER_LOG`, `DSTATE`). **The fake `docker inspect` must answer by format**
(the y330/n2jj stubs return `true|<args>` for every format, which hides the running/stopped distinction):
`-f '{{.State.Running}}'` -> `true`/`false` from `$DSTATE`, `-f '{{join .Args " "}}'` -> the args stored in
`$DSTATE` (seedable by the test to simulate a pre-existing container), missing container -> exit 1. Cases:
- AC1: no container -> exactly one `docker run`, whose argv contains `-hf <default model>`, `--host 0.0.0.0`,
  `--port 8080` and `-c 8192 -b 4096 -ub 4096` (as consecutive words); also with a `SYSTEM1_MODEL` override.
- AC2: seeded running, args `-hf <model> --host 0.0.0.0 --port 8080 -c 8192 -b 4096 -ub 4096` -> no `run`, no
  `rm`, no `start`; output contains "Reusing running System 1 container".
- AC3: seeded running (and separately stopped), args without the flags -> `rm -f factory-s1-llama` then `run` with
  the flags; output contains "Recreating" and "settings". Also partial/different values (e.g. `-c 4096 -b 4096
  -ub 4096`, `-c 81920 ...`) -> recreated.
- AC4: seeded stopped with model + flags -> `docker start factory-s1-llama`, no `run`/`rm`.
- AC5: `SYSTEM1_ENABLED` unset/0, `SYSTEM1_LOCAL` unset/0 -> no docker line mentioning `llama`/`factory-s1`.
- AC6: seeded running with other model + flags -> `rm -f` then `run` with new `-hf` and the flags; output
  contains "Recreating".
- Idempotence: init twice from scratch -> one `run`, second run reuses, rc 0 both times.
- AC7: README Local paragraph contains `8192` and `4096` (e.g. grep `-c 8192` and `-b 4096 -ub 4096`).
**Existing test to update:** `tests/agent-factory-n2jj_test.sh`'s stub `inspect` hard-codes
`-hf <model> --host 0.0.0.0 --port 8080`; after this change its AC4 re-run would see "old settings" and recreate.
Append ` -c 8192 -b 4096 -ub 4096` to that echoed string (that is updating its stub to the new contract, not
weakening it). `tests/agent-factory-y330_test.sh` stores the real `docker run` argv, so it should keep passing;
confirm with `make test`.

## Engineer notes
Single implement task (agent-factory-xrha); no extra issues. Real llama.cpp/GPU behaviour is not testable in the
container; the flags are the contract.
