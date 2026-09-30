# Design: tolerate the bd v2.0 `--json` envelope (agent-factory-3emn)

## Confirmed bd behaviour (bd 1.3.0, checked live with and without `BD_JSON_ENVELOPE=1`)
| command | unset (today) | `BD_JSON_ENVELOPE=1` |
|---|---|---|
| `list`, `ready` | `[ {issue}, ... ]` | `{"data":[ {issue}, ... ],"schema_version":1}` |
| `show <id>` | `[ {issue} ]` (1-element array) | `{"data":[ {issue} ],"schema_version":1}` |
| `create` | `{issue}` (bare object) | `{"data":{issue},"schema_version":1}` |
| empty list | `[]` | `{"data":[],"schema_version":1}` |
| error (e.g. `show <missing>`, rc 1, on **stdout**) | `{"error":..,"hint":..,"schema_version":1}` | `{"data":{"error":..,"hint":..},"schema_version":1}` |

Findings that shape the design:
- The envelope is exactly `{data, schema_version}`; `data` keeps the bare shape of the same command. So
  unwrapping is a single, uniform step and every existing filter stays valid after it.
- A bare **error** object already carries `schema_version` but has no `data` key, and issues have no
  `data` key. So the discriminator must be `has("data")` (plus `has("schema_version")`), never
  `schema_version` alone - otherwise the error object would be misread.
- Unwrapped, an envelope error becomes `{"error":..,"hint":..}` - the same "object with no id/status/labels"
  that the scripts already handle on today's error path (AC7). Empty stays `[]`.
- The `warning: beads.role ...` lines go to stderr; scripts already discard or ignore stderr. No change.

## Approach
Normalise at the boundary: one shared jq filter strips the envelope, applied to the output of every
`bd ... --json` before the existing filter. Nothing else in the scripts changes, so with the flag unset
(input has no `data` key) the filter is the identity and behaviour is unchanged (AC1).

### New file `bin/bdjson.sh` (sourced, no side effects, no `set` options)
```bash
# shellcheck shell=bash
# Sourced by every script that parses `bd ... --json`. bd v2.0 wraps that output as
# {"data": <bare output>, "schema_version": N} (opt in early: BD_JSON_ENVELOPE=1); today it is bare.
# bd_unwrap strips the wrapper if present and is the identity otherwise, so callers work with both.
BD_UNWRAP='if type=="object" and has("data") and has("schema_version") then .data else . end'
bd_unwrap() { jq -c "$BD_UNWRAP" 2>/dev/null; }
```
- `bd_unwrap` reads stdin, writes compact JSON. Empty/non-JSON input -> empty output (`2>/dev/null` and jq's
  behaviour on empty input), matching how the downstream `jq ... 2>/dev/null` calls already behave on bd failure.
  Exit status of a pipeline that used to end in the caller's jq is unchanged because `bd_unwrap` is never last
  (it is always followed by the existing filter) except in `show_json`-style helpers, where it replaces
  the old first jq (see below) and keeps the `2>/dev/null` semantics of the old code.
- Also expose `BD_UNWRAP` (string) for scripts that need the filter inlined (`restart-story.sh`'s `j()`).
- Location: `bin/` and sourced via `source "$(dirname "${BASH_SOURCE[0]}")/bdjson.sh"` (same idiom as
  `board.sh` -> `env.sh`). Do **not** put it in `lib.sh`: that is host-only and `agent-loop.sh`/`board.sh`
  run in containers. `KIT_DIR` is bind-mounted read-only at the same path, so the relative source works there.
  `bd_unwrap` doubles as the reference for the role docs.

### Per-script changes (pipe every `bd ... --json` through `bd_unwrap`; keep the existing jq filters)
- `bin/agent-loop.sh` (source next to `env.sh`, line ~66, before `show_json` is defined):
  - `show_json`: `bd show "$1" --json 2>/dev/null | jq -c 'if type=="array" then .[0] else . end'` becomes
    `bd show "$1" --json 2>/dev/null | bd_unwrap | jq -c 'if type=="array" then .[0] else . end' 2>/dev/null`.
    (`issue_field`, `has_label` and the completion checks at ~116/330 all go through `show_json`; no other edit.)
  - `is_ready`, `next_issue` (both branches), `release_stale`: insert `| bd_unwrap` between `bd ...` and the
    existing `jq`. Line ~395 preflight (`bd ready --json >/dev/null`) only checks the exit code: unchanged.
- `bin/board.sh`: `source` bdjson.sh beside env.sh; insert `| bd_unwrap` in `still_needs_human` (show),
  `ready_section`, `needs_human_section`, `blocked_section`, and the in_progress listing (~line 170).
  Rendering is then byte-identical (AC4) because the unwrapped stream is identical.
- `bin/restart-story.sh`: source bdjson.sh; `j()` becomes `bd_unwrap | jq -c 'if type=="array" then .[0] else . end'`;
  `all=$(bd list ... --json --limit 0 | bd_unwrap)` (so later `<<<"$all"` filters see a bare array); the
  `bd create ... --json | jq -r 'if type=="array" ...'` becomes `| bd_unwrap | jq -r ...`.
  Caution: `set -e`/`pipefail` are on - `bd_unwrap` must not fail where the old pipeline did not; it never
  exits non-zero on empty input, and on invalid JSON the old first jq would have failed the same way.
- `bin/new-story.sh`, `bin/feature.sh`, `bin/smoke-test.sh`: source bdjson.sh; the id extraction
  `jq -r 'if type=="array" then .[0].id else .id end'` becomes `bd_unwrap | jq -r '...'` (in smoke-test, both
  `idof` and the `bd show` status read; apply to `idof() { bd_unwrap | jq -r ...; }` and the show pipeline).
- `bin/init-project.sh:89`: `bd ready --json >/dev/null` is exit-code only; no change. (It also does not
  source anything JSON-related, so do not add the source there.)
- Not touched: `bin/set-throttle.sh`, throttle reads and stream-json rendering (`jq` on files/Claude output,
  not on bd).

### Role docs (AC8)
- `agents/architect.md` (the rework `bd create ... --json` line), `agents/team-lead.md` (~28, ~162 `--json` uses):
  add one sentence where each is used: "`--json` output is a bare array/object today but becomes
  `{"data": ..., "schema_version": N}` under bd v2.0 (`BD_JSON_ENVELOPE=1`); unwrap with
  `jq 'if type=="object" and has("data") then .data else . end'` before indexing, and don't assume an array."
  Grep `agents/*.md` and `README.md` for any other `--json` parsing example and apply the same wording
  (as of this design only those three places exist).
- `docs/ARCHITECTURE.md`: add a short "bd `--json` output" convention under Conventions: every script that parses
  bd JSON sources `bin/bdjson.sh` and pipes through `bd_unwrap` first; new consumers must do the same.

## Error / empty cases (AC7)
- bd failure with no stdout, or stderr-only failure: `bd_unwrap` emits nothing, same as today's empty pipeline.
- Error object on stdout (missing id): envelope unwraps to `{"error":..}`; bare stays `{"error":..}`. Both then
  hit the identical downstream path: `show_json` returns that object, `.status`/`.labels`/`.assignee` are
  empty, `is_ready` is false, `restart-story.sh` gets an empty story id and takes its existing failure path,
  `create` id extraction yields `null`/empty exactly as before (the scripts' existing guards apply).
- `jq -e` predicates keep their semantics: unwrap happens upstream of them.

## Acceptance criteria mapping
1. identity when unset (no `data` key) -> AC1. 2. `next_issue`/`is_ready` via unwrap -> AC2.
3. `show_json` unwrap -> AC3. 4. board sections unwrap -> AC4. 5. restart-story/new-story/feature id and
list reads unwrap -> AC5. 6. smoke-test `idof` + status unwrap -> AC6. 7. section above. 8. role docs.

## Test strategy (QA)
No unit framework; write `tests/agent-factory-3emn_test.sh` (bash), Level: script-level with a stub `bd`.
- Put a `bd` stub first on `PATH` that serves fixtures for `list|ready|show|create|update|close` and, when
  `BD_JSON_ENVELOPE=1`, wraps output in `{"data":<bare>,"schema_version":1}` (errors as `{"data":{"error":..},...}`;
  empty lists as `{"data":[],...}`). Keep fixtures identical between modes so the test can diff outputs.
- Run each scenario twice (flag unset / `=1`) and assert equal results:
  - source `bin/bdjson.sh`: `bd_unwrap` on bare array, bare object, bare error object (has `schema_version`, no
    `data` - must pass through unchanged), envelope of each, empty input, `{"data":[],...}`.
  - `bin/board.sh` sections (env-only run as existing board tests do) -> byte-identical output (AC4).
  - `agent-loop.sh` helpers: source the function definitions the way existing tests (e.g. `rcjb`, `b50b`,
    `m7af`) do; check `next_issue` for a build role and team-lead, `is_ready`, `issue_field`, `has_label`,
    `release_stale` (AC2, AC3).
  - `new-story.sh`, `feature.sh`, `restart-story.sh` against the stub: same created-id / same `bd` calls made
    (have the stub log its argv) in both modes (AC5); `restart-story.sh` on an unknown id: same failure path.
  - `smoke-test.sh` with the stub (N=2) exits 0 in both modes (AC6).
  - Missing-issue error and empty-list cases in both modes (AC7).
  - grep `agents/architect.md` and `agents/team-lead.md` mention `data`/`schema_version` (AC8).
- Optional live check (skip if the shared DB isn't reachable): with real bd 1.3.0,
  `BD_JSON_ENVELOPE=1 bin/board.sh` output equals unset output on the same tracker state.
- Regression: existing tests under `tests/` may grep these scripts for the old literal jq lines; the engineer must
  run the whole suite and update only assertions that pin exact text made obsolete by the extra `bd_unwrap` pipe
  stage, flagging any such edit in the handoff. `shellcheck` every touched script.

## Implementation tasks
Single engineer issue (one branch, small change); no extra issues created.
