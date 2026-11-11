#!/usr/bin/env bash
# Acceptance tests for agent-factory-n2jj: System 1's local model is hosted by Docker Model Runner
# (llama.cpp backend, `docker model pull`), not vLLM. Derived ONLY from docs/stories/agent-factory-n2jj.md
# (test_acN_...). Docker is a stub that logs every call and tracks pulled models in $DSTATE/models;
# init.sh runs for real on a temp project.
#
# Run directly: bash tests/agent-factory-n2jj_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
DEFAULT_MODEL="hf.co/ggml-org/vllm-d3-mini-GGUF"
DEFAULT_URL="http://host.docker.internal:12434/engines/v1/systemone"
# Retired names, assembled from parts so this file does not itself contain them (AC8 scans tests).
OLD_A="vl""lm"; OLD_B="Liquid""AI/d1-2B"; OLD_C="factory-""system1"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

# DOCKER_FAIL_PULL=1 makes `docker model pull` fail (AC5); DOCKER_NO_DMR=1 makes every `docker model` fail.
cat > "$TMP/stubs/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_LOG:-/dev/null}"
M="$DSTATE/models"; touch "$M"
case "$1" in
  model)
    [ "${DOCKER_NO_DMR:-}" = 1 ] && { echo "docker: 'model' is not a docker command" >&2; exit 1; }
    case "$2" in
      pull)
        [ "${DOCKER_FAIL_PULL:-}" = 1 ] && { echo "Error: failed to pull model: simulated failure" >&2; exit 1; }
        grep -qxF "$3" "$M" || echo "$3" >> "$M"; echo "Model $3 pulled"; exit 0 ;;
      list|ls) cat "$M"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  compose)
    case " $* " in *" run "*) ( cd "$PROJECT_DIR" && { echo ".agent-factory/" >> .gitignore; git add .gitignore && git commit -q -m s; } );; esac
    exit 0 ;;
  ps) exit 0 ;;
  inspect) echo "Error: No such object" >&2; exit 1 ;;
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
pulls() { grep -E '^docker model pull ' "$DLOG"; }
LOCAL_ON="SYSTEM1_ENABLED=1\nSYSTEM1_LOCAL=1\n"

# ---------- AC1 ----------
test_ac1_local_pulls_model_via_dmr() {
  run_init "$LOCAL_ON"
  if [ "$INIT_RC" = 0 ] && [ -n "$(pulls)" ]; then pass "ac1: SYSTEM1_LOCAL=1 -> docker model pull ($(pulls | head -1))"
  else fail "ac1: rc=$INIT_RC no docker model pull. log: $(tr '\n' '|' < "$DLOG") out: $(echo "$INIT_OUT" | tail -3)"; fi
}
test_ac1_no_container_no_vllm_image() {
  run_init "$LOCAL_ON"
  if ! grep -qE '^docker run' "$DLOG" && ! strip_model < "$DLOG" | grep -qiE "$OLD_A|$OLD_C"; then pass "ac1: no docker run, no vLLM image/container referenced"
  else fail "ac1: container/vLLM activity: $(strip_model < "$DLOG" | grep -iE "^docker run|$OLD_A|$OLD_C" | tr '\n' '|')"; fi
}

# ---------- AC2 ----------
test_ac2_default_model_pulled() {
  run_init "$LOCAL_ON"
  if [ "$INIT_RC" = 0 ] && pulls | grep -qxF "docker model pull $DEFAULT_MODEL"; then pass "ac2: default model pulled is $DEFAULT_MODEL"
  else fail "ac2: pulls: $(pulls | tr '\n' '|') rc=$INIT_RC"; fi
}
test_ac2_scripts_default_model() {
  local f ok=1
  for f in bin/system1.sh bin/system1-class.sh; do
    grep -E '^SYSTEM1_MODEL=' "$f" | grep -qF "$DEFAULT_MODEL" || { ok=0; echo "  $f: $(grep -E '^SYSTEM1_MODEL=' "$f")"; }
  done
  [ "$ok" = 1 ] && pass "ac2: system1.sh and system1-class.sh default to $DEFAULT_MODEL" || fail "ac2: script default model wrong"
}

# ---------- AC3 ----------
test_ac3_model_override_pulled() {
  run_init "${LOCAL_ON}SYSTEM1_MODEL=hf.co/example/other-1B\n"
  if pulls | grep -qxF "docker model pull hf.co/example/other-1B" && ! pulls | grep -qF "$DEFAULT_MODEL"; then pass "ac3: SYSTEM1_MODEL override pulled instead of default"
  else fail "ac3: pulls: $(pulls | tr '\n' '|')"; fi
}

# ---------- AC4 ----------
test_ac4_rerun_succeeds_when_already_pulled() {
  run_init "$LOCAL_ON"; local rc1=$INIT_RC
  rerun_init
  if [ "$rc1" = 0 ] && [ "$INIT_RC" = 0 ] && ! grep -qE '^docker run' "$DLOG"; then pass "ac4: second init.sh with model already pulled succeeds"
  else fail "ac4: rc1=$rc1 rc2=$INIT_RC out: $(echo "$INIT_OUT" | tail -3)"; fi
}

# ---------- AC5 ----------
test_ac5_pull_failure_exits_nonzero_naming_dmr() {
  DOCKER_FAIL_PULL=1; export DOCKER_FAIL_PULL
  run_init "$LOCAL_ON"
  unset DOCKER_FAIL_PULL
  if [ "$INIT_RC" != 0 ] && grep -qiE 'docker model runner' <<<"$INIT_OUT" && grep -qiE 'fail|error|cannot|could not|unavailable' <<<"$INIT_OUT"; then
    pass "ac5: pull failure -> non-zero exit, message names Docker Model Runner and the failure"
  else fail "ac5: rc=$INIT_RC out: $(echo "$INIT_OUT" | tail -4)"; fi
}
test_ac5_dmr_unavailable_exits_nonzero_naming_dmr() {
  DOCKER_NO_DMR=1; export DOCKER_NO_DMR
  run_init "$LOCAL_ON"
  unset DOCKER_NO_DMR
  if [ "$INIT_RC" != 0 ] && grep -qiE 'docker model runner' <<<"$INIT_OUT"; then pass "ac5: DMR unavailable -> non-zero exit naming Docker Model Runner"
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
echo '{"choices":[{"message":{"content":"low"}}]}'
S
  chmod +x "$d/stubs/"*; CURL_LOG="$d/curl.log"; : > "$CURL_LOG"
  ( unset SYSTEM1_URL SYSTEM1_MODEL; [ -z "${1:-}" ] || export "$1"; export CURL_LOG
    PATH="$d/stubs:$PATH" bash "$KIT_DIR/bin/system1-class.sh" t-1 >/dev/null 2>&1 )
  CALLED=$(tail -1 "$CURL_LOG")
}
test_ac7_request_targets_dmr_endpoint() {
  run_class ""
  if [[ "$CALLED" == "$DEFAULT_URL/chat/completions" || ( "$CALLED" == "$DEFAULT_URL"/* && "$CALLED" == */chat/completions ) ]]; then
    pass "ac7: system1-class.sh unset URL -> $CALLED"
  else fail "ac7: unset SYSTEM1_URL posted to '$CALLED'"; fi
}
test_ac7_url_override_still_wins() {
  run_class "SYSTEM1_URL=http://example.invalid:9/v1"
  [ "$CALLED" = "http://example.invalid:9/v1/chat/completions" ] && pass "ac7: SYSTEM1_URL override still used" || fail "ac7: override ignored, posted to '$CALLED'"
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
test_ac8_docs_describe_dmr_llamacpp() {
  local ok=1 f
  for f in README.md .env.example; do
    grep -qi 'model runner' "$f" && grep -qi 'llama\.cpp' "$f" && grep -q 'SYSTEM1_LOCAL' "$f" && grep -qF "$DEFAULT_MODEL" "$f" \
      || { ok=0; echo "  $f lacks Docker Model Runner / llama.cpp / SYSTEM1_LOCAL / $DEFAULT_MODEL"; }
  done
  [ "$ok" = 1 ] && pass "ac8: README and .env.example describe local DMR (llama.cpp) hosting" || fail "ac8: docs incomplete"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
