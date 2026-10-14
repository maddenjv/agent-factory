#!/usr/bin/env bash
# Pre-review merge-conflict gate (agent-factory-4yvo). Usage: conflict-check.sh <review-issue-id>
# Called by agent-loop.sh before the reviewer claims a stage:review issue. If origin/<branch> would
# conflict with origin/main it files a merge-conflict rework issue and makes the review issue depend
# on it. Detection is `git merge-tree --write-tree` (in memory: no worktree, no push).
# Env: REPO (clone to operate in; default: git toplevel of the cwd).
# Exit: 0 nothing to do/proceed, 10 conflict (rework filed or already present; do not claim),
#       2 could not check (reason on stderr; caller proceeds).
set -uo pipefail

KIT_DIR="${KIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=bin/bdjson.sh
source "$KIT_DIR/bin/bdjson.sh"

say() { echo "conflict-check: $*" >&2; }
cant() { say "cannot check ${RID:-?}: $*"; exit 2; }

RID="${1:?usage: conflict-check.sh <review-issue-id>}"
REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$REPO" ] || cant "no REPO"
g() { git -C "$REPO" "$@"; }

issue=$(bd show "$RID" --json 2>/dev/null | bd_unwrap | jq -c 'if type=="array" then .[0] else . end') \
  && [ -n "$issue" ] && [ "$issue" != null ] || cant "bd show failed"
has_label() { echo "$issue" | jq -e --arg l "$1" '(.labels // []) | index($l)' >/dev/null; }
has_label stage:review && has_label role:reviewer || exit 0

sid=$(echo "$issue" | jq -r '[(.labels // [])[] | select(startswith("story:"))][0] // "" | sub("^story:"; "")')
if [ -n "$sid" ]; then
  branch="story/$sid"
else
  branch=$(echo "$issue" | jq -r '.title // ""' | grep -oE 'fix/[A-Za-z0-9._-]+' | head -1)
  [ -n "$branch" ] || branch=$(echo "$issue" | jq -r '.description // ""' | grep -oE 'fix/[A-Za-z0-9._-]+' | head -1)
  [ -n "$branch" ] || cant "no story label or fix/ branch in title/description"
fi
branch="${branch%[.:]}"

g fetch -q --prune origin 2>/dev/null || cant "git fetch origin failed ($branch)"
g rev-parse --verify -q "refs/remotes/origin/$branch" >/dev/null || cant "origin/$branch does not exist"
g rev-parse --verify -q refs/remotes/origin/main >/dev/null || cant "origin/main does not exist"

rc=0
out=$(g merge-tree --write-tree --name-only --no-messages origin/main "origin/$branch" 2>/dev/null) || rc=$?
case "$rc" in
  0) exit 0 ;;
  1) ;;
  *) cant "git merge-tree failed for $branch (rc=$rc; git too old?)" ;;
esac
files=$(printf '%s\n' "$out" | tail -n +2 | grep -v '^$')
[ -n "$files" ] || cant "merge-tree reported a conflict for $branch but no files"

# Duplicate guard: an open merge-conflict rework for this branch (ours or the reviewer's)
existing=$(bd list --status open,in_progress,blocked --label merge-conflict --json 2>/dev/null | bd_unwrap \
  | jq -r --arg sid "$sid" --arg b "$branch" '[.[]? | select(.status != "closed")
      | select((.labels // []) | index("stage:rework"))
      | select(if $sid != "" then (.labels | index("story:" + $sid)) else ((.labels // []) | all(startswith("story:") | not)) and ((.title // "") | contains($b)) end)
      ][0].id // empty')
if [ -n "$existing" ]; then
  bd dep add "$RID" "$existing" >/dev/null 2>&1
  say "$RID held back: merge-conflict rework $existing already open for $branch"
  exit 10
fi

role=role:qa
while IFS= read -r f; do
  b=${f##*/}
  case "$f" in tests/*|test/*) continue ;; esac
  case "$b" in *_test.*|test_*|*.test.*) continue ;; esac
  role=role:engineer; break
done <<< "$files"

side_branch=$(g log --oneline -n 30 "origin/main..origin/$branch" 2>/dev/null)
mapfile -t flist <<< "$files"
side_main=$(g log --oneline -n 30 "origin/$branch..origin/main" -- "${flist[@]}" 2>/dev/null)
desc="Filed by the pre-review conflict check (bin/conflict-check.sh) for review issue $RID.

$branch would conflict with origin/main.

Conflicting files:
$files

Commits on $branch (not on main):
$side_branch

Commits on origin/main touching those files (not on $branch):
$side_main

Resolve: check out $branch, pull, 'git fetch origin main && git merge origin/main' (no rebase: the branch is shared), resolve preserving both sides' intent, re-run the full suite, push $branch."

labels="$role,stage:rework"
[ -n "$sid" ] && labels="$labels,story:$sid"
labels="$labels,merge-conflict"
new=$(bd create "Merge conflict: bring $branch up to date with origin/main" -t task -p 1 -l "$labels" -d "$desc" --json 2>/dev/null \
  | bd_unwrap | jq -r 'if type=="array" then .[0] else . end | .id // empty')
[ -n "$new" ] || cant "bd create failed for $branch"
bd dep add "$new" "$RID" --type discovered-from >/dev/null 2>&1 || cant "could not link $new to $RID"
bd dep add "$RID" "$new" >/dev/null 2>&1 || cant "could not make $RID depend on $new"
bd comment "$RID" "pre-review check: $branch conflicts with origin/main ($(echo "$files" | tr '\n' ' ')); filed $new ($role) and held this review until it closes." >/dev/null 2>&1
say "$RID held back: filed $new for $branch ($role)"
exit 10
