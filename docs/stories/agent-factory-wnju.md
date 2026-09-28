# agent-factory-wnju: New issues go to team-lead first, not straight to po

## Story
As the agent-factory system, I want issues created by `bin/feature.sh` to enter through
team-lead's triage instead of being labelled `role:po` directly, so that team-lead's existing
diagnosis (is this a stray follow-up for an existing story chain, or a genuinely new request?)
applies to every new issue, not just the ones that happen to reach the board some other way.

## Context
`bin/feature.sh` is the normal user-facing intake command (README "Flow" step 1). Today it
creates every new issue with `-l role:po`, sending it straight into po's queue with no triage at
all - po must always guess whether a request is actually new or secretly belongs to work already
in flight.

Team-lead already has a "Sweep: issues with no `role:*` label" path
(`agents/team-lead.md`, built in `agent-factory-m7af`) that does exactly this diagnosis for
issues that reach the board *outside* `feature.sh`: it checks whether the issue carries a
`story:<id>` label (a stray follow-up that lost its routing labels and belongs to an existing
chain), reroutes it via the same diagnose process used for `needs-team-lead` issues if so,
escalates to `needs-human` if it can't tell, and otherwise defaults to `role:po` for what reads
as a genuinely new, unfiled request. `agent-factory-m7af` deliberately excluded `feature.sh`
issues from this sweep ("Changing what label `feature.sh` ... applies" was explicit out of
scope there) because nothing was broken yet - `feature.sh` was the *only* reliable intake path.

This story reverses that boundary: `feature.sh`-created issues become team-lead's job too, so
every new issue - however it reached the board - gets the same diagnosis before po ever sees it.
It does not add new triage logic; it removes the special case that let `feature.sh` skip the
diagnosis team-lead already performs for everything else.

## Acceptance criteria

1. **Given** a user runs `bin/feature.sh` to file a new issue, **when** the issue is created,
   **then** it does not carry a `role:po` label, or any other `role:*` label.

2. **Given** team-lead polls for work, **when** it finds an open issue with no `role:*` label
   that isn't `needs-human` or `needs-team-lead`, **then** a `feature.sh`-created issue is picked
   up exactly like any other such issue - there is no remaining special case, in behavior or in
   docs (`agents/team-lead.md`), that treats `feature.sh` issues as already triaged or otherwise
   exempt from this sweep.

3. **Given** team-lead diagnoses a `feature.sh`-created issue that carries no `story:<id>` label
   (the common case - a new, unfiled request), **when** it finishes triaging, **then** it labels
   the issue `role:po` and leaves a `bd comment` stating it routed a new request there - the same
   outcome and reasoning the sweep already produces today, now reached uniformly for every new
   issue instead of only for ones that bypassed `feature.sh`.

4. **Given** team-lead diagnoses a `feature.sh`-created issue that does carry a `story:<id>`
   label (a stray follow-up meant for an existing chain, not a brand-new request), **when** it
   investigates, **then** it applies the same diagnose-and-reroute process it already uses for
   stray issues (issue history, the story doc, sibling issues in the chain), rather than
   defaulting to `role:po`.

5. **Given** this change has landed, **when** README.md's "Flow" step 1 and
   `docs/ARCHITECTURE.md`'s description of team-lead's sweep are read afterward, **then** they
   describe `feature.sh`-created issues going to team-lead first (not directly to `role:po`),
   matching actual behavior - including `agent-factory-m7af`'s "outside the normal `feature.sh`
   intake path" framing, which this story makes obsolete.

## Out of scope
- Any change to what po does once an issue reaches it labelled `role:po` (`agents/po.md`
  unchanged).
- Adding new triage outcomes or routing destinations beyond what team-lead's existing diagnose
  logic already supports (`agent-factory-m7af`) - this story unifies intake onto that logic, it
  does not extend the logic itself.
- Any change to `feature.sh`'s other issue fields (title, type, priority, description) beyond
  removing the `role:po` label.
- Issues created by hand with a `role:*` label already on them, or already `needs-human`/
  `needs-team-lead` - unaffected, as today.
