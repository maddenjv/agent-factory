# Design: a role picks up work team-lead routed to it despite a leftover claim (agent-factory-zf0i)

Story: `docs/stories/agent-factory-zf0i.md`. Touches `bin/agent-loop.sh` (`next_issue()`, `claim()`, main
loop around `run_agent`, `release_stale`), `docs/ARCHITECTURE.md` (one sentence), plus a new test.
No change to `agents/team-lead.md`. Mirror image of `agent-factory-rcjb` (see its design).

## Root cause

Non-team-lead roles poll `bd ready --label role:<x>`. `bd ready` **excludes `in_progress`** issues, and
team-lead's session starts with the issue claimed (assignee `team-lead`, `in_progress`). If it adds
`role:<x>` and forgets `bd unclaim`, the issue never appears in `bd ready`; and even if it did, the
jq filter keeps only assignee empty-or-me, and `claim()` returns 1 for any other assignee. So three
places must change: the source of candidates, the assignee filter, and `claim()`.

## Detecting "team-lead is not actually working on it" (AC6)

bd's lease/heartbeat is not usable: the loop never runs `bd heartbeat`, so a long team-lead session
would look expired. Use a loop-owned marker instead. State is already shared per agent id under
`$CONTROL/state/<AGENT_ID>/` (same `CONTROL` dir for every role):

- team-lead's loop writes the issue id to `$CONTROL/state/team-lead/working` immediately after a
  successful `claim` (before `run_agent`) and removes it after `handle_outcome`/`record_failure`
  (i.e. at the end of every loop iteration that got that far; also on the early `continue` paths after
  a claim: sync failure, quota wait). Use one helper pair `mark_working ID` / `clear_working`.
- `release_stale()` (startup) also deletes the marker, so a crashed/restarted team-lead does not leave
  a permanent "running" marker. Crash with no restart leaves a stale marker for the one issue; the
  role-side check therefore also ignores the marker once it is older than `ITERATION_TIMEOUT` + 300 s
  (`find -mmin`/`stat` mtime check; team-lead sessions are killed at `ITERATION_TIMEOUT`).
- Only the role-side `next_issue` reads it: skip the candidate whose id equals the marker content
  (`TEAM_LEAD_WORKING_FILE`, overridable for tests). The marker names exactly one issue, which
  covers AC6 without parsing leases.

## next_issue() for roles other than team-lead

Keep the `bd ready` query (it already encodes AC5: blockers closed; and `needs-*` exclusion) for
unassigned/own issues. Add a second source for team-lead's leftover claims, because `bd ready`
hides in_progress:

```bash
bd list --status in_progress --assignee team-lead --label "role:$ROLE" --limit 50 --json
```

(Engineer: verify these flags exist on the installed bd; if `--assignee` is missing on `list`, filter
in jq.) Candidates from it are kept only when ALL hold, in jq:
- assignee == `team-lead` exactly (AC4: other assignees, incl. other roles' ids, are never taken);
- labels contain none of `needs-human`, `needs-team-lead`, `needs-chain` (AC3);
- id != the working marker (AC6);
- id is **not blocked**: intersect against `bd blocked --json` ids and drop those (AC5). `bd blocked`
  lists issues with open blockers; an in_progress issue whose blockers are all closed is absent.
  If `bd blocked` fails (non-zero / unparseable), treat as "unknown" and select nothing from this
  source this cycle (fail closed).

Also relax the `bd ready` filter's assignee test to `empty or == $me or == "team-lead"` so a
team-lead-assigned **open** issue (e.g. team-lead released status but not assignee) is selected too,
with the same marker exclusion. Own/unassigned `bd ready` results come first; the in_progress
team-lead candidates are appended; first element wins. Single jq pipeline each; use `jq -s`-style
concatenation of the two JSON arrays (`jq -n --argjson a ... --argjson b ...`) or just two calls,
whichever is simpler - result must be the first id or empty.

## claim() takeover

Add a branch for `$who = team-lead` and `$ROLE != team-lead`, re-checking preconditions (state can
change between select and claim):
```bash
elif [ "$who" = team-lead ] && [ "$ROLE" != team-lead ] \
     && ! has_label "$id" needs-team-lead && ! has_label "$id" needs-chain && ! has_label "$id" needs-human \
     && has_label "$id" "role:$ROLE" && [ "$(cat "$TEAM_LEAD_WORKING_FILE" 2>/dev/null)" != "$id" ]; then
  # takeover of team-lead's leftover claim. bd rejects --force with --if-assignee (see rcjb), so
  # compare-and-swap by hand: re-read the assignee right before the forced update.
  [ "$(issue_field "$id" assignee)" = team-lead ] \
    && bd update "$id" --assignee "$AGENT_ID" --status in_progress --force >/dev/null 2>"$CLAIM_ERR"
```
Result: assignee = role's agent id, `in_progress`, no team-lead remnant (AC2). Blockers need no
re-check in `claim()` (selection already did; the window is one loop step). Everything else in
`claim()` unchanged. The existing main-loop failure path (`handle_claim_failure` -> log with bd's
error + `skip_claim_failed`, `CLAIM_SKIP_SECS` backoff) already satisfies AC7, **but** the role-side
`next_issue` must honour the skip list as team-lead's does: add the `claim_skip_ids` exclusion to
the role-side jq (currently only team-lead's branch applies it - without it a failed takeover would
be retried every cycle).

## AC mapping

| AC | How satisfied |
|----|---------------|
| 1  | team-lead-assigned `role:<x>` issue, no `needs-*`, blockers closed => selected via in_progress/`bd ready` source, then claimed. |
| 2  | Takeover update sets assignee to `$AGENT_ID` and status in_progress. |
| 3  | `needs-team-lead`/`needs-chain`/`needs-human` excluded in both select and claim. |
| 4  | Only assignee exactly `team-lead` is added; others fall to existing `return 1`. |
| 5  | `bd blocked` exclusion (in_progress source); `bd ready` source blocked by construction. |
| 6  | working-marker exclusion in select and claim. |
| 7  | `claim` returns non-zero => `handle_claim_failure` logs + skip window; role-side select honours skip list. |

## Test strategy (QA)

New `tests/agent-factory-zf0i_test.sh` in the style of `tests/agent-factory-rcjb_test.sh`/`vfu3`:
extract the function block from `bin/agent-loop.sh`, stub `bd` on `PATH` (`ready`, `list`, `blocked`,
`show`, record `update` argv), set `ROLE=<x> AGENT_ID=<x>`, a temp `TEAM_LEAD_WORKING_FILE`. Cover for
at least two roles (e.g. po and engineer):
- AC1: in_progress, assignee team-lead, `role:po`, not blocked => `next_issue` returns it; `claim`
  issues `--assignee po --status in_progress --force`, returns 0. **Fails on current code.**
- AC2: asserted from the recorded update argv (assignee is the role id; no `team-lead` left).
- AC3: each of `needs-team-lead`, `needs-chain`, `needs-human` => not selected; `claim` returns 1, no update.
- AC4: assignee `engineer` / `alice` seen by role po => not selected; `claim` returns 1, no update.
- AC5: id present in `bd blocked` output => not selected; `bd blocked` failing => not selected.
- AC6: marker contains the id => not selected and `claim` returns 1; marker naming a different id or
  absent => selected; marker older than the timeout => selected.
- AC7: `claim` failure (stub `bd update` exits 1) goes through `handle_claim_failure` in the loop's
  idiom: after `skip_claim_failed ID`, `next_issue` no longer returns it.
- Marker plumbing: `mark_working`/`clear_working` write/remove the file; `release_stale` clears it.
- Regression: existing unassigned/own `bd ready` selection unchanged; team-lead's own `next_issue` unchanged.
Run the whole `tests/` suite (rcjb, vfu3, x8wj, m7af, dx0, ulq, 250 source/grep `agent-loop.sh`).

## Docs

`docs/ARCHITECTURE.md`, team-lead paragraph: one sentence - a role also picks up an issue routed to it
(`role:<x>`) that team-lead left claimed (assignee `team-lead`) unless it carries `needs-team-lead`/
`needs-chain`/`needs-human`, is blocked, or is the issue team-lead's loop is currently running (loop-owned
`$CONTROL/state/team-lead/working` marker); the takeover is a forced reassign.

## Single engineer task

Small enough for one implement issue; no extra issues created.
