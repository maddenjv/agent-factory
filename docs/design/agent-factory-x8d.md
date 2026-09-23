# Design: Restart implementation when a merge-conflict rework cannot be resolved (agent-factory-x8d)

Builds on agent-factory-h71 (design: `story/agent-factory-h71-design`), which files conflict-rework
issues labelled `stage:rework` + `merge-conflict` (role engineer, or qa for test-only conflicts).
**This story must be implemented after h71 has landed**; it relies only on that label and on the
"conflict cannot be resolved -> needs-human" fallback h71 leaves in engineer.md / qa.md.

(Branch note: git cannot hold both `story/<id>` and `story/<id>/design`; this design lives on
`story/agent-factory-x8d-design`. Engineer: merge that branch into `story/agent-factory-x8d` at the end.)

## Approach
One new script does all the tracker work; `agent-loop.sh` calls it from the two places a conflict
rework can fail; the engineer/qa prompts learn a new way to say "unresolvable".

Why loop + script, not prompt-only: the attempt-cap path (AC2) is mechanical in `agent-loop.sh` and
has no agent to instruct; and a script is testable in a scratch Beads DB, unlike prompt text.

### 1. `bin/restart-story.sh <rework-issue-id> <unresolvable|attempt-cap>` (new, executable)
Style of `new-story.sh` (`set -euo pipefail`, a `mk` helper, `bd ... --json | jq`). Steps:

1. Read the rework issue (`bd show --json`, first element if array). Require labels `stage:rework` AND
   `merge-conflict`; else print `not a merge-conflict rework; nothing to do` and `exit 0` (AC8, no
   changes made). `sid` = the `story:<id>` label value; none -> exit 1.
2. List every issue of the story: `bd list --all --label "story:$sid" --json`.
   - **Already restarted?** if any has label `restarted` -> AC7 path (below), then exit 0.
   - `old` = issues with status != closed whose `stage:` label is `implement`, `verify`, `review`
     or `rework` (this includes the rework issue itself and any other open rework). Never `design`
     or `tests`. Remember `oldreview` = the open `stage:review` issue.
3. Create the new chain, `mk role stage desc` exactly as `new-story.sh`, labels
   `role:<r>,stage:<s>,story:$sid,restarted`:
   - implement (`role:engineer`) - description in section 2; **no dependencies** (immediately ready, AC3)
   - verify (`role:qa`) - same text as new-story.sh's verify; `bd dep add verify implement`
   - review (`role:reviewer`) - same text as new-story.sh's review; `bd dep add review verify`
   No design/tests issue and no dep on them (AC6). Titles `"$sid: <story title> [<stage>]"`; take
   the title from the old review issue with its `[review]` suffix swapped.
4. Close every `old` issue: `bd close <ids> --force --reason "Superseded: story $sid restarted (<reason>);
   new implement <impl>, verify <ver>, review <rev>"` (AC4). Create first, close second, so a crash
   in between leaves a duplicate rather than a dead story; log any failed close and exit 1.
5. `bd comment <impl> "Restart of story $sid: reason=<unresolvable|attempt-cap>. Replaces implement
   <ids>, verify <ids>, review <ids>, conflict rework <id>. Rework note: <rework issue notes, or
   'none'>."` (AC6). Print one summary line like new-story.sh.

**AC7 path (second failure):** do not create or close anything. Take the open `stage:review` issue
(the new one), `bd update --append-notes "Story $sid was already restarted once (see issues labelled
'restarted'); its conflict rework failed again (<reason>). Not restarting a second time. Needs a
human to decide: resolve by hand or abandon the story."`, `bd label add <review> needs-human`;
also `bd label add <rework> needs-human` so `next_issue` stops re-offering the rework issue (it is
ready and would otherwise loop). `bd comment` the same on the rework issue.

### 2. Description of the new implement issue (AC5)
```
Restart of story <sid>: the previous implementation could not be merged (conflict rework <id>:
<reason>). Redo it from current origin/main; the old implementation is discarded.
1. git fetch origin && git checkout -B story/<sid> origin/main
2. git merge --no-ff origin/story/<sid>-design -m "[<this-issue>] Merge design"   # brings docs/design/<sid>.md
   git merge --no-ff origin/story/<sid>-tests  -m "[<this-issue>] Merge tests"     # QA's acceptance tests; skip if that branch does not exist
3. Implement per docs/design/<sid>.md until the acceptance tests pass. Do NOT edit QA's tests. Run the full suite.
4. git push --force-with-lease origin story/<sid>   (the old commits are intentionally replaced)
Do not redo design or tests. Story: docs/stories/<sid>.md. Conventions: CLAUDE.md.
```
If the design/tests branch was already merged into main, `git merge` says "Already up to date" - fine.
Force push is required and intended; `--force-with-lease` (after the fetch in step 1) protects against
clobbering an unexpected push.

### 3. `agents/engineer.md` and `agents/qa.md`
- **Unresolvable signal (AC1).** In the h71 `merge-conflict` rework case, replace the "cannot be resolved ->
  `needs-human`" fallback with: `bd update <your-issue> --append-notes "<why it cannot be resolved>"`, then
  `bd label add <your-issue> conflict-unresolvable`, stop. Do NOT label `needs-human` and do not close it;
  `agent-loop.sh` restarts the story. (A note is mandatory: it goes into the restart comment.)
- engineer.md, `stage:implement`: one line - if the issue has label `restarted`, follow the branch/merge/push steps in
  its description instead of steps 0 and the "Before closing" merge (the description is authoritative).
  Everything else (don't edit QA tests, full suite green) unchanged.

### 4. `bin/agent-loop.sh`
Add helper and two call sites; nothing else changes.
```bash
is_conflict_rework() { has_label "$1" stage:rework && has_label "$1" merge-conflict; }
restart_story() {  # restart_story ID REASON - see bin/restart-story.sh
  "$KIT_DIR/bin/restart-story.sh" "$1" "$2" >>"$LOGDIR/loop.log" 2>&1 \
    && alert "$1: merge-conflict rework failed ($2); story restarted" \
    || alert "$1: restart-story.sh failed ($2); needs a human"
}
```
- `handle_outcome`, right after the `closed` check and before the `needs-human` branch: if
  `is_conflict_rework "$id"` and the issue has `conflict-unresolvable` **or** `needs-human` (an agent
  reverting to the old fallback still gets recovered), `restart_story "$id" unresolvable; return 0`.
  Ordinary rework (no `merge-conflict`) falls through unchanged (AC8).
- `record_failure`, after `bd label add "$id" needs-human` in the cap branch: `is_conflict_rework "$id" &&
  restart_story "$id" attempt-cap` (AC2). Alert text of the existing branch is kept.
  If restart-story.sh itself fails, the issue keeps `needs-human` (safe default).

### Error cases
- Rework issue lacks `merge-conflict`/`story:` label: script no-ops (exit 0 / exit 1); loop never calls it for non-conflict issues.
- `bd create` fails mid-chain: `set -e` aborts before any close, so old issues are untouched; orphan new issues are visible in `bd list`.
- Second restart: AC7 path. Restart marker is the `restarted` label, so it is durable and needs no state file.

## Acceptance criteria mapping
1 -> section 3 signal + loop `handle_outcome`. 2 -> `record_failure`. 3 -> script step 3. 4 -> step 4.
5 -> section 2. 6 -> step 3 (no design/tests) + step 5. 7 -> AC7 path. 8 -> label guard in script and loop.

## Test strategy (QA)
`bin/restart-story.sh` is testable end-to-end against a scratch Beads DB (`bd init` in a temp dir, as other
`tests/*_test.sh` do where they touch bd; otherwise stub `bd` on PATH with a shell function/script that logs
calls and serves canned `--json`). Cover:
- Happy path: seed a story with closed design/tests and open implement/verify/review/conflict-rework; run
  script; assert new engineer/qa/reviewer issues with `story:`+`restarted`, chain implement->verify->review,
  implement ready (`bd ready`), old four closed with reason mentioning restart, no new design/tests issue,
  comment on new implement naming old ids and reason for both `unresolvable` and `attempt-cap`.
- Implement description contains `origin/main`, `docs/design/<sid>.md`, `--force-with-lease`, "acceptance tests".
- AC7: second invocation on a restarted story creates nothing, review gets `needs-human` + note, rework gets `needs-human`.
- AC8: rework without `merge-conflict` -> no issues created/closed, exit 0.
- `agent-loop.sh` wiring by grep (it is a long-running loop, not sourceable): `is_conflict_rework`,
  `restart_story` referenced from both `handle_outcome` and `record_failure`, gated on `merge-conflict`.
- Prompt greps: engineer.md/qa.md mention `conflict-unresolvable` and no longer send merge-conflict rework to
  `needs-human`; engineer.md mentions `restarted`.
- `shellcheck bin/restart-story.sh bin/agent-loop.sh` clean.
