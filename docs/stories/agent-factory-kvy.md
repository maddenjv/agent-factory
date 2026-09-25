# agent-factory-kvy: Approval note uses a fixed, unambiguous closing sentence

## Story
As an agent-factory operator, I want the note `approve.sh` appends when I pass an answer to end with
the exact sentence "Approved; any note above is stale; proceed using this answer.", so that the
agent picking the issue back up treats my answer as authoritative instead of ignoring it.

## Context
`bin/approve.sh -m "<answer>"` appends one note of the form
`Human answer via approve.sh by <user> at <time>: <answer> - Approved; any note above is stale; proceed using this answer.`
The approval wording is glued to the answer on the same line with a dash, so it reads as part of
the answer and an agent can overlook or discount the answer. The approval sentence should be
a standalone, fixed sentence that unambiguously says the answer given just before it is current.
The no-`-m` note ("Approved via approve.sh ... any note above is stale; proceed.") has no answer
and is not affected.

## Acceptance criteria

1. **Given** a `needs-human` issue, **when** the operator runs `approve.sh -m "<answer>" <id>`,
   **then** the issue's notes contain the operator's answer text followed by the exact sentence
   `Approved; any note above is stale; proceed using this answer.`
2. **Given** the same call, **when** the notes are read, **then** the answer and the approval
   sentence are on separate lines, the approval sentence being the line immediately after the answer,
   and the answer text is not altered or truncated.
3. **Given** an answer that itself ends in punctuation or contains a dash, **when** approved with
   `-m`, **then** the approval sentence still appears verbatim on its own line after it.
4. **Given** `approve.sh <id>` with no `-m`, **when** it runs, **then** behaviour is unchanged
   (label removed, issue reopened, generic approval note appended).
5. **Given** `-m` with an empty message or with multiple ids, **when** run, **then** it still exits
   non-zero with the existing errors.

## Out of scope
- Changing the no-message approval note wording.
- Changes to other scripts, agent prompts, or the README beyond what is needed to stay accurate.
