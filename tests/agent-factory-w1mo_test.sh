#!/usr/bin/env bash
# Acceptance tests for agent-factory-w1mo: factory-s1-llama starts with -c 8192 -b 4096 -ub 4096,
# and an existing container lacking those flags is recreated. Derived ONLY from
# docs/stories/agent-factory-w1mo.md (test_acN_...). Docker is a stub that honours
# `inspect -f '{{.State.Running}}'` and `inspect -f '{{join .Args " "}}'`; init.sh runs for real.
# Run directly: bash tests/agent-factory-w1mo_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
MODEL="ggml-org/vllm-d3-mini-GGUF"
FLAGS="-c 8192 -b 4096 -ub 4096"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs" "$TMP/home"

cat > "$TMP/stubs/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_LOG:-/dev/null}"
S="$DSTATE"   # files: exists, running (true|false), args
case "$1" in
  inspect)
    [ -f "$S/exists" ] || { echo "Error: No such object" >&2; exit 1; }
    case "$*" in
      *Running*) cat "$S/running" ;;
      *Args*) cat "$S/args" ;;
      *) echo "{}" ;;
    esac; exit 0 ;;
  run)
    [ -f "$S/exists" ] && { echo "Conflict. name in use" >&2; exit 125; }
    img=""; i=0; for a in "$@"; do i=$((i+1)); case "$a" in *llama.cpp:server-cuda) shift $i; break;; esac; done
    touch "$S/exists"; echo true > "$S/running"; echo "$*" > "$S/args"; echo abc123; exit 0 ;;
  rm) rm -f "$S/exists" "$S/running" "$S/args"; exit 0 ;;
  start) echo true > "$S/running"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
cat > "$TMP/stubs/curl" <<'STUB'
#!/usr/bin/env bash
echo '{"status":"ok"}'; exit 0
STUB
chmod +x "$TMP/stubs/docker" "$TMP/stubs/curl"

# precontainer <running true|false> <args...>  -> seeds DSTATE with an existing container
new_state() { DSTATE=$(mktemp -d "$TMP/ds.XXXXXX"); }
seed() { local run=$1; shift; touch "$DSTATE/exists"; echo "$run" > "$DSTATE/running"; echo "$*" > "$DSTATE/args"; }

run_init() {  # run_init "<env lines>" -> INIT_OUT INIT_RC DLOG
  local kit proj
  kit=$(mktemp -d "$TMP/kit.XXXXXX"); proj=$(mktemp -d "$TMP/proj.XXXXXX"); DLOG="$TMP/dockerlog.$RANDOM"; : > "$DLOG"
  (cd "$KIT_DIR" && tar --exclude=.git -c .) | tar -x -C "$kit"
  git -C "$proj" init -q -b main
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
  git -C "$proj" config user.email t@t; git -C "$proj" config user.name t
  mkdir -p "$proj/.agent-factory"; cp "$KIT_DIR/.env.example" "$proj/.agent-factory/.env"
  printf '%b' "$1" >> "$proj/.agent-factory/.env"
  INIT_RC=0
  INIT_OUT=$(cd "$proj" && DSTATE="$DSTATE" DOCKER_LOG="$DLOG" PATH="$TMP/stubs:$PATH" PROJECT_DIR="$proj" HOME="$TMP/home" "$kit/bin/init.sh" 2>&1) || INIT_RC=$?
}
runs() { grep -E '^docker run ' "$DLOG"; }
nruns() { runs | wc -l | tr -d ' '; }
LOCAL_ON="SYSTEM1_ENABLED=1\nSYSTEM1_LOCAL=1\n"
OLD_ARGS="-hf $MODEL --host 0.0.0.0 --port 8080"
NEW_ARGS="-hf $MODEL --host 0.0.0.0 --port 8080 $FLAGS"

test_ac1_fresh_run_has_context_and_batch_flags() {
  new_state; run_init "$LOCAL_ON"
  local r; r=$(runs | head -1)
  [ "$INIT_RC" = 0 ] && [[ "$r" == *" $FLAGS"* && "$r" == *"-hf $MODEL"* && "$r" == *"--host 0.0.0.0"* && "$r" == *"--port 8080"* ]] \
    && pass "ac1: docker run includes $FLAGS plus -hf/--host/--port" || fail "ac1: rc=$INIT_RC run: '$r'"
}
test_ac1_flags_come_after_image() {
  new_state; run_init "$LOCAL_ON"
  local r; r=$(runs | head -1); local after=${r#*llama.cpp:server-cuda}
  [[ "$after" == *"-c 8192"* && "$after" == *"-b 4096"* && "$after" == *"-ub 4096"* ]] \
    && pass "ac1: flags are llama.cpp args (after the image)" || fail "ac1: flags not after image: '$r'"
}
test_ac2_matching_running_container_reused() {
  new_state; seed true "$NEW_ARGS"; run_init "$LOCAL_ON"
  if [ "$INIT_RC" = 0 ] && [ "$(nruns)" = 0 ] && ! grep -qE '^docker rm' "$DLOG" && grep -qi 'reusing' <<<"$INIT_OUT"; then
    pass "ac2: running container with flags reused, log says so"
  else fail "ac2: rc=$INIT_RC runs=$(nruns) log: $(grep -E '^docker' "$DLOG" | tr '\n' '|') out: $(echo "$INIT_OUT" | tail -3)"; fi
}
test_ac3_old_container_recreated_with_flags() {
  new_state; seed true "$OLD_ARGS"; run_init "$LOCAL_ON"
  local r; r=$(runs | head -1)
  if [ "$INIT_RC" = 0 ] && grep -qE '^docker rm' "$DLOG" && [[ "$r" == *" $FLAGS"* ]] && grep -qi 'recreat' <<<"$INIT_OUT" && ! grep -qi 'reusing' <<<"$INIT_OUT"; then
    pass "ac3: old running container removed and recreated with $FLAGS, log says recreating"
  else fail "ac3: rc=$INIT_RC run: '$r' log: $(grep -E '^docker' "$DLOG" | tr '\n' '|') out: $(echo "$INIT_OUT" | tail -4)"; fi
}
test_ac3_old_stopped_container_recreated() {
  new_state; seed false "$OLD_ARGS"; run_init "$LOCAL_ON"
  local r; r=$(runs | head -1)
  [ "$INIT_RC" = 0 ] && grep -qE '^docker rm' "$DLOG" && [[ "$r" == *" $FLAGS"* ]] \
    && pass "ac3: old stopped container recreated with flags" || fail "ac3: rc=$INIT_RC run: '$r'"
}
test_ac3_partial_flags_recreated() {
  new_state; seed true "$OLD_ARGS -c 8192"; run_init "$LOCAL_ON"
  local r; r=$(runs | head -1)
  [ "$INIT_RC" = 0 ] && [[ "$r" == *" $FLAGS"* ]] \
    && pass "ac3: container with only some flags recreated" || fail "ac3: partial flags not recreated: run '$r'"
}
test_ac3_wrong_values_recreated() {
  new_state; seed true "$OLD_ARGS -c 4096 -b 2048 -ub 2048"; run_init "$LOCAL_ON"
  local r; r=$(runs | head -1)
  [ "$INIT_RC" = 0 ] && [[ "$r" == *" $FLAGS"* ]] \
    && pass "ac3: container with different values recreated" || fail "ac3: wrong values not recreated: run '$r'"
}
test_ac4_stopped_matching_container_started() {
  new_state; seed false "$NEW_ARGS"; run_init "$LOCAL_ON"
  if [ "$INIT_RC" = 0 ] && grep -qE '^docker start ' "$DLOG" && [ "$(nruns)" = 0 ] && ! grep -qE '^docker rm' "$DLOG"; then
    pass "ac4: stopped matching container started, not recreated"
  else fail "ac4: rc=$INIT_RC log: $(grep -E '^docker' "$DLOG" | tr '\n' '|')"; fi
}
test_ac5_not_enabled_no_docker() {
  new_state; run_init "SYSTEM1_LOCAL=1\n"
  local a=$(grep -cE '^docker (run|start|rm|inspect|stop|ps|logs).*(factory-s1-llama|llama\.cpp)' "$DLOG")
  new_state; run_init "SYSTEM1_ENABLED=1\n"
  local b=$(grep -cE '^docker (run|start|rm|inspect|stop|ps|logs).*(factory-s1-llama|llama\.cpp)' "$DLOG")
  new_state; run_init "SYSTEM1_ENABLED=0\nSYSTEM1_LOCAL=1\n"
  local c=$(grep -cE '^docker (run|start|rm|inspect|stop|ps|logs).*(factory-s1-llama|llama\.cpp)' "$DLOG")
  [ "$a" = 0 ] && [ "$b" = 0 ] && [ "$c" = 0 ] && pass "ac5: no docker call unless both flags are 1" || fail "ac5: docker calls $a/$b/$c"
}
test_ac6_model_change_recreates_with_flags() {
  new_state; seed true "-hf other/old-GGUF --host 0.0.0.0 --port 8080 $FLAGS"; run_init "$LOCAL_ON"
  local r; r=$(runs | head -1)
  if [ "$INIT_RC" = 0 ] && grep -qE '^docker rm' "$DLOG" && [[ "$r" == *"-hf $MODEL"* && "$r" == *" $FLAGS"* ]]; then
    pass "ac6: model differs -> recreated for new model with $FLAGS"
  else fail "ac6: rc=$INIT_RC run: '$r' log: $(grep -E '^docker' "$DLOG" | tr '\n' '|')"; fi
}
test_ac7_readme_mentions_sizes() {
  local para; para=$(grep -n 'factory-s1-llama' README.md | grep -v '^166:' | head -1 | cut -d: -f1)
  local blk; blk=$(sed -n "${para:-1},$((${para:-1} + 8))p" README.md)
  [[ "$blk" == *8192* && "$blk" == *4096* ]] && pass "ac7: README SYSTEM1_LOCAL paragraph mentions 8192 and 4096" || fail "ac7: README local paragraph lacks 8192/4096"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
