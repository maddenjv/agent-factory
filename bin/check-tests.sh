#!/usr/bin/env bash
# Flag hard-coded YYYY-MM-DD dates in test scripts.
# Usage: bin/check-tests.sh [dir]   (default: tests, relative to cwd)
# Opt out per line by ending it with the marker comment "# fixed-date-ok".
set -uo pipefail

dir="${1:-tests}"
if [ ! -d "$dir" ]; then
  echo "check-tests: not a directory: $dir" >&2
  exit 2
fi

n=0
declare -A files=()
while IFS= read -r f; do
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    line="${hit#*:}"
    [[ "$line" =~ "# fixed-date-ok"[[:space:]]*$ ]] && continue
    echo "$f:${hit%%:*}: ${hit#*:}"
    n=$((n + 1))
    files["$f"]=1
  done < <(grep -nE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$f")
done < <(find "$dir" -type f -name '*.sh' | sort)

if [ "$n" -gt 0 ]; then
  echo "check-tests: $n hard-coded date(s) in ${#files[@]} file(s)" >&2
  exit 1
fi
echo "check-tests: ok"
