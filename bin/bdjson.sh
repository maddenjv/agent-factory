# shellcheck shell=bash
# Sourced by every script that parses `bd ... --json`. bd v2.0 wraps that output as
# {"data": <bare output>, "schema_version": N} (opt in early: BD_JSON_ENVELOPE=1); today it is bare.
# bd_unwrap strips the wrapper if present and is the identity otherwise, so callers work with both.
BD_UNWRAP='if type=="object" and has("data") and has("schema_version") then .data else . end'
bd_unwrap() { jq -c "$BD_UNWRAP" 2>/dev/null; }
