# shellcheck shell=bash
# Sourced by every host-side bin/*.sh script (NOT by things that run inside a container, e.g.
# agent-loop.sh, board.sh - those get KIT_DIR/PROJECT_DIR/DATA_DIR from docker-compose's
# environment: block instead, since by then the two directories are just two bind mounts).
#
# Two roots, deliberately kept separate:
#   KIT_DIR     - this repo (docker-compose.yml, bin/, agents/), wherever it's checked out.
#   PROJECT_DIR - the real project you're pointing agent-factory at: wherever you `cd`'d before
#                 running bin/start.sh etc. Must be an existing git repo - that's what all 5
#                 agents clone from and (only the reviewer) push back to.
# All of agent-factory's own runtime state (workspaces, control, logs, claude config, the Dolt
# database) lives under PROJECT_DIR/.agent-factory, not inside KIT_DIR - so stories, designs and
# the beads database travel with the project, and re-running against a different project starts
# clean instead of mixing the two projects' issues together.
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

toplevel=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) || {
  echo "error: $PROJECT_DIR is not a git repository." >&2
  echo "cd into the project you want agent-factory to work on, then re-run this command." >&2
  exit 1
}
PROJECT_DIR="$toplevel"   # always the repo root, even if you ran this from a subdirectory

DATA_DIR="$PROJECT_DIR/.agent-factory"
export KIT_DIR PROJECT_DIR DATA_DIR

dc() {  # dc <docker compose args...> - always targets the kit's compose file, from PROJECT_DIR
  docker compose -f "$KIT_DIR/docker-compose.yml" "$@"
}
