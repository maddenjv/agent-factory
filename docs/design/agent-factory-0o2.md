# agent-factory-0o2: Board accuracy

## Approach

`bin/board.sh` currently derives two sections directly from `bd`:
- "ready" = `bd ready --json` verbatim.
- "needs-human" = every open issue in `bd list --json` carrying the `needs-human` label.

`bd ready`'s notion of "blocked" is dependency-driven, not label-driven, so an issue that itself
carries `needs-human` but has no open blocking dependency still comes back from `bd ready` (AC1
gap). And issues that *are* correctly excluded from `bd ready` because they depend on a
`needs-human`-labelled issue have nowhere to show up today - they just disappear (AC3 gap).

Fix: keep `bd ready` and `bd list` as the only data sources (no change to any `bd` command
behavior - see "Out of scope"), but post-filter/derive in `jq`:

1. **ready**: filter `bd ready --json` to drop any issue whose own labels include
   `needs-human` (closes AC1). AC2/AC5 (dependency-driven exclusion) already work via `bd
   ready`'s existing blocking logic - untouched.
2. **needs-human**: unchanged.
3. **blocked** (new section, rendered between "needs-human" and "spend today"): from `bd list
   --json`, for every open issue that is *not* itself `needs-human`-labelled, look at its
   dependencies of type `blocks` whose target (`depends_on_id`) is still open (not closed) *and*
   carries the `needs-human` label. If any such blocker exists, print the issue and the blocking
   id(s) it's waiting on (AC3). Because this is computed fresh from current `bd list --json`
   state on every render, a label removal or close on the blocker (AC4) or a non-`needs-human`
   blocker (AC5) naturally fall out of the same filter - no separate invalidation logic needed.
   Only `type == "blocks"` dependencies count (matches what actually gates `bd ready`;
   `discovered-from` and other link types are informational and must not put an issue in
   "blocked").
4. **closed issues** (AC6): every section already filters on `status != "closed"` (ready via
   `bd ready` itself, needs-human and blocked explicitly) - no issue can appear anywhere once
   closed.

Each section becomes its own named function (`ready_section`, `needs_human_section`,
`blocked_section`), following the existing pattern of `still_needs_human`/`recent_alerts`: small,
independently callable, testable by sourcing `bin/board.sh` (guarded by the existing
`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` check, so sourcing never starts the render loop) and
invoking the function directly against a real `bd` instance/scratch project. `render()` becomes a
thin caller of these functions plus the untouched in-progress/spend/alerts blocks.

## Files changed

- `bin/board.sh` only:
  - Extract `ready_section`, `needs_human_section`, `blocked_section` functions (new).
  - `render()` calls them instead of inlining the `bd ready`/`bd list` + `jq` pipelines, and adds
    the new "-- blocked (waiting on a needs-human issue) --" heading between "needs-human" and
    "spend today".

No other files need to change (no new deps, no changes to `agents/`, `docker-compose.yml`, or
`bd`/Beads config). `docs/ARCHITECTURE.md` needs no update - this doesn't change the stack, layout,
or conventions, only a script's internal structure.

## Interfaces / data shapes

Each new function takes no arguments, reads from `bd` (via `bd ready --json` / `bd list --json`),
and prints one line per row to stdout (same convention as `recent_alerts`):

- `ready_section`: `<id>  <comma-joined labels>  <title>` (unchanged format from today, minus
  self-needs-human rows).
- `needs_human_section`: `<id>  <title>` (unchanged from today).
- `blocked_section` (new): `<id>  waiting on <blocker-id>[,<blocker-id>...]  <title>` - joins
  multiple blockers with `,` in the rare case an issue has more than one open `blocks`
  dependency on a `needs-human`-labelled issue.

`jq` logic for `blocked_section`, operating on `bd list --json`'s array (each issue's
`dependencies` field is a flat array of `{issue_id, depends_on_id, type, ...}` records - *not*
nested full issue objects, unlike `bd show --json`; confirmed by inspecting live output):

```
( [.[] | select(.status != "closed")] ) as $open
| ($open | map({key: .id, value: (.labels // [])}) | from_entries) as $labels
| ($open | map({key: .id, value: .status}) | from_entries) as $status
| $open[]
| . as $issue
| select(($issue.labels // []) | index("needs-human") | not)
| ((.dependencies // [])
    | map(select(.type == "blocks"))
    | map(.depends_on_id)
    | map(select(($status[.] // "closed") != "closed"))
    | map(select(($labels[.] // []) | index("needs-human")))
  ) as $blockers
| select(($blockers | length) > 0)
| "\($issue.id)  waiting on \($blockers | join(","))  \($issue.title)"
```

`ready_section`'s filter is a single added `select`:

```
bd ready --limit 50 --json 2>/dev/null \
  | jq -r '.[]? | select((.labels // []) | index("needs-human") | not)
                | "\(.id)  \((.labels // []) | join(","))  \(.title)"'
```

## Error handling

Same posture as the rest of the script: `bd ... 2>/dev/null` plus `jq -r '...?'` / `// []`
defaults everywhere, so a transient `bd`/Dolt hiccup renders an empty section for that refresh
(next 15s loop retries) rather than crashing the board. No new failure modes are introduced -
`blocked_section` fails the same way `needs_human_section` already does today (empty output on
`bd` failure, consistent with the "fail open by omission, not by crash" pattern already used for
the render loop; note this differs from `still_needs_human`'s explicit fail-open-by-keeping-alert
behavior, which only applies to that one already-logged-alert case).

## Acceptance criteria coverage

| AC | How satisfied |
|----|----------------|
| 1  | `ready_section` drops rows whose own labels include `needs-human`. |
| 2  | Unchanged: `bd ready` already excludes issues with an open blocking dependency. |
| 3  | `blocked_section` (new), scoped to `type == "blocks"` deps on an open `needs-human` issue. |
| 4  | `blocked_section` recomputes from live `bd list --json` every render; once the label is gone or the blocker is closed, the `select` on `$labels`/`$status` drops it, and `ready_section`/`bd ready` will surface it in "ready" again on the same render if it has no other open blocker. |
| 5  | `blocked_section`'s `$labels[...] | index("needs-human")` filter excludes non-`needs-human` blockers; such issues remain excluded from "ready" via `bd ready`'s existing logic, exactly as today. |
| 6  | Every section filters `status != "closed"` (directly, or via `bd ready` never returning closed issues). |

## Test strategy (for QA)

No unit-test framework (per `docs/ARCHITECTURE.md`); this is an acceptance-style bash script
check. QA should:

1. `shellcheck bin/board.sh` - must be clean.
2. Source the script without triggering the render loop and call each function directly against
   the shared `bd`/Dolt instance (safe: `render()`'s `while :; do ... sleep 15; done` loop only
   runs when the script is executed directly, guarded by
   `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`; sourcing skips it):
   ```bash
   source bin/board.sh
   ready_section
   needs_human_section
   blocked_section
   ```
3. Using scratch issues created with `bd create` (clean up with `bd close`/delete afterward, or
   use a disposable `PROJECT_DIR`/Beads DB if the harness supports one - do not leave test
   fixtures in the shared tracker), exercise each AC as a scenario:
   - **AC1**: create issue A, `bd label add A needs-human`, no dependencies -> assert A is absent
     from `ready_section` output and present in `needs_human_section` output.
   - **AC2/AC3**: create issue A (`needs-human` labelled) and issue B with
     `bd dep add B A --type blocks` -> assert B is absent from `ready_section`, absent from
     `needs_human_section`, and present in `blocked_section` with A named as the blocker.
   - **AC4**: from the AC2/AC3 setup, `bd label remove A needs-human` (or `bd close A`) -> assert
     B disappears from `blocked_section` and (assuming no other blockers) reappears in
     `ready_section`.
   - **AC5**: create issue A (no `needs-human` label) and issue B depending on it via
     `bd dep add B A --type blocks` -> assert B is absent from `ready_section` (existing `bd
     ready` behavior) and absent from `blocked_section`.
   - **AC6**: take any of the above fixtures and `bd close` the dependent issue itself -> assert
     it is absent from all three of `ready_section`, `needs_human_section`, `blocked_section`.
   - Also confirm a `discovered-from` dependency on a `needs-human` issue does **not** produce a
     `blocked_section` row (distinguishes `blocks` from other dependency types, per "out of
     scope").
4. Visual smoke check: run `bin/board.sh` directly for one render cycle (e.g. `timeout 2
   bin/board.sh` or Ctrl-C after the first screen) and confirm the new "-- blocked --" heading
   appears in the right position (between "needs-human" and "spend today") with sane formatting.
