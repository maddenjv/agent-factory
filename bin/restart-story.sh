#!/usr/bin/env bash
# Usage: restart-story.sh <rework-issue-id> <unresolvable|attempt-cap>
# A merge-conflict rework could not be resolved: redo the story's implementation from current
# origin/main. Creates fresh implement -> verify -> review issues (labelled `restarted`), closes the
# superseded ones. Design and tests are not repeated. A second restart is refused (needs-human).
set -euo pipefail
rid=${1:?usage: restart-story.sh <rework-issue-id> <unresolvable|attempt-cap>}
reason=${2:?usage: restart-story.sh <rework-issue-id> <unresolvable|attempt-cap>}

j() { jq -c 'if type=="array" then .[0] else . end'; }
rj=$(bd show "$rid" --json | j)
haslabel() { jq -e --arg l "$2" '(.labels // []) | index($l)' <<<"$1" >/dev/null; }

if ! { haslabel "$rj" stage:rework && haslabel "$rj" merge-conflict; }; then
  echo "not a merge-conflict rework; nothing to do"; exit 0
fi
sid=$(jq -r '[.labels[] | select(startswith("story:"))][0] // empty | sub("^story:";"")' <<<"$rj")
[ -n "$sid" ] || { echo "error: $rid has no story: label" >&2; exit 1; }
rnotes=$(jq -r '.notes // "none"' <<<"$rj")

all=$(bd list --all --label "story:$sid" --json --limit 0)
ids_of() {  # jq filter on issue -> ids
  jq -r "[.[]? | select($1) | .id] | join(\" \")" <<<"$all"
}

if jq -e '[.[]? | select((.labels // []) | index("restarted"))] | length > 0' <<<"$all" >/dev/null; then
  rev=$(ids_of '.status != "closed" and ((.labels // []) | index("stage:review"))')
  msg="Story $sid was already restarted once (see issues labelled 'restarted'); its conflict rework failed again ($reason). Not restarting a second time. Needs a human to decide: resolve by hand or abandon the story."
  for r in $rev; do
    bd update "$r" --append-notes "$msg" >/dev/null
    bd label add "$r" needs-human >/dev/null
  done
  bd label add "$rid" needs-human >/dev/null
  bd comment "$rid" "$msg" >/dev/null
  echo "story $sid: already restarted; flagged needs-human"; exit 0
fi

stagef() { echo ".status != \"closed\" and ((.labels // []) | index(\"stage:$1\"))"; }
oldimpl=$(ids_of "$(stagef implement)"); oldver=$(ids_of "$(stagef verify)")
oldrev=$(ids_of "$(stagef review)");     oldrew=$(ids_of "$(stagef rework)")
title=$(jq -r '[.[]? | select((.labels // []) | index("stage:review"))][0].title // empty' <<<"$all" \
  | sed 's/ \[review\]$//')
[ -n "$title" ] || title="$sid"

mk() {  # role stage description
  bd create "$title [$2]" -t task -p 2 -l "role:$1,stage:$2,story:$sid,restarted" -d "$3" --json \
    | jq -r 'if type=="array" then .[0].id else .id end'
}
ctx="Story: docs/stories/$sid.md. Branch: story/$sid. Conventions: CLAUDE.md."
i=$(mk engineer implement "PLACEHOLDER")
bd update "$i" -d "Restart of story $sid: the previous implementation could not be merged (conflict rework $rid: $reason). Redo it from current origin/main; the old implementation is discarded.
1. git fetch origin && git checkout -B story/$sid origin/main
2. git merge --no-ff origin/story/$sid-design -m \"[$i] Merge design\"   # brings docs/design/$sid.md
   git merge --no-ff origin/story/$sid-tests  -m \"[$i] Merge tests\"     # QA's acceptance tests; skip if that branch does not exist
3. Implement per docs/design/$sid.md until the acceptance tests pass. Do NOT edit QA's tests. Run the full suite.
4. git push --force-with-lease origin story/$sid   (the old commits are intentionally replaced)
Do not redo design or tests. $ctx" >/dev/null
v=$(mk qa verify "Verify the implementation against every acceptance criterion; add edge-case tests. $ctx")
r=$(mk reviewer review "Review code and tests; merge story/$sid to main if approved. $ctx")
bd dep add "$v" "$i" >/dev/null
bd dep add "$r" "$v" >/dev/null

old="$oldimpl $oldver $oldrev $oldrew"
fail=0
for o in $old; do
  bd close "$o" --force --reason "Superseded: story $sid restarted ($reason); new implement $i, verify $v, review $r" >/dev/null \
    || { echo "error: failed to close $o" >&2; fail=1; }
done
bd comment "$i" "Restart of story $sid: reason=$reason. Replaces implement ${oldimpl:-none}, verify ${oldver:-none}, review ${oldrev:-none}, conflict rework $rid. Rework note: $rnotes." >/dev/null
echo "story $sid restarted ($reason): implement=$i verify=$v review=$r"
exit "$fail"
