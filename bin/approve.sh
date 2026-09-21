#!/usr/bin/env bash
# Usage: approve.sh <issue-id>...  - clear needs-human so agents will pick the issue up again.
set -euo pipefail
for id in "$@"; do
  bd label remove "$id" needs-human
  bd update "$id" --status open >/dev/null 2>&1 || true
  rm -f /work/control/state/*/attempts."$id" 2>/dev/null || true
  echo "released $id"
done
