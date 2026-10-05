# Design: agent-factory-8j3y - Copilot agents can run kit scripts outside their workspace

Story: `docs/stories/agent-factory-8j3y.md`.

## Problem
Under `HARNESS=copilot`, `run_harness_session()` (`bin/agent-loop.sh`) runs
`copilot -p ... --allow-all-tools --no-ask-user -s` with cwd `$REPO`. `--allow-all-tools` approves
tools but Copilot CLI's *path* sandbox still only allows the cwd (and tmp), so reading or running
`$KIT_DIR/bin/*.sh` / `$KIT_DIR/agents/*.md` is refused.

## Approach
Add `--add-dir "$KIT_DIR"` to the Copilot session args in `run_harness_session()`. `--add-dir` adds one
directory to Copilot's allowed-path list (read and execute within it); it is the narrowest flag that
satisfies the story and does not loosen anything else. Rejected: `--allow-all-paths` / `--yolo` -
disables path checks entirely, which the story's out-of-scope section rules out (no loosening beyond kit access).

Change (one line, `bin/agent-loop.sh` ~line 299):

```bash
local args=(-p "$prompt" --allow-all-tools --no-ask-user -s --add-dir "$KIT_DIR")
```

Nothing else changes:
- `cd "$REPO"`, `timeout "$ITERATION_TIMEOUT"`, `--model` handling stay as is (AC3).
- The `claude-code` branch is untouched (AC4).
- The preflight call (~line 423) is deliberately NOT changed: it runs no kit scripts, and leaving it
  byte-identical keeps its quota-hit handling unchanged (AC5).
- `$KIT_DIR` is already required and absolute (`KIT_DIR="${KIT_DIR:?...}"`), so no new validation.
  Quote it (paths may contain spaces). Applies to every role including the throttle assessment
  (both go through `run_harness_session`), satisfying "all roles equally".

Not changed: `PROJECT_DIR`/`DATA_DIR` access. Scripts such as `set-throttle.sh` write control state
from their own process, which the Copilot path sandbox does not govern once the script is allowed to run.

## Docs
Add one sentence to `docs/ARCHITECTURE.md` near the harness description (~line 44): under copilot
the session is started with `--add-dir "$KIT_DIR"` so agents can read/run kit scripts outside their clone.

## Acceptance criteria mapping
1-2. `--add-dir "$KIT_DIR"` grants read/execute under `$KIT_DIR` for all roles.
3. Remaining flags, cwd, model, timeout unchanged.
4. claude-code branch untouched.
5. Preflight line untouched.

## Test strategy (QA)
No real Copilot is available in CI, so use a stub `copilot` on PATH that records its argv and cwd
(same pattern as existing `tests/agent-factory-bki_test.sh` / `lv8s`):
- HARNESS=copilot, call a session (role or throttle): argv contains `--add-dir` immediately followed by
  `$KIT_DIR`, plus `-p`, `--allow-all-tools`, `--no-ask-user`, `-s`; cwd is `$REPO`; `--model` passed
  only when MODEL set (AC1-3). Test with a KIT_DIR containing a space.
- HARNESS=claude-code: argv has no `--add-dir` and equals the previous invocation (AC4).
- Preflight with copilot stub: argv is exactly `-p "Reply with the single word OK." --allow-all-tools
  --no-ask-user -s` (no `--add-dir`); quota-hit stub output still produces the usage-limit wait/alert (AC5).
- Real enforcement (AC1/2 end to end) cannot be verified without Copilot auth; mark as manual/skip.
  Engineer should confirm the flag name with `copilot --help` in the built image; if `--add-dir`
  is not accepted, stop with `needs-team-lead` rather than falling back to `--allow-all-paths`.
