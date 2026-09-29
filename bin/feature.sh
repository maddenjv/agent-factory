#!/usr/bin/env bash
# Usage: feature.sh "Title" ["description"]   - file a feature request. Carries no role:* label,
# so team-lead's sweep triages it (same as any other unrouted issue) before it reaches po.
set -euo pipefail
title=${1:?usage: feature.sh "title" ["description"]}
bd create "$title" -t feature -p 2 -d "${2:-}" --json \
  | jq -r 'if type=="array" then .[0].id else .id end'
