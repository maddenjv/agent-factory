# Design: WIP limit yields when it would leave a role idle (agent-factory-zwn7)

## Approach
Only `bin/agent-loop.sh` changes (`wip_ok()`, plus a new `idle_downstream_role()`), plus docs.
`in_flight()` and the `WIP_LIMIT` comparison stay exactly as they are, so AC5 (limit itself
unchanged) holds by construction, and `in_flight()`'s existing `needs-human`/`needs-team-lead`
stall exclusion (`agent-factory-8wq`, `agent-factory-ulq`) is untouched (AC4, half of it).

Today: `wip_ok() { [ "$ROLE" != "po" ] || [ "$(in_flight)" -lt "$WIP_LIMIT" ] 2>/dev/null; }`.

New rule: when the PO is at or above `WIP_LIMIT`, it is *still* allowed to start a story if at
least one of architect/engineer/qa/reviewer currently has no work available for its `role:<role>`
label - neither a ready issue nor one it already has in progress. "Ready" mirrors `bd ready`'s own
definition (open, and every `blocks`-type dependency resolved) rather than shelling out to `bd
ready` four times, so the whole check is one `bd list --json` call plus one `jq`, same shape and
cost as `in_flight()`.

A `role:<role>` issue counts as "work available" for that role iff, among all non-closed issues
carrying that label:
1. it is **not stalled** - not labelled `needs-human` or `needs-team-lead` (AC4, same test
   `in_flight()` already applies to the reviewer issue); and
2. it is either `status == "in_progress"` (already claimed - AC1's "no issue it's already
   claimed"), or `status == "open"` and every one of its `blocks`-type dependencies is resolved.

A dependency (`.dependencies[] | select(.type=="blocks") | .depends_on_id`) is resolved if it is
closed. `bd list --json` (no `--all`) only ever returns open/in_progress issues, so in real output
a `depends_on_id` that doesn't appear in the list at all is closed by omission; a QA fixture (per
the `agent-factory-8wq` test convention, e.g. `issue e-impl e engineer closed needs-human`) may
instead list it explicitly with `status:"closed"`. Both must count as resolved, so the lookup
defaults a missing id to `"closed"` rather than treating "absent" and "open" the same way (see
implementation below - `$status[.depends_on_id] // "closed"`, not presence/absence alone).

The PO is idle-eligible iff at least one of the four downstream roles has zero such issues -
i.e. `{architect,engineer,qa,reviewer} - active_roles` is non-empty, where `active_roles` is the
set of `role:*` labels appearing on qualifying issues.

No state is cached anywhere: `wip_ok()` recomputes `in_flight()` and (when needed)
`idle_downstream_role()` fresh from Beads on every call, at the loop's normal `IDLE_SLEEP` polling
cadence (`bin/agent-loop.sh`'s main loop), so AC3 (a role going idle unblocks the PO on its next
check, no extra plumbing) falls out for free.

## Implementation (`bin/agent-loop.sh`)

Add `idle_downstream_role()` next to `in_flight()`, and change `wip_ok()` to call it only when
already at the limit (so the extra `bd list --json` call never runs in the common case where the
PO is under `WIP_LIMIT`):

```bash
in_flight() {  # unchanged
  ...
}

idle_downstream_role() {  # true if architect, engineer, qa or reviewer has no ready or in-progress,
                           # non-stalled role:<role> issue - i.e. the PO could unblock it by starting
                           # another story. "Ready" mirrors bd ready: open, and every "blocks"
                           # dependency is resolved (closed - either absent from bd list's default
                           # open/in_progress-only output, or explicitly status:"closed" in a test
                           # fixture). Same needs-human/needs-team-lead stall exclusion as in_flight().
  local list; list=$(bd list --json 2>/dev/null)
  [ -n "$list" ] || return 1   # bd unreachable -> fail safe, same as in_flight() -> wip_ok false
  printf '%s' "$list" | jq -e '
    (map({key: .id, value: .status}) | from_entries) as $status
    | (map({key: .id, value: (((.labels // []) | index("needs-human")) != null
                               or ((.labels // []) | index("needs-team-lead")) != null)})
       | from_entries) as $stalled
    | ["architect","engineer","qa","reviewer"] as $roles
    | [ .[]
        | select(.status != "closed")
        | select($stalled[.id] | not)
        | select(.status == "in_progress"
                 or (.status == "open"
                     and ([ (.dependencies // [])[] | select(.type == "blocks")
                            | ($status[.depends_on_id] // "closed") ]
                          | all(. == "closed"))))
        | (.labels // [])[] | select(startswith("role:")) | ltrimstr("role:")
      ] as $active
    | ($roles - ($active | unique)) | length > 0
  ' >/dev/null 2>&1
}

wip_ok() {
  [ "$ROLE" != "po" ] && return 0
  [ "$(in_flight)" -lt "$WIP_LIMIT" ] 2>/dev/null && return 0
  idle_downstream_role
}
```

Notes for the engineer:
- The explicit `[ -n "$list" ] || return 1` guard is required, not decorative: piping empty input
  straight into `jq -e '(map(...) ...'` makes the filter run zero times (no top-level `.` to act
  on), and a zero-output `jq -e` run exits `0` - the *opposite* of the fail-safe behaviour we want
  when `bd` is unreachable (compare `in_flight()`, where `[ "" -lt "$WIP_LIMIT" ]` reliably fails).
  Verify this with `printf '' | jq -e '.'; echo $?` if in doubt - it prints `0`.
- `$status[.depends_on_id] // "closed"` (not a presence/absence check on a `$closed` set) is what
  makes both real `bd list` output (closed = absent) and explicit-`status:"closed"` test fixtures
  resolve correctly; a naive `$closed_ids | has(...)`-style set built only from what's in the list
  cannot represent "closed" for the real-output case, since closed issues never appear in the list
  at all.
- `wip_ok()`'s two-statement body preserves today's behaviour exactly when `ROLE != po` or when
  under the limit (`idle_downstream_role` is never invoked in either case - AC5, AC2 unaffected
  cost-wise); it only runs the new check once the PO is already at/above `WIP_LIMIT`.
- Keep `2>/dev/null` on the `in_flight()` comparison as today (tolerates non-numeric/empty output
  the same way).
- This only ever affects `ROLE=po`; no other role calls `wip_ok()` (`bin/agent-loop.sh`'s main
  loop calls it unconditionally, but the `[ "$ROLE" != "po" ] && return 0` short-circuit is
  unchanged from today), so architect/engineer/qa/reviewer's own claiming is untouched (out of
  scope, confirmed by construction).
- `shellcheck bin/agent-loop.sh` must stay clean.

## Docs (AC6)

- `.env.example` line 24 - append to the existing `WIP_LIMIT=2` comment (which already covers the
  `needs-human`/`needs-team-lead` exclusion from `agent-factory-8wq`/`agent-factory-ulq`) something
  like: `; yields anyway if architect/engineer/qa/reviewer would otherwise sit idle with no ready
  or in-progress work`. Keep the existing text intact - don't replace it, since AC6 of
  `agent-factory-8wq` already required the `needs-human` wording to stay.
- `README.md` Guardrails paragraph (~line 115, the sentence starting "WIP limit on the PO
  (`WIP_LIMIT`; ...)"): extend the same parenthetical with the yield-when-idle behaviour, e.g.
  "...are not counted; the limit also yields - lets the PO start another story anyway - whenever
  architect, engineer, qa or reviewer would otherwise have nothing ready or in-progress for their
  role)". The string `WIP_LIMIT` and a mention of idle/yielding must both appear in the same
  sentence, same pattern QA used for `agent-factory-8wq`'s AC6 grep.

## Error cases

`bd list` failure -> `idle_downstream_role` returns 1 (see the `[ -n "$list" ]` guard above) ->
`wip_ok` false -> PO waits, same failure mode as `in_flight()` failing today. No new failure modes:
`idle_downstream_role` is a pure read (no mutation), so a crash mid-check leaves nothing to clean
up.

## Test strategy (QA)

No framework (see `docs/ARCHITECTURE.md`). Extend `tests/agent-factory-zwn7_test.sh` following the
`tests/agent-factory-8wq_test.sh` pattern exactly: same stub `bd` (cats a fixture file for `bd
list`), same `issue`/`chain` fixture helpers, extract both `in_flight` and the two new functions
from `bin/agent-loop.sh` (`sed -n '/^in_flight()/,/^wip_ok()/p'` now also captures
`idle_downstream_role`, since it sits between them - adjust the `sed` range if the engineer places
it elsewhere), and read `wip_ok`'s exit status the same way the existing `run()` helper does.

1. **AC1**: `WIP_LIMIT` full chains for two stories (`chain a; chain b` with `WIP_LIMIT=2`, so
   `in_flight` = 2, at the limit) but *no* `role:reviewer` issue open anywhere (e.g. both chains
   only go up to `*-ver`, no `*-rev`) -> `wip_ok` true (reviewer idle).
2. **AC2**: same two full `chain` stories at the limit, but this time include a `role:reviewer`
   issue for a third, unrelated in-progress-everywhere scenario so all four roles have something
   ready/in-progress (e.g. add an extra open `role:architect` design issue, an extra open
   `role:engineer` issue, etc., each independently ready) -> `wip_ok` false.
3. **AC3**: start from the AC2 fixture (`wip_ok` false), then remove the one issue that was giving
   `reviewer` work (close it or drop it) -> `wip_ok` true on the next call, same fixture otherwise.
4. **AC4**: a story whose only downstream-role issue for some role is labelled `needs-human` (or
   `needs-team-lead`) -> that role must still count as idle (the stalled issue doesn't count as
   "work available"), so `wip_ok` true even though `bd show` would list an issue under that label.
   Also check the in-progress case: an issue that is both `status:in_progress` and stalled-labelled
   must not count either.
5. **AC5**: `WIP_LIMIT` chains, all four roles independently have ready/in-progress work -> `wip_ok`
   false (limit still holds - this is the base 8wq-style case, re-run here to confirm the new
   exception didn't loosen the normal case).
6. **AC6**: `grep` `.env.example` and `README.md` for the `WIP_LIMIT` line/sentence and assert it
   mentions idle/yielding in addition to the existing `needs-human` wording (both must be present
   in the same line/sentence, mirroring the AC6 test in `tests/agent-factory-8wq_test.sh`).
7. Regression: re-run the existing `tests/agent-factory-8wq_test.sh` cases unmodified (in_flight
   itself didn't change) plus `bash -n` / `shellcheck bin/agent-loop.sh` clean.
8. Edge case worth covering explicitly: a `role:engineer` issue that is `status:open` but blocked
   by an *open* dependency of a different, unrelated story (no `needs-*` label anywhere) must not
   count as "ready" for engineer (still correctly idle) - this is the case that catches a
   presence/absence-only implementation bug (see the implementation note above about
   `$status[...] // "closed"`).
