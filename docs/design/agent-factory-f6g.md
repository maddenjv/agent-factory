# Design: agent-factory-f6g - pass an answer through approve.sh

Only `bin/approve.sh` and the README "Unstick an issue" row (README.md:80) change. No new files, no
new dependencies.

## Interface
`approve.sh [-m <message>] <issue-id>...` (`-m` / `--message`, accepted before, between or after ids).
- No `-m`: identical to today, for any number of ids.
- `-m <message>`: exactly one id required; message must be non-empty.

## Approach
1. **Parse first, mutate never until validated.** Loop over `"$@"` with a `case`:
   `-m|--message)` requires a following arg (`[ $# -ge 2 ]`, else error "-m requires a message"),
   sets `msg`, `have_msg=1`, `shift 2`; `-m=*`/`--message=*` optional, not required; `-*` unknown
   flag -> usage error exit 2; anything else appended to an `ids` array. Use `have_msg` (not
   `-n "$msg"`) so `-m ""` is distinguishable from no `-m`.
2. **Validate** (all before any `bd` call; errors to stderr, exit 2):
   - `have_msg` and `msg` empty/whitespace-only -> "message must not be empty" (AC5).
   - `have_msg` and `${#ids[@]} -ne 1` -> "a message can only be attached to a single issue" (AC4;
     also covers zero ids with `-m`).
3. **Per id** (unchanged flow): `bd label remove`, `bd update --status open`, then one
   `bd update --append-notes`. Keep the existing `|| true` tolerance and the existing stale-note
   comment block. The note text depends on `have_msg`:
   - none: unchanged `Approved via approve.sh by $(whoami) at $ts - any note above is stale; proceed.`
   - with message: `Human answer via approve.sh by $(whoami) at $ts: <msg> - Approved; any note above is stale; proceed using this answer.`
   Single note (one append, not two) so ordering is unambiguous and the prefix `Human answer` is the
   greppable marker distinguishing it from the generic note (AC2). Pass `$msg` as a single quoted
   argument; never `eval` or interpolate into a command string.
4. `echo "released $id"` unchanged. Update the usage comment line and the README row to show
   `approve.sh <id> -m "<answer>"`.

## AC mapping
1 label removed + reopened + note contains message: step 3. 2 `Human answer` prefix. 3 no-`-m` path
untouched. 4/5 step 2, before any mutation.

## Test strategy (QA; per ARCHITECTURE.md, acceptance-style shell test in tests/acceptance/)
Put a stub `bd` first on PATH that logs its argv to a file (no real Dolt needed), run script, assert:
- `approve.sh X -m "use option B"`: exit 0; log shows label remove, status open, one append-notes
  whose text contains `use option B` and `Human answer`.
- No `-m`, one and several ids: exit 0; each id gets label remove/status/append with exact generic text
  and no `Human answer`.
- `approve.sh A B -m "x"` and `-m x A B`: exit non-zero, stderr mentions single issue, stub log empty.
- `approve.sh X -m ""` and `-m "   "`: non-zero, log empty. `approve.sh X -m` (missing arg): non-zero, log empty.
- Message with quotes/`$`/backticks/newline is recorded verbatim (single argv element).
- `shellcheck bin/approve.sh` clean.
