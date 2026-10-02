#!/usr/bin/env bash
# Acceptance tests for agent-factory-qkh4 (init.sh checks its dependencies up front).
# One test function per acceptance criterion in docs/stories/agent-factory-qkh4.md. Plain shell
# acceptance script (docs/ARCHITECTURE.md "Test strategy"):  bash tests/acceptance/agent-factory-qkh4.sh
# Needs no real docker: each test runs a scratch copy of the kit against a scratch git project
# with a restricted PATH holding stub `docker` binaries (absent / compose-less / fully working).
# Written before implementation: AC1-AC3, AC5 are expected to FAIL until init.sh grows the check.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$KIT_DIR"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

cleanup_dirs=()
trap 'for d in "${cleanup_dirs[@]}"; do rm -rf "$d"; done' EXIT
mktmp() { local d; d=$(mktemp -d); cleanup_dirs+=("$d"); echo "$d"; }

make_tmpkit() { local d; d=$(mktmp); git -C "$KIT_DIR" archive HEAD | tar -x -C "$d"; echo "$d"; }
make_tmpproject() {
  local d; d=$(mktmp)
  git -C "$d" init -q -b main
  git -C "$d" -c user.email=t@t.example -c user.name=t commit -q --allow-empty -m init
  echo "$d"
}

# Restricted PATH dir: symlinks to the ordinary tools init.sh needs, but never docker.
# $1 = stub mode: none | nocompose | full
make_path() {
  local mode=$1 d t p; d=$(mktmp)
  for t in bash sh env git dirname basename chmod mkdir cp mv rm cat grep sed awk id seq sleep \
           tr sort head tail wc date readlink realpath uname touch ls find diff cut tee xargs \
           mktemp printf true false test expr; do
    p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -sf "$p" "$d/$t"
  done
  case "$mode" in
    nocompose)
      cat > "$d/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "${STUB_LOG:-/dev/null}"
case "${1:-}" in
  compose) echo "unknown shorthand flag: 'f' in -f" >&2; echo "See 'docker --help'." >&2; exit 125 ;;
  --version|version) echo "Docker version 99.0.0"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
      ;;
    full)
      cat > "$d/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "${STUB_LOG:-/dev/null}"
case "${1:-}" in
  --version|version) echo "Docker version 99.0.0" ;;
  compose) case " $* " in *" version "*) echo "Docker Compose version v99.0.0" ;; esac ;;
esac
exit 0
STUB
      ;;
  esac
  [ -f "$d/docker" ] && chmod +x "$d/docker"
  echo "$d"
}

snapshot() { ( cd "$1" && find . -path ./.git -prune -o -print | sort ); }

# run_init <mode> <kit> <project> [args...]: sets OUT and RC
run_init() {
  local mode=$1 kit=$2 proj=$3; shift 3
  local pathdir; pathdir=$(make_path "$mode")
  STUBLOG="$(mktmp)/stub.log"
  OUT=$(cd "$proj" && PROJECT_DIR="$proj" STUB_LOG="$STUBLOG" PATH="$pathdir" bash "$kit/bin/init.sh" "$@" 2>&1)
  RC=$?
}

mentions_dash_f() { grep -Eq '(^|[[:space:]`"'"'"'(])-f([[:space:]`"'"'"',.:;)]|$)' <<<"$1"; }

missing_dep_case() {  # missing_dep_case <mode> <must-name-regex> <label>
  local mode=$1 name=$2 label=$3 kit proj
  kit=$(make_tmpkit); proj=$(make_tmpproject)
  run_init "$mode" "$kit" "$proj"
  if [ "$RC" -eq 0 ]; then bad "$label: exited 0, expected non-zero"; return; fi
  if ! grep -Eiq "$name" <<<"$OUT"; then bad "$label: message does not name the missing dependency ($name). Output: $OUT"; return; fi
  if grep -q "command not found" <<<"$OUT"; then bad "$label: raw shell error, not a clear message. Output: $OUT"; return; fi
  if mentions_dash_f "$OUT"; then bad "$label: message mentions the -f flag. Output: $OUT"; return; fi
  ok "$label"
}

test_ac1_no_docker_names_docker() {
  missing_dep_case none 'docker' "AC1 no docker: non-zero exit, names Docker, no -f"
}

test_ac2_no_compose_names_compose() {
  missing_dep_case nocompose 'compose' "AC2 docker without compose plugin: non-zero exit, names Compose, no -f"
}

test_ac3_nothing_created_when_dep_missing() {
  local mode kit proj before after_kit extra
  for mode in none nocompose; do
    for extra in "" "--harness=copilot"; do
      kit=$(make_tmpkit); proj=$(make_tmpproject)
      before=$(snapshot "$proj"); after_kit=$(snapshot "$kit")
      # shellcheck disable=SC2086
      run_init "$mode" "$kit" "$proj" $extra
      if [ "$RC" -eq 0 ]; then bad "AC3 [$mode $extra]: init unexpectedly succeeded"; continue; fi
      if [ -e "$proj/.agent-factory" ]; then bad "AC3 [$mode $extra]: .agent-factory/ was created"; continue; fi
      if [ -e "$proj/.env" ] || [ -e "$kit/.env" ]; then bad "AC3 [$mode $extra]: a .env was created"; continue; fi
      if [ "$before" != "$(snapshot "$proj")" ]; then bad "AC3 [$mode $extra]: project files changed"; continue; fi
      if [ "$after_kit" != "$(snapshot "$kit")" ]; then bad "AC3 [$mode $extra]: kit files changed"; continue; fi
      if [ -n "$(git -C "$proj" status --porcelain)" ]; then bad "AC3 [$mode $extra]: git status not clean"; continue; fi
      if [ -s "${STUBLOG:-/nonexistent}" ] && grep -q 'compose.*\(build\|up\|run\)' "$STUBLOG"; then
        bad "AC3 [$mode $extra]: init went on to run docker compose build/up/run"; continue
      fi
      ok "AC3 [$mode ${extra:-no flags}]: nothing created or changed"
    done
  done
}

test_ac4_both_available_unchanged() {
  local kit proj
  kit=$(make_tmpkit); proj=$(make_tmpproject)
  run_init full "$kit" "$proj"
  if [ "$RC" -ne 0 ]; then bad "AC4: init failed with docker+compose present (rc=$RC). Output: $OUT"; return; fi
  [ -f "$proj/.agent-factory/.env" ] || { bad "AC4: .agent-factory/.env not created"; return; }
  grep -q '^HARNESS=claude-code' "$proj/.agent-factory/.env" || { bad "AC4: HARNESS not recorded"; return; }
  grep -q 'compose.* build' "$STUBLOG" 2>/dev/null || { bad "AC4: docker compose build was not invoked"; return; }
  grep -q 'init-project.sh' "$STUBLOG" 2>/dev/null || { bad "AC4: init-project.sh step not run"; return; }
  grep -qi 'missing\|not installed' <<<"$OUT" && { bad "AC4: spurious missing-dependency message: $OUT"; return; }
  [ -d "$proj/.agent-factory/workspaces/qa" ] || { bad "AC4: workspaces not created"; return; }
  ok "AC4 docker + compose present: setup proceeds as before"
}

test_ac4_bad_harness_still_validated_first() {
  local kit proj
  kit=$(make_tmpkit); proj=$(make_tmpproject)
  run_init full "$kit" "$proj" --harness=bogus
  if [ "$RC" -ne 0 ] && grep -q "harness" <<<"$OUT" && [ ! -e "$proj/.agent-factory" ]; then
    ok "AC4 existing --harness validation unchanged"
  else bad "AC4: --harness=bogus behaviour changed (rc=$RC): $OUT"; fi
}

test_ac5_readme_lists_prerequisite() {
  if grep -iE 'docker' README.md | grep -iE 'compose' | grep -iEq 'prerequisite|require|plugin|need|install'; then
    ok "AC5 README lists Docker with the Compose plugin as a prerequisite"
  else
    bad "AC5: README has no line listing Docker + Compose plugin as a prerequisite"
  fi
}

test_ac1_no_docker_names_docker
test_ac2_no_compose_names_compose
test_ac3_nothing_created_when_dep_missing
test_ac4_both_available_unchanged
test_ac4_bad_harness_still_validated_first
test_ac5_readme_lists_prerequisite

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
