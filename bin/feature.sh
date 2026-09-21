#!/usr/bin/env bash
# Usage: feature.sh "Title" ["description"]   - file a feature request for the product-owner agent.
set -euo pipefail
title=${1:?usage: feature.sh "title" ["description"]}
bd create "$title" -t feature -p 2 -l role:po -d "${2:-}" --json \
  | jq -r 'if type=="array" then .[0].id else .id end'
