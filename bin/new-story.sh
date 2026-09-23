#!/usr/bin/env bash
# Usage: new-story.sh <story-id> "<short title>"
# Creates the fixed stage graph for a story (fork/join):
#   design(architect) -> implement(engineer) --\
#                                               +-> verify(qa) -> review(reviewer)
#   tests(qa) ----------------------------------/
# design and tests have no dependency on each other and run in parallel.
# <story-id> is the PO's feature-request issue id; it names the branch story/<id>.
set -euo pipefail
sid=${1:?usage: new-story.sh <story-id> "<title>"}
title=${2:?usage: new-story.sh <story-id> "<title>"}
gate=""; [ "${HUMAN_APPROVE_STORIES:-0}" = 1 ] && gate=",needs-human"

mk() {  # role stage suffix-labels description
  bd create "$sid: $title [$2]" -t task -p 2 -l "role:$1,stage:$2,story:$sid$3" -d "$4" --json \
    | jq -r 'if type=="array" then .[0].id else .id end'
}
ctx="Story: docs/stories/$sid.md. Branch: story/$sid. Conventions: CLAUDE.md."

d=$(mk architect design    "$gate" "Design the implementation. $ctx")
# HUMAN_APPROVE_STORIES=1 gates the design issue behind needs-human from creation - a deliberate
# checkpoint, not an agent stuck partway through. It's never touched by the architect (next_issue
# excludes needs-human issues), so nobody ever explains it via --append-notes the way a stuck
# agent would - do it here instead, so `bd show` doesn't look identical to a real stuck-agent case.
[ -n "$gate" ] && bd update "$d" --append-notes "Gated by HUMAN_APPROVE_STORIES=1 - a deliberate checkpoint, not a stuck agent. Review docs/stories/$sid.md, then run 'approve.sh $d' to let the architect start design." >/dev/null
t=$(mk qa        tests     ""      "Write acceptance tests from the story's acceptance criteria only - do not read or depend on docs/design/$sid.md, which may not exist yet or may still be changing. $ctx")
i=$(mk engineer  implement ""      "Implement per docs/design/$sid.md until the acceptance tests pass. $ctx")
v=$(mk qa        verify    ""      "Verify the implementation against every acceptance criterion; add edge-case tests. $ctx")
r=$(mk reviewer  review    ""      "Review code and tests; merge story/$sid to main if approved. $ctx")

bd dep add "$i" "$d"   # implement depends on design only
bd dep add "$v" "$i"   # verify depends on implement
bd dep add "$v" "$t"   # ...and on write-tests (tests has no deps: ready immediately)
bd dep add "$r" "$v"   # review depends on verify

echo "story $sid: design=$d tests=$t implement=$i verify=$v review=$r"
[ -n "$gate" ] && echo "design issue $d is gated: run approve.sh $d to release it"
