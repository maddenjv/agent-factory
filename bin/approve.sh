#!/usr/bin/env bash
# Usage: approve.sh [-m <answer>] <issue-id>...  - clear needs-human so agents will pick the issue up again.
set -euo pipefail
DATA_DIR="${DATA_DIR:-$PWD/.agent-factory}"
# -m attaches the human's answer; it is only valid with exactly one id.
ids=()
msg=""
have_msg=0
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message)
      if [ $# -lt 2 ]; then echo "approve.sh: $1 requires a message" >&2; exit 2; fi
      msg="$2"; have_msg=1; shift 2 ;;
    -*) echo "approve.sh: unknown option $1" >&2
        echo "usage: approve.sh [-m <answer>] <issue-id>..." >&2; exit 2 ;;
    *) ids+=("$1"); shift ;;
  esac
done
if [ "$have_msg" -eq 1 ]; then
  if [ -z "${msg//[[:space:]]/}" ]; then echo "approve.sh: message must not be empty" >&2; exit 2; fi
  if [ "${#ids[@]}" -ne 1 ]; then echo "approve.sh: a message can only be attached to a single issue" >&2; exit 2; fi
fi
for id in "${ids[@]}"; do
  bd label remove "$id" needs-human
  bd update "$id" --status open >/dev/null 2>&1 || true
  # Whatever note explained the needs-human label (the HUMAN_APPROVE_STORIES gate note from
  # new-story.sh, or an agent's own "here's what I need") is now stale - removing the label alone
  # doesn't remove or amend it. Without this, the next agent to pick the issue up reads old text
  # still telling it to wait for approval that has, by definition, already just happened here -
  # confusing it into stopping again and re-triggering needs-human right back (observed in
  # practice: the note said "run approve.sh", the architect read that as still-pending even after
  # approve.sh had already run, and stopped twice, hitting the attempt cap).
  if [ "$have_msg" -eq 1 ]; then
    note="Human answer via approve.sh by $(whoami) at $(date -u +%FT%TZ): $msg"$'\n'"Approved; any note above is stale; proceed using this answer."
  else
    note="Approved via approve.sh by $(whoami) at $(date -u +%FT%TZ) - any note above is stale; proceed."
  fi
  bd update "$id" --append-notes "$note" >/dev/null 2>&1 || true
  echo "released $id"
done
