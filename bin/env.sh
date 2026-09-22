# shellcheck shell=bash
# Sourced inside containers. KIT_DIR (this repo), PROJECT_DIR (the real project) and DATA_DIR
# (PROJECT_DIR/.agent-factory, agent-factory's own runtime state) all arrive as environment
# variables from docker-compose.yml - both directories are bind-mounted at these same absolute
# paths, so no path translation between host and container is needed. This file is for the
# BEADS_DOLT_* defaults below; the DATA_DIR fallback just keeps board.sh/ops-shell.sh/approve.sh
# working if one of them is ever run without the compose environment (e.g. by hand for debugging).
export DATA_DIR="${DATA_DIR:-$PWD/.agent-factory}"

# Points bd at the shared Dolt server.
# NOT sourced during `bd init` (init-project.sh) - init takes these as flags instead,
# because BEADS_DOLT_* env vars have been reported to make `bd init` skip creating .beads/.
export BEADS_DOLT_SERVER_HOST="${BEADS_DOLT_SERVER_HOST:-dolt}"
export BEADS_DOLT_SERVER_PORT="${BEADS_DOLT_SERVER_PORT:-3306}"   # dolt-sql-server image default
export BEADS_DOLT_AUTO_START=0                                     # never spawn a private server in a container
