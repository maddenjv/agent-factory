#!/usr/bin/env bash
# Acceptance tests for agent-factory-n2jj: System 1's local model is hosted by llama.cpp, not vLLM.
# Originally Docker Model Runner (`docker model pull`); updated by agent-factory-jgll to the y330
# contract (llama.cpp server container `docker run ... -hf <model>`, POST <base>/v1/systemone).
# Docker is a stub that logs every call and emulates one container in $DSTATE; init.sh runs for real
# on a temp project. The "no vllm / d1-2B leftovers" check (AC8) is unchanged.
#
# Run directly: bash tests/agent-factory-n2jj_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
DEFAULT_MODEL="ggml-org/vllm-d3-mini-GGUF"
DEFAULT_URL="http://host.docker.internal:8080"
# Retired names, assembled from parts so this file does not itself contain them (AC8 scans tests).
OLD_A="vl""lm"; OLD_B="Liquid""AI/d1-2B"; OLD_C="factory-""system1"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

# DOCKER_FAIL_RUN=1 makes `docker run` fail (AC5). The stub emulates one container: `run` records its -hf
# model in $DSTATE/c; `inspect` reports it as running with those args.
cat > "$TMP/stubs/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_LOG:-/dev/null}"
case "$1" in
  run)
    [ "${DOCKER_FAIL_RUN:-}" = 1 ] && { echo "Error: simulated docker run failure" >&2; exit 1; }
    m=""; while [ $# -gt 0 ]; do [ "$1" = -hf ] && m=$2; shift; done; echo "$m" > "$DSTATE/c"; exit 0 ;;
  inspect) [ -s "$DSTATE/c" ] && { echo "true|-hf $(cat "$DSTATE/c") --host 0.0.0.0 --port 8080 -c 8192 -b 4096 -ub 4096"; exit 0; }
    echo "Error: No such object" >&2; exit 1 ;;
  rm) rm -f "$DSTATE/c"; exit 0 ;;
  compose)
    case " $* " in *" run "*) ( cd "$PROJECT_DIR" && { echo ".agent-factory/" >> .gitignore; git add .gitignore && git commit -q -m s; } );; esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/stubs/docker"

# run_init "<env lines>" [existing DSTATE] -> INIT_OUT, INIT_RC, DLOG, DSTATE
run_init() {
  local kit proj
  kit=$(mktemp -d "$TMP/kit.XXXXXX"); proj=$(mktemp -d "$TMP/proj.XXXXXX"); DLOG="$TMP/dockerlog.$RANDOM"; : > "$DLOG"
  DSTATE=${2:-$(mktemp -d "$TMP/ds.XXXXXX")}
  (cd "$KIT_DIR" && tar --exclude=.git -c .) | tar -x -C "$kit"
  git -C "$proj" init -q -b main
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
  git -C "$proj" config user.email t@t; git -C "$proj" config user.name t
  mkdir -p "$proj/.agent-factory"; cp "$KIT_DIR/.env.example" "$proj/.agent-factory/.env"
  printf '%b' "$1" >> "$proj/.agent-factory/.env"
  PROJ=$proj; KIT=$kit
  rerun_init
}
rerun_init() {
  INIT_RC=0
  INIT_OUT=$(cd "$PROJ" && DSTATE="$DSTATE" DOCKER_LOG="$DLOG" PATH="$TMP/stubs:$PATH" PROJECT_DIR="$PROJ" "$KIT/bin/init.sh" 2>&1) || INIT_RC=$?
}
runs() { grep -E '^docker run ' "$DLOG"; }
LOCAL_ON="SYSTEM1_ENABLED=1\nSYSTEM1_LOCAL=1\n"

# ---------- AC1 ----------
test_ac1_local_starts_llamacpp_container() {
  run_init "$LOCAL_ON"
  if [ "$INIT_RC" = 0 ] && runs | grep -q 'llama\.cpp' && ! grep -qE '^docker model' "$DLOG"; then pass "ac1: SYSTEM1_LOCAL=1 -> docker run llama.cpp, no docker model call"
  else fail "ac1: rc=$INIT_RC log: $(tr '\n' '|' < "$DLOG") out: $(echo "$INIT_OUT" | tail -3)"; fi
}
test_ac1_no_vllm_image() {
  run_init "$LOCAL_ON"
  if ! strip_model < "$DLOG" | grep -qiE "$OLD_A|$OLD_C"; then pass "ac1: no vLLM image/container referenced"
  else fail "ac1: vLLM activity: $(strip_model < "$DLOG" | grep -iE "$OLD_A|$OLD_C" | tr '\n' '|')"; fi
}

# ---------- AC2 ----------
test_ac2_default_model_used() {
  run_init "$LOCAL_ON"
  if [ "$INIT_RC" = 0 ] && runs | grep -qE -- " -hf $DEFAULT_MODEL( |\$)"; then pass "ac2: default model started is $DEFAULT_MODEL"
  else fail "ac2: runs: $(runs | tr '\n' '|') rc=$INIT_RC"; fi
}
test_ac2_scripts_default_model() {
  local f ok=1
  for f in bin/system1.sh bin/system1-class.sh; do
    grep -E '^SYSTEM1_MODEL=' "$f" | grep -qF "$DEFAULT_MODEL" || { ok=0; echo "  $f: $(grep -E '^SYSTEM1_MODEL=' "$f")"; }
  done
  [ "$ok" = 1 ] && pass "ac2: system1.sh and system1-class.sh default to $DEFAULT_MODEL" || fail "ac2: script default model wrong"
}

# ---------- AC3 ----------
test_ac3_model_override_used() {
  run_init "${LOCAL_ON}SYSTEM1_MODEL=example/other-1B\n"
  if runs | grep -qE -- " -hf example/other-1B( |\$)" && ! runs | grep -qF "$DEFAULT_MODEL"; then pass "ac3: SYSTEM1_MODEL override used instead of default"
  else fail "ac3: runs: $(runs | tr '\n' '|')"; fi
}

# ---------- AC4 ----------
test_ac4_rerun_succeeds_when_already_running() {
  run_init "$LOCAL_ON"; local rc1=$INIT_RC
  : > "$DLOG"
  rerun_init
  if [ "$rc1" = 0 ] && [ "$INIT_RC" = 0 ] && [ -z "$(runs)" ]; then pass "ac4: second init.sh with the container already running succeeds, no new docker run"
  else fail "ac4: rc1=$rc1 rc2=$INIT_RC runs: $(runs | tr '\n' '|') out: $(echo "$INIT_OUT" | tail -3)"; fi
}

# ---------- AC5 ----------
test_ac5_run_failure_exits_nonzero() {
  DOCKER_FAIL_RUN=1; export DOCKER_FAIL_RUN
  run_init "$LOCAL_ON"
  unset DOCKER_FAIL_RUN
  if [ "$INIT_RC" != 0 ] && grep -qiE 'llama\.cpp' <<<"$INIT_OUT" && grep -qiE 'fail|error|cannot|could not|unavailable' <<<"$INIT_OUT"; then
    pass "ac5: docker run failure -> non-zero exit, message names llama.cpp and the failure"
  else fail "ac5: rc=$INIT_RC out: $(echo "$INIT_OUT" | tail -4)"; fi
}

# ---------- AC6 ----------
test_ac6_local_unset_runs_nothing() {
  local c
  for c in "" "SYSTEM1_ENABLED=1\n" "SYSTEM1_ENABLED=1\nSYSTEM1_URL=https://example.invalid/v1\nSYSTEM1_API_KEY=k\n"; do
    run_init "$c"
    if [ "$INIT_RC" = 0 ] && ! grep -qE '^docker (model|run)' "$DLOG"; then
      pass "ac6: SYSTEM1_LOCAL unset ($(printf '%b' "$c" | head -1 | tr -d '\n')) -> no docker model, no container"
    else fail "ac6: rc=$INIT_RC unexpected docker activity: $(grep -E '^docker (model|run)' "$DLOG" | tr '\n' '|')"; fi
  done
}

# ---------- AC7 ----------
test_ac7_default_url_in_scripts() {
  local f ok=1 line
  for f in bin/system1.sh bin/system1-class.sh; do
    line=$(grep -E '^SYSTEM1_URL=' "$f" | head -1)
    [[ "$line" == *":-$DEFAULT_URL}"* ]] || { ok=0; echo "  $f: $line"; }
  done
  [ "$ok" = 1 ] && pass "ac7: both scripts default SYSTEM1_URL to $DEFAULT_URL" || fail "ac7: default URL wrong"
}
run_class() {  # run_class [env assignment] -> CALLED (last curl arg)
  local d; d=$(mktemp -d "$TMP/cls.XXXXXX"); mkdir -p "$d/stubs"
  cat > "$d/stubs/bd" <<'S'
#!/usr/bin/env bash
echo '[{"id":"t-1","title":"fix typo","description":"d","labels":[],"status":"open"}]'
S
  cat > "$d/stubs/curl" <<'S'
#!/usr/bin/env bash
for a in "$@"; do last=$a; done; echo "$last" >> "$CURL_LOG"
echo '{"answers":{"class":{"choice":"low","confidence":0.9,"probabilities":{}}},"usage":{}}'
S
  chmod +x "$d/stubs/"*; CURL_LOG="$d/curl.log"; : > "$CURL_LOG"
  ( unset SYSTEM1_URL SYSTEM1_MODEL; [ -z "${1:-}" ] || export "$1"; export CURL_LOG
    PATH="$d/stubs:$PATH" bash "$KIT_DIR/bin/system1-class.sh" t-1 >/dev/null 2>&1 )
  CALLED=$(tail -1 "$CURL_LOG")
}
test_ac7_request_targets_systemone_endpoint() {
  run_class ""
  [ "$CALLED" = "$DEFAULT_URL/v1/systemone" ] && pass "ac7: system1-class.sh unset URL -> $CALLED" || fail "ac7: unset SYSTEM1_URL posted to '$CALLED'"
}
test_ac7_url_override_still_wins() {
  run_class "SYSTEM1_URL=http://example.invalid:9"
  [ "$CALLED" = "http://example.invalid:9/v1/systemone" ] && pass "ac7: SYSTEM1_URL override still used" || fail "ac7: override ignored, posted to '$CALLED'"
}

# ---------- AC8 ----------
FILES=(README.md .env.example docs/ARCHITECTURE.md docker-compose.yml bin)
S1_TESTS=(); while IFS= read -r t; do [ "$(basename "$t")" = "$(basename "${BASH_SOURCE[0]}")" ] || S1_TESTS+=("$t"); done < <(grep -lE 'SYSTEM1|System 1' tests/*.sh tests/acceptance/*.sh 2>/dev/null)
strip_model() { sed "s#$DEFAULT_MODEL##g"; }   # the model's own name legitimately contains "$OLD_A"
test_ac8_no_stale_vllm_references() {
  local hits f
  hits=$(for f in "${FILES[@]}" "${S1_TESTS[@]}"; do grep -rnIE -i "$OLD_A|$OLD_B|$OLD_C" "$f" 2>/dev/null | strip_model | grep -iE "$OLD_A|$OLD_B|$OLD_C" | sed "s#^#$f: #"; done)
  [ -z "$hits" ] && pass "ac8: no vLLM / vllm-openai / factory-system1 / d1-2B references in docs, bin, compose or System 1 tests" || fail "ac8: stale references:
$(echo "$hits" | head -10)"
}
test_ac8_docs_describe_llamacpp() {
  local ok=1 f
  for f in README.md .env.example; do
    grep -qi 'llama\.cpp' "$f" && grep -q 'SYSTEM1_LOCAL' "$f" && grep -qF "$DEFAULT_MODEL" "$f" \
      || { ok=0; echo "  $f lacks llama.cpp / SYSTEM1_LOCAL / $DEFAULT_MODEL"; }
  done
  [ "$ok" = 1 ] && pass "ac8: README and .env.example describe local llama.cpp hosting" || fail "ac8: docs incomplete"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
