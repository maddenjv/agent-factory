#!/usr/bin/env bash
# Acceptance tests for agent-factory-f6g: "Pass an answer/feedback through approve.sh".
# Criteria: docs/stories/agent-factory-f6g.md; interface: docs/design/agent-factory-f6g.md.
# A stub `bd` first on PATH logs each call (argv, %q-quoted, one line per call); no real Dolt needed.
# Written BEFORE implementation: -m tests fail until bin/approve.sh supports it.
# Run: bash tests/acceptance/agent-factory-f6g.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/bin/approve.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/bd" <<'STUB'
#!/usr/bin/env bash
{ printf '%q ' "$@"; echo; } >> "$BD_LOG"
printf '%s\0' "$@" > "$BD_RAW/call.$(date +%s%N).$$"
STUB
chmod +x "$TMP/bin/bd"
mkdir -p "$TMP/raw"
export BD_RAW="$TMP/raw" BD_LOG="$TMP/bd.log" PATH="$TMP/bin:$PATH"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

RC=0; ERR=""
run() { : > "$BD_LOG"; rm -f "$BD_RAW"/call.*; ERR="$(bash "$SCRIPT" "$@" 2>&1 >/dev/null)"; RC=$?; }
log() { cat "$BD_LOG"; }
# Note text from raw argv (quoting-agnostic: notes may be multi-line, which %q renders as $'..').
notes_for() {
  local f args i
  for f in "$BD_RAW"/call.*; do
    [ -e "$f" ] || continue
    mapfile -d '' -t args < "$f"
    [ "${args[0]:-}" = update ] && [ "${args[1]:-}" = "$1" ] || continue
    for i in "${!args[@]}"; do
      [ "${args[$i]}" = --append-notes ] && printf '%s\n' "${args[$((i + 1))]:-}"
    done
  done
  return 0
}
count_notes() { grep -c -- '--append-notes' "$BD_LOG"; }
GENERIC='Approved via approve.sh by'

check_released() { # id: label removed, reopened
  log | grep -Fq "label remove $1 needs-human" && log | grep -Fq "update $1 --status open"
}

test_ac1_message_removes_label_reopens_and_records_message() {
  run agent-x -m "use option B"
  if [ $RC -eq 0 ] && check_released agent-x && [ "$(count_notes)" = 1 ] \
     && notes_for agent-x | grep -Fq 'use option B'; then
    pass "ac1 -m: label removed, reopened, one note containing message"
  else fail "ac1 -m (rc=$RC) log: $(log)"; fi
  run -m "use option B" agent-x
  if [ $RC -eq 0 ] && check_released agent-x && notes_for agent-x | grep -Fq 'use option B'; then
    pass "ac1 -m accepted before id"
  else fail "ac1 -m before id (rc=$RC) $ERR"; fi
  run agent-x --message "long form"
  if [ $RC -eq 0 ] && notes_for agent-x | grep -Fq 'long form'; then
    pass "ac1 --message long form"
  else fail "ac1 --message (rc=$RC) $ERR"; fi
}

test_ac1_message_verbatim_single_argv() {
  local m=$'it\'s "q" $HOME `id` $(id)\nline2'
  run agent-x -m "$m"
  # raw (unquoted) argv: the note must be a single argument containing the message verbatim
  local f a found=0 args
  for f in "$BD_RAW"/call.*; do
    mapfile -d '' -t args < "$f"
    [ "${args[0]:-}" = update ] || continue
    for a in "${args[@]}"; do
      case "$a" in *"$m"*) found=1 ;; esac
    done
  done
  if [ $RC -eq 0 ] && [ "$(count_notes)" = 1 ] && [ $found = 1 ]; then
    pass "ac1 special chars recorded verbatim as one argument"
  else fail "ac1 verbatim (rc=$RC) log: $(log)"; fi
}

test_ac2_answer_distinguishable_from_generic() {
  run agent-x -m "use option B"
  if notes_for agent-x | grep -Fq 'Human answer' && ! notes_for agent-x | grep -Fq "$GENERIC"; then
    pass "ac2 note marked 'Human answer', not the generic text"
  else fail "ac2 note: $(notes_for agent-x)"; fi
}

test_ac3_no_message_unchanged() {
  run agent-a
  if [ $RC -eq 0 ] && check_released agent-a && notes_for agent-a | grep -Fq 'Approved via approve.sh' \
     && ! log | grep -Fq 'Human'; then pass "ac3 single id, generic note only"
  else fail "ac3 single (rc=$RC) log: $(log)"; fi
  run agent-a agent-b agent-c
  local ok=1 i
  [ $RC -eq 0 ] || ok=0
  for i in agent-a agent-b agent-c; do
    check_released "$i" && notes_for "$i" | grep -Fq 'Approved via approve.sh' \
      && notes_for "$i" | grep -Fq 'proceed' || ok=0
  done
  log | grep -Fq 'Human' && ok=0
  [ "$(count_notes)" = 3 ] || ok=0
  [ $ok = 1 ] && pass "ac3 multiple ids each released with generic note" || fail "ac3 multi (rc=$RC) log: $(log)"
}

test_ac4_message_with_multiple_ids_rejected() {
  local args
  for args in "A B -m x" "-m x A B" "A -m x B"; do
    # shellcheck disable=SC2086
    run $args
    if [ $RC -ne 0 ] && [ ! -s "$BD_LOG" ] && grep -qi 'single' <<<"$ERR"; then
      pass "ac4 '$args' rejected, no changes, error mentions single issue"
    else fail "ac4 '$args' (rc=$RC) err: $ERR log: $(log)"; fi
  done
}

test_ac5_empty_or_missing_message_rejected() {
  run agent-x -m ""
  if [ $RC -ne 0 ] && [ ! -s "$BD_LOG" ] && [ -n "$ERR" ]; then pass "ac5 empty message rejected"
  else fail "ac5 empty (rc=$RC) err: $ERR log: $(log)"; fi
  run agent-x -m "   "
  if [ $RC -ne 0 ] && [ ! -s "$BD_LOG" ]; then pass "ac5 whitespace-only message rejected"
  else fail "ac5 whitespace (rc=$RC) log: $(log)"; fi
  run agent-x -m
  if [ $RC -ne 0 ] && [ ! -s "$BD_LOG" ]; then pass "ac5 -m with no argument rejected"
  else fail "ac5 missing arg (rc=$RC) log: $(log)"; fi
  run -m "answer"
  if [ $RC -ne 0 ] && [ ! -s "$BD_LOG" ]; then pass "ac5 -m with no id rejected"
  else fail "ac5 no id (rc=$RC) log: $(log)"; fi
}

test_shellcheck_clean() {
  if ! command -v shellcheck >/dev/null; then echo "SKIP: shellcheck not installed"; return; fi
  if shellcheck "$SCRIPT"; then pass "shellcheck bin/approve.sh clean"; else fail "shellcheck"; fi
}

test_ac1_message_removes_label_reopens_and_records_message
test_ac1_message_verbatim_single_argv
test_ac2_answer_distinguishable_from_generic
test_ac3_no_message_unchanged
test_ac4_message_with_multiple_ids_rejected
test_ac5_empty_or_missing_message_rejected
test_shellcheck_clean
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
