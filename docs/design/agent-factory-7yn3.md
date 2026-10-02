# Design: team-lead can claim an escalated issue still assigned to the escalating role (agent-factory-7yn3)

Story: `docs/stories/agent-factory-7yn3.md`. Touches `bin/agent-loop.sh` (`claim()`, `next_issue()`, the
main loop's claim-failure branch), `tests/agent-factory-rcjb_test.sh` (one assertion is wrong, see below),
a new test, and one sentence in `docs/ARCHITECTURE.md`. No change to `agents/team-lead.md`.

## Root cause (established, reproduced against the installed `bd`)

`claim()`'s takeover branch (added by agent-factory-9awd) runs

```bash
bd update "$id" --if-assignee "$who" --assignee "$AGENT_ID" --status in_progress --force
```

`bd update` rejects that combination outright, before touching the issue:

```
Error: if any flags in the group [force if-assignee] are set none of the others can be; [force if-assignee] were all set
```

(exit 1). `claim()` discards bd's output (`>/dev/null 2>&1`) and returns non-zero, so the loop logs
"could not claim", sleeps 5s and `next_issue()` returns the same issue again - forever. That is exactly
the 515 `could not claim` lines in team-lead's `loop.log` (first seen on agent-factory-wto1 on
2026-09-29, the day 9awd merged; ar5n is just the latest victim). The takeover has therefore **never
worked**; 9awd's and rcjb's tests pass because their `bd` stub accepts any `update` argv and only checks
that the argv contains `--if-assignee po` and `--force` - which is itself the bug (see Tests).
The other candidates in the story are ruled out: the loop was restarted at 10:43 on code that already
contains 9awd, and selection (`next_issue`) and the label/assignee shape of ar5n all match correctly -
the failure is purely in the `bd update` call.

Other bd facts verified in a scratch issue on the live board (closed afterwards):
- `bd update <id> --assignee <me> --status in_progress --force` (no `--if-assignee`) succeeds on an
  issue another actor holds `in_progress`.
- Without `--force`, bd refuses to reassign a live `in_progress` claim ("held by X ... pass --force
  only if their claim is abandoned"). `needs-team-lead` is the escalator's statement that it stopped,
  so `--force` is correct here, as for an expired lease (AC2).
- `--if-assignee` alone gives a compare-and-swap (exit 13 on mismatch) but cannot be combined with
  `--force`.

## Fix 1: claim() takeover (AC1-AC3)

Keep the precondition (team-lead only, assignee matches `BUILD_ROLE_RE` *and* the issue's own
`role:<x>`, issue has `needs-team-lead`) exactly as is - that is AC4. Change only the update:

```bash
# bd rejects --force together with --if-assignee, so do the compare-and-swap by hand: re-read the
# assignee immediately before the forced update and bail if it moved.
[ "$(issue_field "$id" assignee)" = "$who" ] \
  && bd update "$id" --assignee "$AGENT_ID" --status in_progress --force >/dev/null 2>"$err"
```

The window between re-read and update is milliseconds and the only contender is a single team-lead
loop (build roles never touch a `needs-team-lead` issue), so a hand-rolled CAS is adequate. Do **not**
add `--claim` (it cannot combine with other flags and refuses a held issue) and do not drop `--force`
(live lease => refusal).

`claim()` must capture bd's stderr into a variable/temp file (`CLAIM_ERR`) on every failing path so the
caller can log the reason (Fix 2). Success paths are unchanged.

## Fix 2: a failed claim must not wedge the loop (AC5)

Today the main loop does `if ! claim "$id"; then log "could not claim $id"; sleep 5; continue; fi`.
Replace with a per-issue backoff so team-lead falls through to other triage work:

- New global `CLAIM_SKIP` (a `id:epoch` space-separated string, or an associative array - match
  whatever bash version `agent-loop.sh` already assumes; a plain string keeps it portable), defined
  between `log()` and `sync_dir()` so the test extraction range picks it up.
- Helper `skip_claim_failed ID` appends `ID:$(date +%s)`; helper `claim_skip_ids` prints the ids whose
  entry is younger than `CLAIM_SKIP_SECS` (default `600`, env-overridable, defined next to the other
  tunables) and drops expired entries. Skipped ids are retried after the TTL, so a transient failure
  self-heals.
- `next_issue()` (team-lead branch only) takes the skip list as a jq arg
  (`--arg skip "$(claim_skip_ids)"`) and adds `| select(.id as $i | ($skip | split(" ") | index($i)) | not)`
  after the `needs-human` select. Selection rules are otherwise untouched (rcjb out of scope).
- Main loop on claim failure:
  `log "could not claim $id: $(head -c 300 "$CLAIM_ERR" | tr '\n' ' ') - skipping for ${CLAIM_SKIP_SECS}s"`
  then `skip_claim_failed "$id"; sleep 1; continue`. Build roles use the same code path; their skip list
  is simply harmless there (their `next_issue` ignores it), but the log line gains the reason, and they
  keep the existing 5s sleep.
  The "could not claim" prefix is kept so existing greps (and alerting, if any) still match.
- If the skip makes the queue look empty, the loop idles as usual (and team-lead's throttle assessment
  still runs) - which is the point: other triage work and the throttle are no longer starved.

## AC mapping

| AC | How satisfied |
|----|---------------|
| 1  | Takeover now issues a `bd update` bd accepts: assignee becomes team-lead, status in_progress, session starts. |
| 2  | `--force` handles live/expired lease alike; no lease check anywhere. |
| 3  | Labels other than `needs-team-lead` and `role:<assignee>` are irrelevant to the precondition (unchanged). |
| 4  | Precondition unchanged: assignee `alice`, or a build role that is not the issue's `role:` label, still returns 1 with no update. |
| 5  | Reason logged from bd stderr; id skipped for `CLAIM_SKIP_SECS`; loop proceeds to the next issue / idle / throttle. |
| 6  | Tests below; the regression test fails on current code. |

## Tests (QA)

The reason 9awd/rcjb did not catch this is that their `bd` stub is permissive. The new test must use a
stub that **mimics bd's flag validation**: `update` exits 1 with the real error text if both `--force`
and `--if-assignee` appear; exit 13 if `--if-assignee X` is given and the fixture's assignee differs;
otherwise records argv to `$BDLOG` and (for assignee changes) mutates the fixture so a following
`show`/`list` reflects it.

New `tests/agent-factory-7yn3_test.sh`, same extraction approach as `rcjb_test.sh` (`log()..sync_dir()`
plus `bin/bdjson.sh`):
- AC1/AC2/AC3: fixture shaped exactly like ar5n - `in_progress`, assignee `qa`,
  labels `needs-team-lead,role:qa,stage:verify,story:agent-factory-lv8s`, with `lease_expires_at` in the
  past (and a second case with a future lease) - `ROLE=team-lead AGENT_ID=team-lead`:
  `next_issue` returns it, `claim` returns 0, the stub's recorded argv has no `--if-assignee`, includes
  `--force --assignee team-lead`, and the fixture assignee is now `team-lead`. **Fails on current code.**
  Repeat for `engineer`, `po`, `architect`, `reviewer` (role label matching the assignee).
- AC4: assignee `alice` + `needs-team-lead` (and assignee `engineer` with label `role:qa`):
  `claim` returns 1 and no `bd update` is recorded; `next_issue` does not return the first.
- AC5: stub `update` always fails with stderr "boom": `claim` returns 1, `$CLAIM_ERR` contains "boom";
  after the main-loop failure handling (extract it into a function `handle_claim_failure ID` so it is
  testable - engineer's call on the name, but it must be callable without running the whole loop) the
  id is in the skip list, `next_issue` returns the *next* matching issue (fixture with two), and with
  `CLAIM_SKIP_SECS=0` (or a back-dated entry) the first issue is selectable again.
- Non-team-lead role never uses the takeover branch (guard on `$ROLE`).

Fix `tests/agent-factory-rcjb_test.sh` lines ~66-69: it asserts `--if-assignee po` **and** `--force` in
the same argv, which encodes the bug. Change it to assert `--assignee team-lead --force` and the
**absence** of `--if-assignee`. The engineer does this in the implement stage (it is an existing test
whose expectation the story changes; QA's verify stage should be told in the handoff comment, the same
situation as lv8s vs b50b).
Also grep the other tests (`tests/agent-factory-9awd*`, if present) for `--if-assignee` +
`--force` and update likewise.

Run the whole `tests/` suite per ARCHITECTURE.md's test command.

## Docs

`docs/ARCHITECTURE.md` team-lead paragraph (line ~22): append one sentence - the takeover is a forced
reassign (bd forbids `--force` together with `--if-assignee`), and a claim that fails is logged with
bd's error and skipped for `CLAIM_SKIP_SECS` rather than retried every cycle.

## Single engineer task

Small; no extra issues. First step for the engineer: re-run the repro to confirm bd's behaviour on the
installed version (`bd update <scratch> --if-assignee a --assignee b --status in_progress --force`
must error; the forced update without `--if-assignee` must succeed) using a throwaway issue, closing it
afterwards with `bd close <id> --force`.
