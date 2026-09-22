#!/usr/bin/env bash
# One-time-per-project setup. Run from the ROOT OF THE PROJECT you want agent-factory to work on
# (see bin/lib.sh) - not from inside this kit's own directory.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

chmod +x "$KIT_DIR"/bin/*.sh

mkdir -p "$DATA_DIR"   # moved up: AGENT_ENV_FILE's project-level candidate must exist to test for
if [ ! -f "$AGENT_ENV_FILE" ]; then
  # AGENT_ENV_FILE only falls back to $KIT_DIR/.env when that file already exists (see lib.sh),
  # so reaching this branch means NEITHER exists yet - starter goes at the project-level path,
  # the location new projects should use going forward.
  cp "$KIT_DIR/.env.example" "$DATA_DIR/.env"
  echo "Created $DATA_DIR/.env - defaults to reusing your host ~/.claude login (no key needed); edit it only if you want a separate CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY instead, then re-run bin/init.sh"
  exit 1
fi
grep -q '^HOST_UID=' "$AGENT_ENV_FILE" || { echo "HOST_UID=$(id -u)" >> "$AGENT_ENV_FILE"; echo "HOST_GID=$(id -g)" >> "$AGENT_ENV_FILE"; }
grep -q '^CONTAINER_HOME=' "$AGENT_ENV_FILE" || echo "CONTAINER_HOME=/home/john" >> "$AGENT_ENV_FILE"

# Checked here, before anything below creates .agent-factory/ (which would otherwise make this
# repo look "dirty" to the same check). bin/init-project.sh commits scaffolding directly to main
# on your behalf next, using explicit paths only - this just makes sure that isn't quietly
# mixed in with unrelated work you have in progress.
if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
  echo "error: $PROJECT_DIR has uncommitted changes. Commit or stash them first, then re-run bin/init.sh." >&2
  exit 1
fi

for r in po architect qa engineer reviewer; do
  mkdir -p "$DATA_DIR/workspaces/$r" "$DATA_DIR/claude/$r"
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

dc run --rm --entrypoint bash agent "$KIT_DIR/bin/init-project.sh"
echo
echo "Done. Next: $KIT_DIR/bin/start.sh"
