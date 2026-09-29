# agent-factory-r7m5: Set priorities on issues created via feature.sh

## Story
As the human operator filing work with `bin/feature.sh`, I want to set the priority of the issue
it creates, so that urgent or low-value feature requests are triaged correctly instead of always
landing at the default priority.

## Context
`bin/feature.sh` (see README "Setup" step 1) is the intake path a human uses to file a feature
request for the `po` role: `feature.sh "Title" ["description"]`. It always calls
`bd create ... -p 2 ...` - there is currently no way to ask for a different priority without
running `bd create`/`bd update` by hand afterward. Beads priorities are `0`-`4` (or `P0`-`P4`),
`0` = critical, `4` = backlog; `2` is the existing default and stays the default here. Other
`bin/*.sh` scripts that take optional modifiers use trailing `--flag` arguments after the
required positional ones (e.g. `new-story.sh <story-id> "<title>" [--skip-design]
[--skip-tests]`), which this script should follow for consistency.

## Acceptance criteria

1. Given a call to `feature.sh` with a title and no priority, when the issue is created, then
   its priority is `2` (unchanged from today's default).
2. Given a call to `feature.sh` with a title and a valid priority (any of Beads' accepted forms,
   e.g. `0`-`4`), when the issue is created, then its priority matches the one supplied.
3. Given a call to `feature.sh` with a title, a description, and a valid priority, when the issue
   is created, then both the description and the priority are set as supplied (supplying a
   priority does not require omitting or reordering the description).
4. Given a call to `feature.sh` with an invalid priority (not one of Beads' accepted values),
   when the script runs, then it exits non-zero with an error message identifying the invalid
   value, and no issue is created.
5. Given a call to `feature.sh` with no arguments or a missing title, when the script runs, then
   it prints usage output including how to pass a priority, and exits non-zero (existing
   no-title behavior, extended to document the new argument).

## Out of scope
- Changing the default priority itself (stays `2`).
- Adding priority support to any script other than `feature.sh`.
- Changing how `po` or any other role sets priority on issues it creates directly via `bd create`.
