#!/usr/bin/env bash
# Usage: set-throttle.sh <go|idle> "<reason>"
# Records team-lead's current judgment on whether po/architect may claim new top-of-funnel work
# (agent-factory-q4tj) - see agents/team-lead.md's "Assess the po/architect throttle" and
# bin/agent-loop.sh's throttle_ok()/throttle_age(). engineer, qa and reviewer never read this file.
#
# Runs inside team-lead's own Claude Code session (bin/agent-loop.sh's run_throttle_assessment()),
# whose cwd is its own clone ($DATA_DIR/workspaces/team-lead), not $PROJECT_DIR - so, unlike
# bin/lib.sh's host-side scripts, this does not take DATA_DIR from $PWD. It doesn't need to: every
# agent container already has DATA_DIR exported (bin/env.sh, sourced early in agent-loop.sh, while
# PWD is still the container's $PROJECT_DIR working_dir - see docker-compose.yml), so it's already
# in this session's environment. The PROJECT_DIR-based fallback below only matters if this is ever
# run by hand outside that flow.
set -euo pipefail
: "${PROJECT_DIR:?PROJECT_DIR must be set (set by docker-compose in every agent container)}"
DATA_DIR="${DATA_DIR:-$PROJECT_DIR/.agent-factory}"
CONTROL="$DATA_DIR/control"
mkdir -p "$CONTROL"

decision=${1:?usage: set-throttle.sh <go|idle> "<reason>"}
reason=${2:?usage: set-throttle.sh <go|idle> "<reason>"}
case "$decision" in
  go)   idle=false ;;
  idle) idle=true ;;
  *) echo "set-throttle.sh: decision must be 'go' or 'idle', got '$decision'" >&2
     echo "usage: set-throttle.sh <go|idle> \"<reason>\"" >&2; exit 2 ;;
esac
[ -n "${reason//[[:space:]]/}" ] || { echo "set-throttle.sh: reason must not be empty" >&2; exit 2; }

tmp=$(mktemp "$CONTROL/throttle.json.XXXXXX")
jq -n --argjson idle "$idle" --arg reason "$reason" --arg ts "$(date -u +%FT%TZ)" \
  '{idle: $idle, reason: $reason, assessed_at: $ts}' > "$tmp"
mv -f "$tmp" "$CONTROL/throttle.json"
echo "throttle: $decision - $reason"
