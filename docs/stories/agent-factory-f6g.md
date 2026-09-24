# agent-factory-f6g: Pass an answer/feedback message through approve.sh

## Story
As an agent-factory operator unsticking a `needs-human` issue, I want to attach my answer or
feedback to the issue as part of running `approve.sh`, so that the agent picking the issue back up
reads what I actually decided instead of just seeing its own stale question cleared.

## Context
`bin/approve.sh <issue-id>...` currently only removes the `needs-human` label, reopens the issue,
and appends a generic "Approved via approve.sh ... any note above is stale; proceed." note
(bin/approve.sh:6-16) — there's no way to pass the human's actual answer through it. Today an
operator has to separately run `bd comment` or `bd update --append-notes` before or after
`approve.sh` to record their answer, which the README's "Unstick an issue" row
(`answer what the issue's note asked for, then approve.sh <id>`) already assumes happens but the
script doesn't support directly. This story adds that support to the script itself.

`approve.sh` today accepts multiple issue ids in one call with no per-id text. A message is
necessarily specific to one issue's question, so this story adds an optional message limited to
single-id invocations; multi-id invocations keep today's no-message behavior unchanged.

## Acceptance criteria

1. **Given** a `needs-human` issue, **when** the operator runs `approve.sh <id> -m "<message>"`,
   **then** the issue's `needs-human` label is removed, its status is reopened, and its notes
   contain the operator's message text (not just the generic "approved" note).
2. **Given** a `needs-human` issue, **when** the operator runs `approve.sh <id> -m "<message>"`,
   **then** the note recorded is distinguishable as the human's answer (not indistinguishable from
   the generic auto-approval note already produced today) so the next agent reading `bd show <id>`
   can tell an answer was given, not just that approval happened.
3. **Given** no `-m` flag, **when** the operator runs `approve.sh <id>...` with one or more ids
   (today's existing usage), **then** behavior is unchanged from today: label removed, status
   reopened, generic "approved... proceed" note appended, for every id given.
4. **Given** more than one issue id, **when** the operator also passes `-m "<message>"`,
   **then** `approve.sh` exits non-zero with an error explaining that a message can only be
   attached to a single issue, and makes no changes to any of the listed issues.
5. **Given** `-m` is passed with an empty string, **when** `approve.sh <id> -m ""` runs, **then**
   it exits non-zero with an error and makes no changes (an empty message is not a valid answer).

## Out of scope
- Changing how `needs-human` is set in the first place (agent-loop.sh, new-story.sh's
  `HUMAN_APPROVE_STORIES` gate note, or any agent's own `--append-notes` call).
- Any interactive prompt for the message (operator must pass it on the command line).
- Structured/multi-field feedback (e.g. approve vs. reject with reasons) - this story is a single
  free-text message attached at approval time.
- Changes to `board.sh`, `ops-shell.sh`, or other scripts beyond `bin/approve.sh` and the README
  row documenting it.
