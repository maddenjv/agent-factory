#!/usr/bin/env bash
# Concurrency smoke test for the shared Beads database. Run from the ops shell BEFORE trusting the setup.
# Beads embedded mode has known lost-write problems under concurrent agents; this checks server mode doesn't.
set -uo pipefail
N=${1:-8}
idof() { jq -r 'if type=="array" then .[0].id else .id end'; }
ids=()
for i in $(seq "$N"); do ids+=("$(bd create "smoke $i" -t task -p 4 -l smoke --json | idof)"); done
echo "created ${#ids[@]} issues; claiming + closing them concurrently..."
for id in "${ids[@]}"; do
  ( bd update "$id" --claim --assignee "smoke-$id" >/dev/null 2>&1 \
    && sleep "0.$((RANDOM % 9))" \
    && bd close "$id" --reason "smoke test" >/dev/null 2>&1 ) &
done
wait
bad=0
for id in "${ids[@]}"; do
  st=$(bd show "$id" --json | jq -r 'if type=="array" then .[0].status else .status end')
  [ "$st" = closed ] || { echo "NOT CLOSED: $id ($st)"; bad=$((bad+1)); }
done
if [ "$bad" -eq 0 ]; then echo "PASS: all $N closes persisted"; else echo "FAIL: $bad of $N closes lost - do not run unattended"; exit 1; fi
