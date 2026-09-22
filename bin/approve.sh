#!/usr/bin/env bash
# Usage: approve.sh <issue-id>...  - clear needs-human so agents will pick the issue up again.
set -euo pipefail
DATA_DIR="${DATA_DIR:-$PWD/.agent-factory}"
for id in "$@"; do
  bd label remove "$id" needs-human
  bd update "$id" --status open >/dev/null 2>&1 || true
  rm -f "$DATA_DIR"/control/state/*/attempts."$id" 2>/dev/null || true
  echo "released $id"
done
