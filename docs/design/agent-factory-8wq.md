# Design: exclude needs-human-stalled stories from the WIP limit (agent-factory-8wq)

## Approach
Only `in_flight()` in `bin/agent-loop.sh` changes (plus docs). `wip_ok()` and the `WIP_LIMIT`
comparison stay as they are, so AC5 (limit unchanged) holds by construction.

A story is identified by its `story:<id>` label. Today `in_flight()` counts open issues labelled
`role:reviewer` (one per story). New rule: count such an issue only if its story is **not stalled**.

A story is **stalled** iff, among all its non-closed issues (any issue carrying the same `story:<id>`
label), at least one is either
1. labelled `needs-human`, or
2. has a `blocks`-type dependency (`.dependencies[] | select(.type=="blocks") | .depends_on_id`) on
   a non-closed issue labelled `needs-human` (same test `bin/board.sh` `blocked_section` uses).

Rationale: the chain is strictly sequential, so once one issue is `needs-human` every later issue
waits behind it and nothing can progress (AC1, AC2). Rule 2 also catches a dependency onto a
`needs-human` issue of another story. Plain dependency waiting (review blocked by implement, none
`needs-human`) matches neither rule, so the story still counts (AC3). Nothing is stored: the count
is recomputed from labels on each call, so removing `needs-human` (e.g. `approve.sh`) makes the
story count again on the next check (AC4).

## Implementation (`bin/agent-loop.sh`, replace `in_flight`)
Keep the comment/one-jq-call shape and the `2>/dev/null` tolerance (`wip_ok`'s `[ ... ] 2>/dev/null`
treats empty output as "not ok"-safe, as today):

```bash
in_flight() {  # stories whose review issue is not yet closed, minus those stalled on a needs-human issue
  bd list --json 2>/dev/null | jq '
    [ .[]? | select(.status != "closed") ] as $open
    | ($open | map({key: .id, value: ((.labels // []) | index("needs-human") != null)}) | from_entries) as $nh
    | ( [ $open[]
          | select(($nh[.id]) or ([ (.dependencies // [])[] | select(.type == "blocks") | $nh[.depends_on_id] ] | any))
          | (.labels // [])[] | select(startswith("story:")) ] | unique ) as $stalled
    | [ $open[]
        | select((.labels // []) | index("role:reviewer"))
        | select(([ (.labels // [])[] | select(startswith("story:")) ] | any(. as $s | $stalled | index($s))) | not)
      ] | length' 2>/dev/null
}
```
Notes: `$nh[...]` is `null` (falsy) for closed/unknown ids, which is what we want. A reviewer issue
with no `story:` label is never stalled (counted, as today). The engineer may restructure the jq
for clarity but must keep the semantics above and run `shellcheck`.

## Docs (AC6)
- `.env.example` line 21: `WIP_LIMIT=2  # PO won't start a new story while this many are in flight (stories stalled on needs-human don't count)`
- `README.md`: where `WIP_LIMIT`/"WIP limit on the PO" is described (Guardrails, ~line 107) add: stories
  stalled on a `needs-human` issue (or waiting behind one) are not counted toward it. If README has
  no `WIP_LIMIT` config entry, add that sentence there; the string `WIP_LIMIT` and `needs-human`
  must both appear in the sentence.

## Error cases
`bd list` failure -> empty output -> `[ "" -lt N ] 2>/dev/null` fails -> `wip_ok` false, PO waits
(same as today). No new failure modes.

## Test strategy (QA)
No framework (see ARCHITECTURE.md). Test `in_flight` by sourcing/extracting the function with a stub
`bd` on `PATH` that prints canned `bd list --json` fixtures; assert printed count and `wip_ok`
exit status with `ROLE=po WIP_LIMIT=2`:
1. AC1: two stories, one with an open `needs-human` issue -> `1`; `wip_ok` true.
2. AC2: story whose open review issue depends (`type:"blocks"`) on a `needs-human` issue -> not counted.
3. AC3: story with review blocked only by an open implement issue (no `needs-human`) -> counted.
4. AC4: same fixture as AC1 with the label removed -> `2`; `wip_ok` false.
5. AC5: two healthy stories plus a stalled third -> `2`; `wip_ok` false.
6. AC6: `grep` `.env.example` and `README.md` for a `WIP_LIMIT`/`needs-human` mention.
7. Closed `needs-human` issue does not stall; `bash -n` and `shellcheck bin/agent-loop.sh` clean.
