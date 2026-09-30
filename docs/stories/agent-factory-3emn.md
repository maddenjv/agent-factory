# agent-factory-3emn: Tolerate the bd v2.0 `--json` envelope

## Story
As the operator of agent-factory, I want every script that parses `bd ... --json` output to work with both the current bare output and the v2.0 envelope (`BD_JSON_ENVELOPE=1`), so that upgrading bd does not silently stop the agent loop, board, or story tooling.

## Context
bd announces that `--json` output changes in v2.0 (opt in early with `BD_JSON_ENVELOPE=1`). Checked against bd 1.3.0: with the flag, `bd list --json` returns `{"data": [ ... ]}` instead of a bare array `[ ... ]`. agent-factory is **not ready**: its scripts assume the bare shape (`jq '.[]?'`, `if type=="array" then .[0] else . end`, `.[$f]`). Against an envelope, `.[]?` iterates the object's values, `type=="array"` is false so `show` yields the wrapper, and `.status`/`.labels`/`.assignee` are empty. The failures are silent: no ready work is found, role/label checks fail, `is_ready` is false.

Consumers of `bd --json`: `bin/agent-loop.sh` (show_json, is_ready, work picking, completion checks), `bin/board.sh`, `bin/restart-story.sh`, `bin/new-story.sh`, `bin/feature.sh`, `bin/init-project.sh`, `bin/smoke-test.sh`, plus the `--json` usage documented in `agents/team-lead.md` and `agents/architect.md`. The full envelope schema (`docs/reference/json-schema.md` in bd) is not in this repo; the design stage must confirm it for every command used (list, ready, show, create) including error output.

## Acceptance criteria
1. Given `BD_JSON_ENVELOPE` is unset, when any listed script runs, then behaviour is unchanged from today.
2. Given `BD_JSON_ENVELOPE=1`, when agent-loop picks work (`bd list` / `bd ready`), then it selects the same issues as it does without the flag.
3. Given `BD_JSON_ENVELOPE=1`, when a script reads a single issue (`bd show --json`), then status, assignee, labels and other fields resolve to the same values as without the flag.
4. Given `BD_JSON_ENVELOPE=1`, when `bin/board.sh` renders, then the output is identical to the unset case for the same tracker state.
5. Given `BD_JSON_ENVELOPE=1`, when `restart-story.sh`, `new-story.sh` or `feature.sh` read the id or fields of a created or listed issue, then they behave as without the flag.
6. Given `BD_JSON_ENVELOPE=1`, when `bin/smoke-test.sh` runs, then it passes.
7. Given a bd command fails or returns an empty result under either format, when a script parses it, then the script takes the same error/empty path it does today rather than treating an envelope as data.
8. Given role docs that show `bd ... --json` parsing examples, when read, then they do not assume the bare array shape.

## Out of scope
- Setting `BD_JSON_ENVELOPE=1` globally or upgrading bd to v2.0.
- Changing non-JSON bd usage or the stream-json output of Claude Code.
- Any other v2.0 changes not related to `--json`.
