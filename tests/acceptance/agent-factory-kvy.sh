#!/usr/bin/env bash
# Acceptance tests for agent-factory-kvy: "Approval note uses a fixed, unambiguous closing sentence".
# Criteria: docs/stories/agent-factory-kvy.md. A stub `bd` first on PATH records the raw argv of each call.
# Written BEFORE implementation: ac1-ac3 fail until bin/approve.sh puts the sentence on its own line.
# Run: bash tests/acceptance/agent-factory-kvy.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/bin/approve.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/raw"
cat > "$TMP/bin/bd" <<'STUB'
#!/usr/bin/env bash
{ printf '%q ' "$@"; echo; } >> "$BD_LOG"
printf '%s\0' "$@" > "$BD_RAW/call.$(date +%s%N).$$"
STUB
chmod +x "$TMP/bin/bd"
export BD_RAW="$TMP/raw" BD_LOG="$TMP/bd.log" PATH="$TMP/bin:$PATH"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
SENT='Approved; any note above is stale; proceed using this answer.'

RC=0; ERR=""; NOTE=""
run() { : > "$BD_LOG"; rm -f "$BD_RAW"/call.*; ERR="$(bash "$SCRIPT" "$@" 2>&1 >/dev/null)"; RC=$?; NOTE="$(note_arg)"; }
# The value following --append-notes in the raw argv (empty if none).
note_arg() {
  local f args i
  for f in "$BD_RAW"/call.*; do
    [ -e "$f" ] || continue
    mapfile -d '' -t args < "$f"
    for i in "${!args[@]}"; do
      [ "${args[$i]}" = --append-notes ] && { printf '%s' "${args[$((i+1))]}"; return; }
    done
  done
}
# check_lines <answer>: NOTE has answer verbatim ending a line, and the very next line is exactly SENT.
check_lines() {
  local ans="$1" lines i alines
  mapfile -t lines <<<"$NOTE"
  mapfile -t alines <<<"$ans"
  local n=${#alines[@]}
  for i in "${!lines[@]}"; do
    # answer occupies lines i .. i+n-1; last answer line must end with the answer's last line
    local j ok=1
    for ((j=0; j<n; j++)); do
      if [ $j -eq 0 ] && [ $n -eq 1 ]; then
        case "${lines[$i]}" in *"${alines[0]}") ;; *) ok=0 ;; esac
      elif [ $j -eq 0 ]; then
        case "${lines[$i]}" in *"${alines[0]}") ;; *) ok=0 ;; esac
      elif [ $j -eq $((n-1)) ]; then
        [ "${lines[$((i+j))]:-}" = "${alines[$j]}" ] || ok=0
      else
        [ "${lines[$((i+j))]:-}" = "${alines[$j]}" ] || ok=0
      fi
    done
    if [ $ok = 1 ] && [ "${lines[$((i+n))]:-}" = "$SENT" ]; then return 0; fi
  done
  return 1
}

test_ac1_answer_followed_by_exact_sentence() {
  run agent-x -m "use option B"
  if [ $RC -eq 0 ] && [[ "$NOTE" == *"use option B"* ]] && [[ "$NOTE" == *$'\n'"$SENT" || "$NOTE" == *$'\n'"$SENT"$'\n' ]]; then
    pass "ac1 note has answer then exact sentence"
  else fail "ac1 (rc=$RC) note: $NOTE"; fi
}

test_ac2_sentence_on_own_line_right_after_answer() {
  run agent-x -m "use option B"
  if check_lines "use option B"; then pass "ac2 sentence is its own line, immediately after answer"
  else fail "ac2 note: $NOTE"; fi
  if ! grep -Fq -- "- $SENT" <<<"$NOTE" && ! grep -Fq -- "use option B - Approved" <<<"$NOTE"; then
    pass "ac2 sentence not glued to answer with a dash"
  else fail "ac2 glued: $NOTE"; fi
  local m=$'first line\nsecond line with $HOME `id` "q"'
  run agent-x -m "$m"
  if check_lines "$m"; then pass "ac2 multi-line/special answer unaltered, sentence on next line"
  else fail "ac2 multiline note: $NOTE"; fi
  local long; long="$(printf 'word%.0s ' $(seq 1 400))end"
  run agent-x -m "$long"
  if [[ "$NOTE" == *"$long"* ]] && check_lines "$long"; then pass "ac2 long answer not truncated"
  else fail "ac2 long answer truncated/altered"; fi
}

test_ac3_punctuation_and_dashes() {
  local m
  for m in "Yes." "do it!" "why?" "use A - not B" "trailing dash -" "a -- b." "ends with sentence: $SENT"; do
    run agent-x -m "$m"
    if [ $RC -eq 0 ] && check_lines "$m"; then pass "ac3 '$m'"
    else fail "ac3 '$m' (rc=$RC) note: $NOTE"; fi
  done
}

test_ac4_no_message_unchanged() {
  run agent-a
  local log; log="$(cat "$BD_LOG")"
  if [ $RC -eq 0 ] && grep -Fq "label remove agent-a needs-human" <<<"$log" \
     && grep -Fq "update agent-a --status open" <<<"$log" \
     && [[ "$NOTE" == "Approved via approve.sh by "* ]] \
     && [[ "$NOTE" == *" - any note above is stale; proceed." ]] \
     && [[ "$NOTE" != *$'\n'* ]] && [[ "$NOTE" != *"Human answer"* ]] && [[ "$NOTE" != *"$SENT"* ]]; then
    pass "ac4 no -m: released, generic single-line note unchanged"
  else fail "ac4 (rc=$RC) note: $NOTE log: $log"; fi
}

test_ac5_errors_unchanged() {
  run agent-x -m ""
  if [ $RC -ne 0 ] && [ ! -s "$BD_LOG" ] && [[ "$ERR" == *"message must not be empty"* ]]; then pass "ac5 empty message rejected"
  else fail "ac5 empty (rc=$RC) err: $ERR"; fi
  run agent-x -m "  "
  if [ $RC -ne 0 ] && [ ! -s "$BD_LOG" ] && [[ "$ERR" == *"message must not be empty"* ]]; then pass "ac5 whitespace message rejected"
  else fail "ac5 whitespace (rc=$RC) err: $ERR"; fi
  run -m "x" agent-a agent-b
  if [ $RC -ne 0 ] && [ ! -s "$BD_LOG" ] && [[ "$ERR" == *"a message can only be attached to a single issue"* ]]; then pass "ac5 multiple ids rejected"
  else fail "ac5 multi (rc=$RC) err: $ERR"; fi
}

test_ac1_answer_followed_by_exact_sentence
test_ac2_sentence_on_own_line_right_after_answer
test_ac3_punctuation_and_dashes
test_ac4_no_message_unchanged
test_ac5_errors_unchanged
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
