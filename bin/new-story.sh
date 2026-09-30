#!/usr/bin/env bash
# Usage: new-story.sh <story-id> "<short title>" [--skip-design] [--skip-tests]
# Creates the stage graph for a story (fork/join), sized by team-lead's decision:
#   design(architect) -> implement(engineer) --\
#                                               +-> verify(qa) -> review(reviewer)
#   tests(qa) ----------------------------------/
# design and tests have no dependency on each other and run in parallel. Either track can be
# omitted (--skip-design / --skip-tests) - implement/verify simply lose the corresponding
# dependency and get different description text; implement, verify and review always exist.
# <story-id> is the PO's feature-request issue id; it names the branch story/<id>. Called by
# team-lead after it decides the chain (agents/team-lead.md's "Size a new story's chain"), not by
# po directly - see agents/po.md step 6.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/bdjson.sh"
sid=${1:?usage: new-story.sh <story-id> "<title>" [--skip-design] [--skip-tests]}
title=${2:?usage: new-story.sh <story-id> "<title>" [--skip-design] [--skip-tests]}
shift 2
skip_design=0; skip_tests=0
for arg in "$@"; do
  case "$arg" in
    --skip-design) skip_design=1 ;;
    --skip-tests)  skip_tests=1 ;;
    *) echo "new-story.sh: unknown flag '$arg'" >&2; exit 1 ;;
  esac
done
gate=""; [ "$skip_design" = 0 ] && [ "${HUMAN_APPROVE_STORIES:-0}" = 1 ] && gate=",needs-human"

mk() {  # role stage suffix-labels description
  bd create "$sid: $title [$2]" -t task -p 2 -l "role:$1,stage:$2,story:$sid$3" -d "$4" --json \
    | bd_unwrap | jq -r 'if type=="array" then .[0].id else .id end'
}
ctx="Story: docs/stories/$sid.md. Branch: story/$sid. Conventions: CLAUDE.md."

d=""
if [ "$skip_design" = 0 ]; then
  d=$(mk architect design "$gate" "Design the implementation. $ctx")
  # HUMAN_APPROVE_STORIES=1 gates the design issue behind needs-human from creation - a deliberate
  # checkpoint, not an agent stuck partway through. It's never touched by the architect (next_issue
  # excludes needs-human issues), so nobody ever explains it via --append-notes the way a stuck
  # agent would - do it here instead, so `bd show` doesn't look identical to a real stuck-agent case.
  [ -n "$gate" ] && bd update "$d" --append-notes "Gated by HUMAN_APPROVE_STORIES=1 - a deliberate checkpoint, not a stuck agent. Review docs/stories/$sid.md, then run 'approve.sh $d' to let the architect start design." >/dev/null
fi

t=""
if [ "$skip_tests" = 0 ]; then
  t=$(mk qa tests "" "Write acceptance tests from the story's acceptance criteria only - do not read or depend on docs/design/$sid.md, which may not exist yet or may still be changing. $ctx")
fi

impl_desc="Implement per docs/design/$sid.md until the acceptance tests pass. $ctx"
impl_suffix=""
if [ "$skip_design" = 1 ]; then
  impl_suffix=",no-design"
  impl_desc="No design stage for this story - team-lead judged it simple enough to skip (see bd comments on the story's needs-chain issue for why). Check out story/$sid directly (git checkout story/$sid && git pull) - there is no story/$sid-design branch, so there is nothing to merge before closing. Implement per the acceptance criteria in docs/stories/$sid.md and docs/ARCHITECTURE.md, run the full suite, push story/$sid directly, then close as usual. $ctx"
fi
i=$(mk engineer implement "$impl_suffix" "$impl_desc")

verify_desc="Verify the implementation against every acceptance criterion; add edge-case tests. $ctx"
verify_suffix=""
if [ "$skip_tests" = 1 ]; then
  verify_suffix=",no-tests"
  verify_desc="No write-tests stage for this story - team-lead judged existing tests already cover this behaviour (see bd comments on the story's needs-chain issue for why). There is no story/$sid-tests branch to merge. Verify the implementation against every acceptance criterion directly and add tests for any gap you find. $ctx"
fi
v=$(mk qa verify "$verify_suffix" "$verify_desc")

r=$(mk reviewer review "" "Review code and tests; merge story/$sid to main if approved. $ctx")

[ -n "$d" ] && bd dep add "$i" "$d"   # implement depends on design, if there is one
bd dep add "$v" "$i"                  # verify depends on implement
[ -n "$t" ] && bd dep add "$v" "$t"   # ...and on write-tests, if there is one
bd dep add "$r" "$v"                  # review depends on verify

echo "story $sid: design=${d:-skipped} tests=${t:-skipped} implement=$i verify=$v review=$r"
if [ -n "$gate" ]; then
  echo "design issue $d is gated: run approve.sh $d to release it"
fi
