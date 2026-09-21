# shellcheck shell=bash
# Sourced inside containers. Points bd at the shared Dolt server.
# NOT sourced during `bd init` (init-project.sh) - init takes these as flags instead,
# because BEADS_DOLT_* env vars have been reported to make `bd init` skip creating .beads/.
export BEADS_DOLT_SERVER_HOST="${BEADS_DOLT_SERVER_HOST:-dolt}"
export BEADS_DOLT_SERVER_PORT="${BEADS_DOLT_SERVER_PORT:-3306}"   # dolt-sql-server image default
export BEADS_DOLT_AUTO_START=0                                     # never spawn a private server in a container
