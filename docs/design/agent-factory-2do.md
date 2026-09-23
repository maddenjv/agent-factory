# agent-factory-2do: Expire recent alerts — design

## Approach

All the logic lives in `bin/board.sh` (the only reader of `alerts.log`'s display, and the only
place these acceptance criteria are observable). No change to `alert()`, `alerts.log`'s format,
or any other script.

Today `board.sh` is one flat `while :; do ... done` loop. Restructure it into named functions
plus a guarded main loop, so the filtering logic can be exercised directly (see Test strategy)
without running the infinite refresh loop:

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

still_needs_human() { ... }   # issue-id -> 0 (still labelled, not closed) / 1 (resolved)
recent_alerts()     { ... }   # reads alerts.log, writes the filtered tail to stdout

render() {
  clear
  echo "== $(date -u +%FT%TZ) =="
  ...                          # unchanged sections (in progress / ready / needs-human / spend)
  echo; echo "-- recent alerts --"
  recent_alerts
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  while :; do render; sleep 15; done
fi
```

`render` is just today's body with the last two lines (`tail -n 6 ...`) replaced by a call to
`recent_alerts`. Everything above `-- recent alerts --` is untouched.

## `recent_alerts`

Filtering happens **after** the existing `tail -n 6` (per AC2's "subject to the existing
tail-window limit") — it never looks further back than what's already shown today, it just drops
some of those 6 lines. `alerts.log` on disk is never rewritten.

```bash
recent_alerts() {
  local now line ts msg id wait_s alert_epoch
  now=$(date -u +%s)
  tail -n 6 "$DATA_DIR/control/alerts.log" 2>/dev/null | while IFS= read -r line; do
    if [[ ! $line =~ ^([0-9T:-]+Z)\ \[[^]]*\]\ (.*)$ ]]; then
      echo "$line"; continue   # doesn't match the alert() format - show it, don't guess
    fi
    ts="${BASH_REMATCH[1]}"; msg="${BASH_REMATCH[2]}"

    if [[ $msg =~ ^([A-Za-z0-9_.-]+)\ (flagged\ needs-human|not\ completed\ after\ [0-9]+\ attempts\;\ labelled\ needs-human) ]]; then
      id="${BASH_REMATCH[1]}"
      still_needs_human "$id" && echo "$line"
      continue
    fi

    if [[ $msg =~ usage\ limit\ hit.*waiting\ ([0-9]+)s ]]; then
      wait_s="${BASH_REMATCH[1]}"
      alert_epoch=$(date -d "$ts" +%s 2>/dev/null) || { echo "$line"; continue; }
      (( now < alert_epoch + wait_s )) && echo "$line"
      continue
    fi

    echo "$line"   # not a needs-human or usage-limit alert (AC5) - always shown
  done
}
```

`still_needs_human`:

```bash
still_needs_human() {  # exit 0 = still true (keep showing), 1 = resolved (drop)
  local id="$1" json status
  json=$(bd show "$id" --json 2>/dev/null | jq -c 'if type=="array" then .[0] else . end' 2>/dev/null)
  [ -n "$json" ] || return 0   # bd lookup failed/issue vanished - fail open, keep the alert
  status=$(echo "$json" | jq -r '.status // empty')
  [ "$status" = "closed" ] && return 1
  echo "$json" | jq -e '(.labels // []) | index("needs-human")' >/dev/null 2>&1
}
```

Notes:
- `still_needs_human` reuses the same `bd show --json` + `jq -c 'if type=="array" then .[0]
  else . end'` idiom `agent-loop.sh`'s `show_json`/`has_label` already use (bin/agent-loop.sh:44-45)
  for the same reason: `bd show` sometimes returns a bare object, sometimes a one-element array.
- Any failure mode (bd unreachable, id typo'd, issue deleted) makes the alert **keep showing**,
  never silently disappear — an operator seeing a stale alert is a minor annoyance; one that
  silently vanished because `bd` hiccuped is the exact regression this story exists to avoid on
  the other side.
- Usage-limit expiry uses `date -d` (GNU coreutils, present in the Debian-bookworm `agent` image
  per docs/ARCHITECTURE.md — board.sh only ever runs there, never on a host shell). If parsing
  ever fails, same fail-open rule: show the line.
- Regex extraction is against the exact strings `alert()` calls at bin/agent-loop.sh:181, 183,
  201 (needs-human family) and 254, 295 (usage-limit family) — see Story context. No other
  `alert()` call site matches either pattern, so they fall through to the final `echo "$line"`
  unchanged, satisfying AC5.

## Acceptance criteria mapping

1. Label removed from X → next `still_needs_human` call sees no `needs-human` label → line
   dropped on next refresh (board redraws every 15s).
2. Label still present → `still_needs_human` returns 0 → line kept, still bounded by `tail -n 6`.
3. `now >= alert_epoch + N` → line dropped.
4. `now < alert_epoch + N` → line kept.
5. Anything not matching either regex (circuit breaker, daily budget, git sync, clone, preflight
   `claude` failure) falls through to the unconditional `echo "$line"` — unchanged.

## Test strategy

No unit-test framework per docs/ARCHITECTURE.md; QA exercises the script directly, per its "bash
script changes" convention. Because `recent_alerts`/`still_needs_human` are now plain functions
guarded behind the `BASH_SOURCE == 0` check, QA can source the script without triggering the
infinite loop:

```bash
DATA_DIR=/tmp/board-test-$$ 
mkdir -p "$DATA_DIR/control"
source bin/board.sh   # defines functions, does NOT start the while loop (sourced, not executed)
```

Suggested cases (real `bd` issues in a scratch project, or a stub `bd`/`jq` on `PATH` ahead of
the real ones if QA prefers not to touch live Beads state):
- Append a needs-human line for an issue that still carries the label → appears in
  `recent_alerts` output.
- Same, after `bd close <id>` (or `bd label remove <id> needs-human` if available) → line is
  gone.
- Append a usage-limit line with an old timestamp + small `N` (already elapsed) → gone.
- Append a usage-limit line with `N` far in the future → still present.
- Append one of each unaffected alert type (circuit breaker / daily budget / git sync / clone /
  preflight) → always present, byte-for-byte unchanged.
- Malformed/unparseable line (hand-edited) → still present (fail-open).
- `alerts.log` missing or empty → `recent_alerts` prints nothing, doesn't error (matches today's
  `tail` behavior with `2>/dev/null`).
- `shellcheck bin/board.sh` clean, per repo convention.

## Out of scope (per story)
No changes to `alert()`, `alerts.log` format/rotation, `NOTIFY_URL`, or expiry for circuit
breaker / daily budget / git sync / clone / preflight alerts.
