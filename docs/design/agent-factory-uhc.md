# Design: agent-factory-uhc - move board into ops, give team-lead its old slot

## Context
`bin/start.sh` builds two tmux windows. Today `agents` gets a `board` pane (`bin/board.sh`) first,
then one pane per role in `ROLES=(po architect qa engineer reviewer)`, all created through the
`pane()` helper (which also handles the "first call creates the session, later calls split it"
branching and re-tiles). `ops` is a single interactive-shell pane created directly (not through
`pane()`), with no `pane-border-status`/`pane-border-format` set on it.

`team-lead` support (role recognized by `bin/agent-loop.sh`, `agents/team-lead.md`) landed on
`main` via `agent-factory-dx0` - confirmed present at `origin/main` (`agents/team-lead.md` exists;
`agent-loop.sh` handles `ROLE=team-lead` generically, including the sanitized `MODEL_TEAM_LEAD`
lookup). `bin/start.sh` itself does not yet create a `team-lead` pane anywhere - that's this
story's job, not a leftover from `dx0`. This story only rearranges pane/window membership in
`bin/start.sh`; it doesn't touch `bin/board.sh`, `bin/ops-shell.sh`, or team-lead's own behaviour.

QA already wrote `tests/acceptance/agent-factory-uhc.sh` directly from the story (stage:tests ran
before this design, by convention - see that file's header) and pushed it on
`story/agent-factory-uhc-tests`. Its fake-tmux/fake-docker harness inspects the exact sequence of
`tmux` invocations `bin/start.sh` issues, so this design is written to produce a specific,
literal command sequence rather than leaving the engineer to improvise one that merely "looks
right" - see "Exact command sequence" below, which the tests parse structurally (pane role, pane
window, cmd string, `-t`/`-n` targets), not by matching a whole line verbatim.

## Approach

### 1. `agents` window: swap `board` for `team-lead` in the first pane-creation call
Delete the standalone `pane board shell --entrypoint bash agent "$KIT_DIR/bin/board.sh"` call.
Replace it with a `team-lead` pane created through the *same* `pane()` helper used for every other
role, in the exact same position (the first call - the one that creates the session):
```bash
pane team-lead team-lead agent
for r in "${ROLES[@]}"; do pane "$r" "$r" agent; done
```
`ROLES` stays `(po architect qa engineer reviewer)`, unchanged - the loop is untouched, so those
five keep their existing relative order (AC2, second half). Because `pane team-lead team-lead
agent` is the *first* `pane()` call, it's the one that runs `tmux new-session` and therefore is
first among the window's panes (AC2, first half; it lands in the position `board` used to occupy).
The window ends up with exactly six panes - `team-lead po architect qa engineer reviewer` - and no
`board.sh` invocation anywhere in it (AC1). No changes needed to `pane()` itself, or to the
`remain-on-exit`/`pane-border-status`/`pane-border-format`/tiled-layout lines that already follow
the loop - they apply window-wide and don't care which roles occupy the panes.

### 2. `ops` window: add the board pane, built directly (not via `pane()`)
`pane()` is hardwired to `$WIN` (`agents`) and to a plain (non-split-percentage) split, so it
can't build ops's two-pane, unevenly-sized layout - construct these calls directly, the same way
the current single-pane `ops_cmd` already is:
```bash
ops_cmd="PROJECT_DIR='$PROJECT_DIR' KIT_DIR='$KIT_DIR' AGENT_ENV_FILE='$AGENT_ENV_FILE' ROLE=shell docker compose -f '$KIT_DIR/docker-compose.yml' run --rm --name factory-ops --entrypoint bash agent '$KIT_DIR/bin/ops-shell.sh'"
board_cmd="PROJECT_DIR='$PROJECT_DIR' KIT_DIR='$KIT_DIR' AGENT_ENV_FILE='$AGENT_ENV_FILE' ROLE=shell docker compose -f '$KIT_DIR/docker-compose.yml' run --rm --name factory-board --entrypoint bash agent '$KIT_DIR/bin/board.sh'"
tmux new-window -t "$SESSION" -n ops "$ops_cmd"
tmux select-pane -t "$SESSION:ops" -T shell
tmux split-window -v -b -p 33 -t "$SESSION:ops" "$board_cmd"
tmux select-pane -t "$SESSION:ops" -T board
```
Notes:
- `board_cmd` is byte-for-byte the same shape as today's `board` pane command (`ROLE=shell`,
  `--entrypoint bash agent`, `bin/board.sh`, `--name factory-board`) - only its window/pane
  changed, not what it runs or how (AC3). Keeping `--name factory-board` (rather than
  `factory-<new-title>`) means the container identity is unchanged too, though nothing in the
  acceptance criteria requires that - it's just the least surprising choice.
- `-v` (vertical/stacked split) plus `-b` (new pane goes *before*, i.e. *above*, the target for a
  vertical split) puts `board` above the pre-existing shell pane (AC4, "above").
- `-p 33` sizes the *new* pane (`board`) to 33% of the window's height; the shell pane keeps the
  remaining ~67% automatically (AC4, "approximately one third" - the acceptance test accepts
  20-45%, so 33 has headroom on both sides).
- `select-pane -T` titles both panes, matching the existing per-pane title convention in `agents`
  (needed for `pane-border-format` to show anything meaningful once enabled on `ops`, next step).

### 3. `ops` window: mirror `agents`'s three window options
Immediately after the block above:
```bash
tmux set-option -w -t "$SESSION:ops" remain-on-exit on
tmux set-option -w -t "$SESSION:ops" pane-border-status top
tmux set-option -w -t "$SESSION:ops" pane-border-format "#{pane_title}"
```
Same three options, same values, as already set on `agents` - literally copy those three lines
with `$WIN` replaced by `ops` (AC5). Don't add anything beyond these three; the acceptance test
checks the option set on each window for equality, not just superset.

### 4. Startup summary: describe the new layout
Replace the two summary lines that currently read:
```
echo "Window '$WIN': panes board ${ROLES[*]}   (Ctrl-b o to cycle panes, Ctrl-b q to show numbers, Ctrl-b n/p for windows)"
echo "Window 'ops' is separate - that's the shell you type into."
```
with:
```bash
echo "Window '$WIN': panes team-lead ${ROLES[*]}   (Ctrl-b o to cycle panes, Ctrl-b q to show numbers, Ctrl-b n/p for windows)"
echo "Window 'ops': shell pane (where you type) plus a board pane above it - the live status view, relocated here."
```
The first line now lists all six agent roles and never mentions `board`; the second now mentions
both `ops` and `board` (AC7). Nothing else in the script prints window contents, so no other lines
need to change.

### 5. `bin/start.sh`'s early-exit path (AC6) needs no change
`if tmux has-session ...; then echo "Already running..."; exit 0; fi` already runs before any of
the above and is untouched by this design - a second invocation still short-circuits immediately,
issuing exactly one `tmux` call (`has-session`) and altering nothing. Flagged explicitly only
because it's an acceptance criterion; there is no code change to make here.

## Exact command sequence
For reference, the full sequence of `tmux` calls `bin/start.sh` issues on a fresh run, in order
(everything except the `pane()` internals is spelled out above):
1. `tmux has-session -t "$SESSION"` (fails - session doesn't exist yet)
2. `tmux new-session -d -s "$SESSION" -n agents <team-lead cmd>` + `select-pane -T team-lead`
3. `tmux split-window -t "$SESSION:agents" <po cmd>` + `select-layout tiled` + `select-pane -T po`
4. ...same for architect, qa, engineer, reviewer (existing loop, unchanged)
5. `set-option -w agents remain-on-exit on` / `pane-border-status top` / `pane-border-format ...`
6. `select-layout -t "$SESSION:agents" tiled`
7. `tmux new-window -t "$SESSION" -n ops <ops cmd>` + `select-pane -T shell`
8. `tmux split-window -v -b -p 33 -t "$SESSION:ops" <board cmd>` + `select-pane -T board`
9. `set-option -w ops remain-on-exit on` / `pane-border-status top` / `pane-border-format ...`
10. `tmux select-window -t "$SESSION:ops"`

## Acceptance criteria mapping
1. §1: swapping `board` for `team-lead` as the first `pane()` call, loop over `ROLES` unchanged ->
   exactly six panes, one per role, no `board.sh` in `agents`.
2. §1: `team-lead` is the first `pane()` call (board's old slot); `ROLES` loop untouched, so the
   other five keep their existing order.
3. §2: `board_cmd` unchanged in shape from today's `board` pane command, now issued as the second
   pane-creation call in the `ops` window alongside the pre-existing `ops_cmd`.
4. §2: `-v -b -p 33` places `board` above the shell pane at ~1/3 height.
5. §3: same three `set-option -w` calls, same values, copied onto `ops`.
6. §5: early-exit path is pre-existing and untouched.
7. §4: summary lines rewritten to list all six `agents` roles (no `board`) and to mention `board`
   as part of `ops`.

## Test strategy (QA)
Acceptance tests already exist at `tests/acceptance/agent-factory-uhc.sh` (written directly from
the story before this design, per this project's stage:tests convention) and don't need
rewriting - they were built against fake `tmux`/`docker` binaries on `PATH` that log every
invocation, then parse pane-creation calls (`new-session`/`split-window`/`new-window`) and
`set-option` calls per window, structurally (by role, window target, and command substring) so
they don't depend on exact flag ordering. Verified by inspection above that the command sequence
this design produces satisfies each parser's expectations (roles-per-window, pane-creation order,
`board.sh`/`ops-shell.sh` substrings, option sets per window). One criterion (AC4, real pane
geometry - top offset and rendered height) can't be verified through the fake-tmux harness at all
and is written to `SKIP` when a real `tmux` binary isn't on `PATH`; QA's verify pass should run it
under a real `tmux` if one is available in that environment, and rely on the AC1/AC2/AC3/AC5
structural tests (which fully pin down the `-v -b -p 33` flags via the logged command string) as
the fallback otherwise. `shellcheck -x bin/start.sh` is included in the suite as a standing
quality gate.

## Out of scope
As in the story: `bin/board.sh`'s own content/behaviour, `team-lead`'s runtime logic (both
`agent-factory-dx0`), and the `agents` window's tiled-layout algorithm beyond fitting one more
pane. Also out of scope, not requested by any acceptance criterion: updating `README.md`'s
architecture diagram/prose (`board | po | architect | qa | engineer | reviewer` panes list, "Five
Claude Code agents" framing) - it's already stale from `team-lead`'s addition in
`agent-factory-dx0` and nothing in this story's acceptance criteria touches it; leaving it as a
pre-existing inconsistency rather than expanding this story's scope.
