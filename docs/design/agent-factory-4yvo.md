# Design: Pre-review merge-conflict detection (agent-factory-4yvo)

## Approach
Detection is a **loop-level gate, not agent work**: no Claude session is spent on it. Before
`bin/agent-loop.sh` claims a review issue for the `reviewer` role it runs a new script,
`bin/conflict-check.sh <review-issue-id>`. If the branch would conflict with `origin/main`, the
script files the `merge-conflict` rework issue and makes the review issue depend on it, so the
review issue drops out of `bd ready` until the rework closes. Because the gate runs *every time*
the reviewer is about to claim, re-checking after the rework is closed (AC3) needs no extra state:
the review issue simply becomes ready again and goes through the gate again.

Why here: "about to become available to the reviewer" == "about to be claimed by the reviewer
loop"; the gate sits on the one path every review issue takes (stories and `fix/` merge requests),
costs a few git calls, and needs no new daemon/cron. Checking at the claim moment is also as fresh
as possible, which minimises (but cannot eliminate, AC9) merge-time conflicts.

### Detecting without touching anything (AC5)
`git merge-tree --write-tree --name-only --no-messages origin/main origin/<branch>` (git >= 2.38;
the image's Debian bookworm git is 2.39). It performs the merge in memory: no worktree, no index,
no `MERGE_HEAD`, no ref updates, nothing pushed. Exit 0 = clean (including "merely behind", AC4),
exit 1 = conflicts (stdout: tree oid, then one conflicting path per line), anything else = error.
Only `git fetch -q --prune origin` (remote-tracking refs only) precedes it. Add a `git --version`
guard: if `merge-tree --write-tree` is unsupported it is an error case (exit 2), never a block.

## Files
- **new `bin/conflict-check.sh`** - sources `bin/lib.sh` and `bin/bdjson.sh`. Usage:
  `conflict-check.sh <review-issue-id>`; env `REPO` (clone to operate in, default
  `$(git rev-parse --show-toplevel)`), `LOGDIR` optional. Exit codes (the interface the loop and
  tests depend on):
  - `0` - nothing to do: not a review issue, clean merge, or branch fine -> proceed.
  - `10` - conflict: rework issue filed (or already present) and linked -> do **not** claim.
  - `2` - could not check (fetch failed, branch missing on origin, merge-tree error, bd error,
    cannot determine branch) -> a one-line reason on stderr; caller proceeds (AC8).
- **`bin/agent-loop.sh`** - add `precheck_review()` and call it in the main loop (below).
- **`agents/reviewer.md`** - one sentence under the Approve paragraphs: the loop pre-checks
  conflicts, so a review issue you receive was conflict-free at claim time; the merge-time conflict
  flow below is unchanged (AC9). No other prompt changes.
- **`docs/ARCHITECTURE.md`** - add a short "Pre-review conflict gate" paragraph (see end).

## conflict-check.sh behaviour
1. `show_json <id>` (bd show --json, unwrapped). Proceed (exit 0) unless the issue has label
   `stage:review` and `role:reviewer`.
2. Branch: if it has a `story:<sid>` label -> `story/<sid>`; else (storyless path) take the first
   match of `fix/[A-Za-z0-9._-]+` in the title (merge-request titles are
   `Merge fix/<issue-id>: ...`), falling back to the description; none -> exit 2.
   Strip a trailing `.`/`:` from the match.
3. `git -C "$REPO" fetch -q --prune origin` (failure -> exit 2, log). Require
   `git rev-parse --verify -q refs/remotes/origin/<branch>` and `.../origin/main` (missing -> exit 2;
   AC8 "branch does not exist on origin").
4. Run merge-tree as above. Exit 0 -> exit 0. Exit 1 -> collect `files` (lines after the first,
   non-empty). Other -> exit 2.
5. Duplicate guard (AC6): `bd list --status open,in_progress,blocked --label merge-conflict --json`
   (unwrap) filtered with jq to issues that also have `stage:rework` and: for stories the label
   `story:<sid>`; for fix branches a title containing `<branch>` (and no `story:` label). If one
   exists, do not create; just ensure the review issue depends on it
   (`bd dep add <review> <existing>`, idempotent/ignore "already exists") and exit 10. This also
   covers a reviewer-filed merge-time conflict rework, which carries the same labels.
6. Gather commit lists for the description: `git log --oneline origin/main..origin/<branch>` (branch
   side, `-n 30`) and `git log --oneline origin/<branch>..origin/main -- <files>` (main side, `-n 30`).
7. Route (same rule as reviewer.md step 3): a file is **test** if its path starts with `tests/` or
   `test/`, or its basename matches `*_test.*`, `test_*` or `*.test.*`. All files test -> `role:qa`;
   otherwise `role:engineer`.
8. File: `bd create "Merge conflict: bring <branch> up to date with origin/main" -t task -p 1 -l
   <role:X>,stage:rework[,story:<sid>],merge-conflict -d "<description>" --json` (unwrap, take
   `.id`). Description: "Filed by the pre-review conflict check (bin/conflict-check.sh) for review
   issue <review-id>." + branch to resolve (`<branch>` directly, same as the reviewer's storyless flow) +
   conflicting files + both commit lists + the ask: check out `<branch>`, pull,
   `git fetch origin main && git merge origin/main` (no rebase: shared branch), resolve preserving both
   sides' intent, re-run the full suite, push `<branch>`.
9. Link like the reviewer flow: `bd dep add <new> <review> --type discovered-from`, then
   `bd dep add <review> <new>` (blocks review). If creating or linking fails after the create,
   exit 2 (loop proceeds; the stray issue is harmless and is found by step 5 next time - and a
   half-linked one gets linked then). `bd comment <review> "pre-review check: conflict ... filed <new>"`.
   Exit 10.
Log lines to stderr, prefixed `conflict-check:`; the loop forwards them to `loop.log`.

## agent-loop.sh change
```bash
precheck_review() {  # reviewer only: 0 = proceed to claim, 1 = blocked on a conflict rework just filed/found
  [ "$ROLE" = reviewer ] || return 0
  local rc=0 out
  out=$("$KIT_DIR/bin/conflict-check.sh" "$1" 2>&1) || rc=$?
  [ -z "$out" ] || log "$out"
  case "$rc" in 0) return 0;; 10) return 1;; *) log "pre-review check failed for $1 (rc=$rc); proceeding"; return 0;; esac
}
```
Call it in the main loop right after `id=$(next_issue)` / empty check and **before** `claim`:
`if ! precheck_review "$id"; then log "$id held back: merge conflict rework filed"; sleep 1; continue; fi`.
It runs with `REPO="$REPO"` exported (the loop's clone; `sync_repo` has not yet run this cycle, which
is fine - the script fetches itself and never uses the worktree). `next_issue` will not return the
issue again while the rework is open (blocked), and returns it again when the rework closes (AC3).
Gate failure never counts toward `record_failure`/`fails` (AC8). `set -uo pipefail` loop is unaffected
by the nonzero rc (captured via `|| rc=$?`).

## Error cases
- origin unreachable / branch not pushed / branch missing / git too old / unparsable title: exit 2,
  loop logs and proceeds; reviewer's merge-time flow remains the backstop.
- Review issue with a `story:` label whose branch is the combined chain: only `story/<sid>` is
  checked (design/tests sub-branches are merged back before review).
- Rework issue closed but branch not actually fixed: next claim attempt re-detects, files a new one
  (the old one is closed so step 5 finds nothing) - intended per AC3. No attempt cap here (out of scope;
  the reviewer's existing cap excludes `merge-conflict` issues).
- Two loops racing on the same issue: only one reviewer loop exists; if it ever happens a duplicate is
  possible only in that window and is harmless (both block the review).

## Acceptance criteria mapping
1: steps 4-9 + loop gate before claim. 2: step 7 + step 8 description. 3: dep blocks review; gate re-runs
on each claim. 4: merge-tree exit 0 -> exit 0, nothing filed. 5: merge-tree, no push, no worktree use.
6: step 5. 7: step 2 fix branch, same steps. 8: exit 2 path. 9: reviewer.md merge flow untouched.

## Test strategy (QA) - `tests/agent-factory-4yvo_test.sh`
Scratch bare `origin` + clone in a temp dir (isolate `HOME`, set git identity via env); a stub `bd`
first on `PATH` that serves canned `show --json` / `list --json` and appends every other invocation to a
log file, so assertions are on recorded calls. Cases against `bin/conflict-check.sh` (assert exit code
and recorded calls):
1. story conflicting in a non-test file -> exit 10, one `bd create` with `role:engineer`,
   `stage:rework`, `story:<id>`, `merge-conflict`; description contains the file name and a commit subject from each side; `bd dep add <review> <new>` recorded (AC1,2,3).
2. conflict only in `tests/x_test.sh` -> `role:qa`; mixed tests+code -> `role:engineer` (AC2).
3. branch behind main but clean -> exit 0, no `bd create` (AC4).
4. clean and conflicting cases: `git -C origin rev-parse` of the branch and main unchanged, local
   `git status` clean, no `MERGE_HEAD` (AC5).
5. stub `list` returns an open `merge-conflict`+`stage:rework`+`story:<id>` issue -> exit 10, no `bd create`,
   dep add still issued (AC6).
6. `fix/<issue-id>` review issue (no `story:` label, title `Merge fix/<id>: ...`) conflicting -> filed with no
   `story:` label, description names `fix/<id>` (AC7).
7. branch absent on origin; origin URL pointing at a nonexistent path -> exit 2, no `bd create` (AC8).
8. non-review issue (e.g. `stage:rework`) -> exit 0 without any git work.
Static greps: `agent-loop.sh` defines `precheck_review`, calls it before `claim`, and only for reviewer;
`reviewer.md` still contains the merge-time conflict steps (`git merge --abort`, `merge-conflict`) (AC9).
`shellcheck bin/conflict-check.sh bin/agent-loop.sh` clean.

## ARCHITECTURE.md addition
Under "Getting work to main": "**Pre-review conflict gate** (`agent-factory-4yvo`): before the reviewer
loop claims a `stage:review` issue (story or `fix/`), `bin/conflict-check.sh` runs `git merge-tree
--write-tree` of `origin/<branch>` into `origin/main` (no worktree, no push). A real conflict files a
`merge-conflict` `stage:rework` issue (engineer, or qa if all conflicting files are tests) that the review
issue depends on; a clean-but-behind branch is untouched; any failure to check is logged and ignored."
