#!/usr/bin/env bash
# One-time-per-project setup. Run from the ROOT OF THE PROJECT you want agent-factory to work on
# (see bin/lib.sh) - not from inside this kit's own directory.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --harness=<claude-code|copilot> selects which harness CLI every role runs on. Validated here,
# before anything below touches the filesystem, so a bad value never creates so much as $DATA_DIR.
HARNESS_FLAG=""
for arg in "$@"; do
  case "$arg" in
    --harness=*) HARNESS_FLAG="${arg#--harness=}" ;;
    *) echo "error: unrecognized argument: $arg (expected --harness=claude-code or --harness=copilot)" >&2; exit 1 ;;
  esac
done
case "$HARNESS_FLAG" in
  ""|claude-code|copilot) ;;
  *) echo "error: --harness must be 'claude-code' or 'copilot' (got '$HARNESS_FLAG')" >&2; exit 1 ;;
esac

# Dependency check, also before anything touches the filesystem: lib.sh's dc() runs
# `docker compose -f ...`, and without the Compose plugin Docker's error is about that flag.
if ! command -v docker >/dev/null 2>&1; then
  echo "error: Docker is not installed (or not on PATH). Install Docker with the Compose plugin, then re-run bin/init.sh." >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "error: Docker Compose (the 'docker compose' plugin) is not available. Install the Docker Compose plugin, then re-run bin/init.sh." >&2
  exit 1
fi

chmod +x "$KIT_DIR"/bin/*.sh

mkdir -p "$DATA_DIR"   # moved up: AGENT_ENV_FILE's project-level candidate must exist to test for
if [ ! -f "$AGENT_ENV_FILE" ]; then
  # AGENT_ENV_FILE only falls back to $KIT_DIR/.env when that file already exists (see lib.sh),
  # so reaching this branch means NEITHER exists yet - starter goes at the project-level path,
  # the location new projects should use going forward.
  cp "$KIT_DIR/.env.example" "$DATA_DIR/.env"
  # Defaults to Claude Code. Only appended when it differs from that default: an unconditional
  # append would make the freshly-created .env diverge from .env.example's starter contents even
  # on the plain no-flag path (see tests/acceptance/agent-factory-jqn.sh's AC4, which diffs the
  # two). The default is still guaranteed - the append block below (every run after the first)
  # unconditionally records HARNESS=claude-code if no HARNESS= line exists yet.
  default_harness="${HARNESS_FLAG:-claude-code}"
  [ "$default_harness" = "claude-code" ] || echo "HARNESS=$default_harness" >> "$DATA_DIR/.env"
  # lib.sh resolved AGENT_ENV_FILE to the not-yet-existing $KIT_DIR/.env fallback; re-point it so
  # the appends below and every dc call use the file just created.
  AGENT_ENV_FILE="$DATA_DIR/.env"; export AGENT_ENV_FILE
  # shellcheck disable=SC2088  # literal ~ is intended: it is display text, not a path
  if [ "$default_harness" = "copilot" ]; then
    harness_login="~/.copilot login (run 'copilot login' on the host if needed)"
    harness_tokens="COPILOT_GITHUB_TOKEN / GH_TOKEN / GITHUB_TOKEN"
  else
    harness_login="~/.claude login"
    harness_tokens="CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY"
  fi
  echo "Created $DATA_DIR/.env with defaults (reuses your host $harness_login - no edits needed). Optional settings ($harness_tokens, models, budget) can be edited there; if you change any, re-run bin/init.sh afterwards. Continuing setup..."
fi
grep -q '^HOST_UID=' "$AGENT_ENV_FILE" || echo "HOST_UID=$(id -u)" >> "$AGENT_ENV_FILE"
grep -q '^HOST_GID=' "$AGENT_ENV_FILE" || echo "HOST_GID=$(id -g)" >> "$AGENT_ENV_FILE"
grep -q '^HOST_USER=' "$AGENT_ENV_FILE" || echo "HOST_USER=$(id -un)" >> "$AGENT_ENV_FILE"
grep -q '^CONTAINER_HOME=' "$AGENT_ENV_FILE" || echo "CONTAINER_HOME=/home/$(id -un)" >> "$AGENT_ENV_FILE"
if [ -n "$HARNESS_FLAG" ]; then
  if grep -q '^HARNESS=' "$AGENT_ENV_FILE"; then
    sed -i "s/^HARNESS=.*/HARNESS=$HARNESS_FLAG/" "$AGENT_ENV_FILE"
  else
    echo "HARNESS=$HARNESS_FLAG" >> "$AGENT_ENV_FILE"
  fi
else
  grep -q '^HARNESS=' "$AGENT_ENV_FILE" || echo "HARNESS=claude-code" >> "$AGENT_ENV_FILE"
fi

# System 1 (agent-factory-y330): with SYSTEM1_ENABLED=1 and SYSTEM1_LOCAL=1, start (or reuse) a llama.cpp
# server container that serves the model for POST /v1/systemone. Anything else makes no docker call.
s1_val() { grep -E "^$1=" "$AGENT_ENV_FILE" | tail -1 | cut -d= -f2- | sed -E 's/^["'"'"']|["'"'"']$//g'; }
if [ "$(s1_val SYSTEM1_ENABLED)" = 1 ] && [ "$(s1_val SYSTEM1_LOCAL)" = 1 ]; then
  S1_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda; S1_NAME=factory-s1-llama
  s1_model="$(s1_val SYSTEM1_MODEL)"; s1_model="${s1_model:-ggml-org/vllm-d3-mini-GGUF}"
  command -v docker >/dev/null 2>&1 || { echo "error: SYSTEM1_LOCAL=1 needs docker to run the llama.cpp server container ($S1_IMAGE), but 'docker' was not found." >&2; exit 1; }
  s1_fail() { echo "error: llama.cpp System 1 container: $1 failed (needs an NVIDIA GPU + nvidia-container-toolkit for --gpus all)" >&2; exit 1; }
  mkdir -p "$HOME/.cache/llama.cpp"
  s1_state=$(docker inspect -f '{{.State.Running}}' "$S1_NAME" 2>/dev/null) || s1_state=""
  s1_args=""; [ -z "$s1_state" ] || s1_args=$(docker inspect -f '{{join .Args " "}}' "$S1_NAME" 2>/dev/null) || s1_args=""
  s1_start=run
  if [ -n "$s1_state" ]; then
    # recreate only if the container's -hf model demonstrably differs
    if [[ "$s1_args" != *-hf* || "$s1_args" == *"$s1_model"* ]]; then
      if [ "$s1_state" = true ]; then
        echo "Reusing running System 1 container $S1_NAME ($s1_model)."; s1_start=none
      else
        s1_start=start
      fi
    else
      docker rm -f "$S1_NAME" >/dev/null || s1_fail "docker rm -f $S1_NAME"
    fi
  fi
  case "$s1_start" in
    start) echo "Starting existing System 1 container $S1_NAME..."
      docker start "$S1_NAME" >/dev/null || s1_fail "docker start $S1_NAME" ;;
    run) echo "Starting System 1 llama.cpp container $S1_NAME ($s1_model); first start downloads the model."
      docker run -d --name "$S1_NAME" --restart unless-stopped --gpus all -p 8080:8080 \
        -v "$HOME/.cache/llama.cpp:/root/.cache/llama.cpp" "$S1_IMAGE" \
        -hf "$s1_model" --host 0.0.0.0 --port 8080 >/dev/null || s1_fail "docker run $S1_IMAGE" ;;
  esac
  [ "$s1_start" = none ] || echo "Follow model download/startup with: docker logs -f $S1_NAME"
fi

# .agent-factory/ is excluded: this script creates it (untracked until init-project.sh
# gitignores it), so it must not make a re-run look "dirty". bin/init-project.sh commits scaffolding directly to main
# on your behalf next, using explicit paths only - this just makes sure that isn't quietly
# mixed in with unrelated work you have in progress.
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain -- . ":(exclude)${DATA_DIR#"$PROJECT_DIR"/}")" ]; then
  echo "error: $PROJECT_DIR has uncommitted changes. Commit or stash them first, then re-run bin/init.sh." >&2
  exit 1
fi

for r in "${FACTORY_ROLES[@]}"; do
  mkdir -p "$DATA_DIR/workspaces/$r" "$DATA_DIR/claude/$r" "$DATA_DIR/copilot/$r"
done
mkdir -p "$DATA_DIR/dolt" "$DATA_DIR/logs" "$DATA_DIR/control"

# Lets the reviewer's final `git push origin main` update this repo's checked-out files
# directly, since all 5 agents clone from and push back to it (see bin/lib.sh, README).
# Only affects pushes to the branch currently checked out here; other branches push normally.
# It will refuse (loudly) if this working tree is dirty at push time.
git -C "$PROJECT_DIR" config receive.denyCurrentBranch updateInstead

dc build agent
dc up -d dolt
echo "Waiting for Dolt..."
for _ in $(seq 30); do
  dc exec -T dolt dolt sql -q "select 1" >/dev/null 2>&1 && break
  sleep 2
done

# Identity for init-project.sh's scaffolding commit. The container can't see your ~/.gitconfig,
# so resolve it here (git's own lookup, all levels, from PROJECT_DIR) and pass it in as env vars
# - which, unlike `git config`, never write anything to your git configuration. Each half falls
# back on its own, so having only user.name or only user.email set still works.
git_name=$(git -C "$PROJECT_DIR" config user.name 2>/dev/null || true)
git_email=$(git -C "$PROJECT_DIR" config user.email 2>/dev/null || true)
git_name=${git_name:-${GIT_AUTHOR_NAME:-agent-factory}}
git_email=${git_email:-${GIT_AUTHOR_EMAIL:-agent-factory@factory.local}}

dc run --rm \
  -e GIT_AUTHOR_NAME="$git_name" -e GIT_AUTHOR_EMAIL="$git_email" \
  -e GIT_COMMITTER_NAME="$git_name" -e GIT_COMMITTER_EMAIL="$git_email" \
  --entrypoint bash agent "$KIT_DIR/bin/init-project.sh"
echo
echo "Done. Next: $KIT_DIR/bin/start.sh"
