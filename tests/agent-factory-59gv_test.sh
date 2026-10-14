#!/usr/bin/env bash
# Acceptance tests for agent-factory-59gv: "Lint tests for hard-coded dates".
# One function per acceptance criterion in docs/stories/agent-factory-59gv.md (test_acN_...).
# Written from the story only. Date literals here are built from parts so this file itself
# stays clean under the check it tests.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/bin/check-tests.sh"
FAILS=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }
D1="2026""-09-23"
D2="2025""-01-02"
D3="2031""-12-31"
SCRATCH=$(mktemp -d); trap 'rm -rf "$SCRATCH"' EXIT

mk() { rm -rf "$SCRATCH/t"; mkdir -p "$SCRATCH/t"; }
run() { OUT=$(cd "$ROOT" && bash "$CHECK" "$@" 2>&1); RC=$?; }

test_ac1_flags_unmarked_date() {
  mk
  printf '#!/usr/bin/env bash\necho ok\nX=%s\n' "$D1" > "$SCRATCH/t/a_test.sh"
  run "$SCRATCH/t"
  [ "$RC" -ne 0 ] || { fail "ac1 exit non-zero"; return; }
  grep -q "a_test.sh:3" <<<"$OUT" && pass "ac1 reports path:line" || fail "ac1 path:line missing: $OUT"
}
test_ac1_flags_datetime() {
  mk
  printf 'X=%sT10:20:30\n' "$D2" > "$SCRATCH/t/b_test.sh"
  run "$SCRATCH/t"
  [ "$RC" -ne 0 ] && grep -q "b_test.sh:1" <<<"$OUT" && pass "ac1 datetime flagged" || fail "ac1 datetime: rc=$RC $OUT"
}
test_ac2_marker_suppresses() {
  mk
  printf 'X=%s # fixed-date-ok\n' "$D1" > "$SCRATCH/t/c_test.sh"
  run "$SCRATCH/t"
  [ "$RC" -eq 0 ] && ! grep -q "c_test.sh" <<<"$OUT" && pass "ac2 marked line ignored" || fail "ac2: rc=$RC $OUT"
}
test_ac2_marker_only_on_its_line() {
  mk
  printf 'X=%s # fixed-date-ok\nY=%s\n' "$D1" "$D2" > "$SCRATCH/t/d_test.sh"
  run "$SCRATCH/t"
  [ "$RC" -ne 0 ] && grep -q "d_test.sh:2" <<<"$OUT" && ! grep -q "d_test.sh:1\b" <<<"$OUT" \
    && pass "ac2 only unmarked line reported" || fail "ac2 mixed: rc=$RC $OUT"
}
test_ac3_clean_tree_exits_zero() {
  mk
  printf 'echo hi\nX=$(date +%%F)\n' > "$SCRATCH/t/e_test.sh"
  run "$SCRATCH/t"
  [ "$RC" -eq 0 ] && pass "ac3 clean exits 0" || fail "ac3: rc=$RC $OUT"
  [ "$RC" -eq 0 ] && ! grep -q "e_test.sh" <<<"$OUT" && pass "ac3 nothing reported" || fail "ac3 reported: $OUT"
}
test_ac4_reports_all() {
  mk; mkdir -p "$SCRATCH/t/acceptance"
  printf 'A=%s\nok\nB=%s\n' "$D1" "$D2" > "$SCRATCH/t/f_test.sh"
  printf 'C=%s\n' "$D3" > "$SCRATCH/t/acceptance/g.sh"
  run "$SCRATCH/t"
  [ "$RC" -ne 0 ] && grep -q "f_test.sh:1" <<<"$OUT" && grep -q "f_test.sh:3" <<<"$OUT" \
    && grep -q "acceptance/g.sh:1" <<<"$OUT" && pass "ac4 all path:line reported (recursive)" || fail "ac4: rc=$RC $OUT"
}
test_ac5_real_tests_clean() {
  [ -f "$CHECK" ] || { fail "ac5 bin/check-tests.sh missing"; return; }
  run
  [ "$RC" -eq 0 ] && pass "ac5 real tests/ passes" || fail "ac5: rc=$RC $OUT"
}
test_ac6_dir_argument() {
  mk; mkdir -p "$SCRATCH/t2"
  printf 'X=%s\n' "$D1" > "$SCRATCH/t/h_test.sh"
  printf 'echo clean\n' > "$SCRATCH/t2/i_test.sh"
  run "$SCRATCH/t2"; local rc2=$RC
  run "$SCRATCH/t"
  [ "$rc2" -eq 0 ] && [ "$RC" -ne 0 ] && grep -q "h_test.sh:1" <<<"$OUT" \
    && pass "ac6 scans given dir" || fail "ac6: rc2=$rc2 rc=$RC $OUT"
}
test_ac7_architecture_docs() {
  local f="$ROOT/docs/ARCHITECTURE.md"
  grep -q 'bin/check-tests.sh' "$f" && grep -q 'fixed-date-ok' "$f" \
    && pass "ac7 ARCHITECTURE documents check + marker" || fail "ac7 ARCHITECTURE.md lacks bin/check-tests.sh / fixed-date-ok"
}

if [ ! -f "$CHECK" ]; then echo "NOTE: $CHECK not implemented yet"; fi
for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
[ "$FAILS" -eq 0 ]
