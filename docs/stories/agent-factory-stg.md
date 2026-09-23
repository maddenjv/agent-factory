# agent-factory-stg: Wait out a usage-limit hit instead of failing the issue

## Story
As an agent-factory operator running the agents unattended, I want an agent that hits the Claude
plan's session limit to wait for the quota reset and retry, so that a temporary quota outage never
burns an issue's attempts or escalates it to `needs-human`.

## Context
`bin/agent-loop.sh` already intends to do this (`quota_hit_message`, `usage_limit_wait_seconds`,
the "not counted as a failed attempt" branch). It did not work in practice: on 2026-09-23 the
architect hit "You've hit your session limit · resets 1:50pm (UTC)" while on agent-factory-5l0. The
loop counted two failed attempts within ~10 seconds, logged "not completed (attempt 1/2)" then
"not completed after 2 attempts; labelled needs-human", and bumped the consecutive-failure
counter. It never slept until the reset.

Evidence in the run transcript (`logs/architect/2026-09-23.agent-factory-5l0.jsonl`): the limit
message appears only in the CLI's stream-json output (a synthetic assistant message with that text,
followed by a `result` event with `is_error: true` and `terminal_reason: "api_error"`), while the
CLI's stderr (`claude-err.log`) was empty. Detection today only scans stderr (deliberately, to avoid
false positives from text the agent merely read), so the real signal is missed. The message wording
and the "resets H:MMam/pm (UTC)" time format are as above.

## Acceptance criteria

1. **Given** an agent session ends because the CLI reported "You've hit your session limit ·
   resets <time>" in its output (with nothing on stderr), **when** the loop handles the outcome,
   **then** it is recognised as a usage-limit hit and the loop waits until shortly after the stated
   reset time before doing anything else.
2. **Given** a usage-limit hit, **when** the loop handles it, **then** the issue's attempt count is
   not incremented, the consecutive-failure counter is not incremented, the issue is not labelled
   `needs-human`, and the issue is released so it can be retried after the wait.
3. **Given** a usage-limit hit whose message has no parseable reset time, **when** the loop handles
   it, **then** it waits the fallback quota-retry interval rather than retrying immediately.
4. **Given** the agent's own conversation merely contains the words "usage limit" or "session
   limit" (e.g. it read a file or issue mentioning them) and the session otherwise ends normally or
   with an ordinary failure, **when** the loop handles the outcome, **then** it is NOT treated as a
   usage-limit hit (ordinary failure accounting applies).
5. **Given** the limit is still in force when the wait ends and the retry hits it again, **when**
   the loop handles it, **then** it again waits without counting a failure.
6. **Given** a usage-limit hit, **when** the loop starts waiting, **then** an alert states that the
   limit was hit and how long the wait is, as it does today.

## Out of scope
- The `DAILY_BUDGET_USD` spend cap, which is a separate mechanism.
- Changing attempt caps or circuit-breaker thresholds for genuine failures.
- Reducing quota consumption or pausing other roles' loops while one waits.
