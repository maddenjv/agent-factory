#!/usr/bin/env bash
# Usage: approve.sh <issue-id>...  - clear needs-human so agents will pick the issue up again.
set -euo pipefail
DATA_DIR="${DATA_DIR:-$PWD/.agent-factory}"
for id in "$@"; do
  bd label remove "$id" needs-human
  bd update "$id" --status open >/dev/null 2>&1 || true
  # Whatever note explained the needs-human label (the HUMAN_APPROVE_STORIES gate note from
  # new-story.sh, or an agent's own "here's what I need") is now stale - removing the label alone
  # doesn't remove or amend it. Without this, the next agent to pick the issue up reads old text
  # still telling it to wait for approval that has, by definition, already just happened here -
  # confusing it into stopping again and re-triggering needs-human right back (observed in
  # practice: the note said "run approve.sh", the architect read that as still-pending even after
  # approve.sh had already run, and stopped twice, hitting the attempt cap).
  bd update "$id" --append-notes "Approved via approve.sh by $(whoami) at $(date -u +%FT%TZ) - any note above is stale; proceed." >/dev/null 2>&1 || true
  echo "released $id"
done
