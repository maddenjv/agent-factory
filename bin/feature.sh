#!/usr/bin/env bash
# Usage: feature.sh "Title" ["description"] [--priority <priority>]   - file a feature request.
# Carries no role:* label, so team-lead's sweep triages it (same as any other unrouted issue)
# before it reaches po. priority is any of Beads' accepted forms (0-4 or P0-P4); default 2.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/bdjson.sh"
usage="usage: feature.sh \"title\" [\"description\"] [--priority <priority>]"
title=${1:?$usage}
shift

description=""
if [ $# -gt 0 ] && [ "$1" != "--priority" ]; then
  description=$1
  shift
fi

priority=2
if [ "${1:-}" = "--priority" ]; then
  priority=${2:?$usage}
  shift 2
fi

if ! [[ $priority =~ ^[Pp]?[0-4]$ ]]; then
  echo "feature.sh: invalid priority '$priority' - expected 0-4 or P0-P4" >&2
  exit 1
fi

bd create "$title" -t feature -p "$priority" -d "$description" --json \
  | bd_unwrap | jq -r 'if type=="array" then .[0].id else .id end'
