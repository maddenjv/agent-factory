#!/usr/bin/env bash
# Acceptance tests for agent-factory-lxo0: System 1's local model runs on vLLM
# (vllm/vllm-openai:latest, run directly with `docker run`) instead of Docker Model Runner.
# Derived ONLY from docs/stories/agent-factory-lxo0.md (test_acN_...). The story leaves open the
# container name, the port and the exact `docker run` flags, so the tests only assume:
#   - the container is started with `docker run` of image vllm/vllm-openai:latest, with the model id as
#     an argument token (e.g. `--model <id>`), and the default SYSTEM1_URL port (read from
#     bin/system1.sh) published on all interfaces (-p [PORT]:8000, or --network host + --port PORT);
#   - already-running state is discoverable via ordinary docker verbs (ps/inspect/rm/stop/start).
# Docker is a stateful stub (containers tracked in $DSTATE); init.sh runs for real on a temp project.
#
# Run directly: bash tests/agent-factory-lxo0_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
IMAGE="vllm/vllm-openai:latest"
DEFAULT_MODEL="LiquidAI/d1-2B"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

# Stateful docker stub. $DSTATE/containers: id|name|image|state|args. $DOCKER_LOG: every call.
# DOCKER_FAIL_RUN=1 makes `run` and `pull` fail (AC5).
cat > "$TMP/stubs/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_LOG:-/dev/null}"
C="$DSTATE/containers"; touch "$C"
case "$1" in
  model) echo "docker model is not available" >&2; exit 1 ;;
  compose)
    case " $* " in *" run "*) ( cd "$PROJECT_DIR" && { echo ".agent-factory/" >> .gitignore; git add .gitignore && git commit -q -m s; } );; esac
    exit 0 ;;
  pull) [ "${DOCKER_FAIL_RUN:-}" = 1 ] && { echo "Error response from daemon: pull access denied" >&2; exit 1; }; exit 0 ;;
  run)
    [ "${DOCKER_FAIL_RUN:-}" = 1 ] && { echo "docker: Error response from daemon: simulated run failure" >&2; exit 125; }
    shift; name=""; args=("$@")
    for ((i=0;i<${#args[@]};i++)); do
      case "${args[$i]}" in --name) name=${args[$((i+1))]};; --name=*) name=${args[$i]#--name=};; esac
    done
    if [ -n "$name" ] && grep -q "^[^|]*|$name|" "$C"; then
      echo "docker: Error response from daemon: Conflict. The container name \"/$name\" is already in use." >&2; exit 125; fi
    img=""; for a in "${args[@]}"; do case "$a" in */*:*|vllm*) img=$a; break;; esac; done
    id="c$(( $(wc -l < "$C") + 1 ))$RANDOM"
    echo "$id|${name:-anon$RANDOM}|$img|running|${args[*]}" >> "$C"; echo "$id"; exit 0 ;;
  ps)
    all=0; q=0; fmt=""; fname=""; fanc=""; a=("$@")
    for ((i=1;i<${#a[@]};i++)); do case "${a[$i]}" in
      -a|--all) all=1;; -q|--quiet) q=1;; -aq|-qa) all=1; q=1;;
      --format) fmt=${a[$((i+1))]};; --format=*) fmt=${a[$i]#--format=};;
      -f|--filter) f=${a[$((i+1))]}; case "$f" in name=*) fname=${f#name=};; ancestor=*) fanc=${f#ancestor=};; esac;;
      --filter=name=*) fname=${a[$i]#--filter=name=};; --filter=ancestor=*) fanc=${a[$i]#--filter=ancestor=};;
    esac; done
    while IFS='|' read -r id name img state args; do
      [ -n "$id" ] || continue
      [ "$all" = 1 ] || [ "$state" = running ] || continue
      [ -z "$fname" ] || [[ "$name" =~ ${fname#^} ]] || continue
      [ -z "$fanc" ] || [ "${fanc%:latest}" = "${img%:latest}" ] || continue
      if [ "$q" = 1 ]; then echo "$id"
      elif [ -n "$fmt" ]; then o=${fmt//\{\{.Names\}\}/$name}; o=${o//\{\{.ID\}\}/$id}; o=${o//\{\{.Image\}\}/$img}; o=${o//\{\{.State\}\}/$state}; o=${o//\{\{.Status\}\}/$state}; echo "$o"
      else echo "$id  $img  $name  $state"; fi
    done < "$C"; exit 0 ;;
  inspect)
    t=${!#}; l=$(grep -E "^$t\||^[^|]*\|$t\|" "$C" | head -1); [ -n "$l" ] || { echo "Error: No such object: $t" >&2; echo "[]"; exit 1; }
    st=$(echo "$l" | cut -d'|' -f4); echo "[{\"Name\":\"/$(echo "$l" | cut -d'|' -f2)\",\"State\":{\"Running\":$([ "$st" = running ] && echo true || echo false),\"Status\":\"$st\"}}]"
    # best-effort for --format '{{.State.Running}}' etc.
    case " $* " in *"State.Running"*) [ "$st" = running ] && echo true || echo false;; esac; exit 0 ;;
  rm|stop|kill|start|restart)
    verb=$1; shift; for t in "$@"; do case "$t" in -*) continue;; esac
      l=$(grep -E "^$t\||^[^|]*\|$t\|" "$C" | head -1); [ -n "$l" ] || { echo "Error: No such container: $t" >&2; continue; }
      id=${l%%|*}
      case "$verb" in rm) grep -v "^$id|" "$C" > "$C.t"; mv "$C.t" "$C";;
        stop|kill) sed -i "s/^\($id|[^|]*|[^|]*|\)running/\1exited/" "$C";;
        start|restart) sed -i "s/^\($id|[^|]*|[^|]*|\)exited/\1running/" "$C";; esac
      echo "$t"; done; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$TMP/stubs/docker"

# run_init "<env lines>" [pre-existing DSTATE dir]  -> INIT_OUT, INIT_RC, DLOG, DSTATE
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
run_cmds() { grep -E '^docker run( |$)' "$DLOG"; }
vllm_running() { awk -F'|' -v i="$IMAGE" '$3==i && $4=="running"' "$DSTATE/containers" | wc -l | tr -d ' '; }
default_port() { grep -E '^SYSTEM1_URL=' bin/system1.sh | head -1 | sed -E 's#.*host\.docker\.internal:([0-9]+)/.*#\1#'; }
LOCAL_ON="SYSTEM1_ENABLED=1\nSYSTEM1_LOCAL=1\n"

# ---------- AC1 ----------
test_ac1_local_starts_vllm_container_serving_model() {
  run_init "$LOCAL_ON"
  local r; r=$(run_cmds | grep -F "$IMAGE" | head -1)
  if [ "$INIT_RC" = 0 ] && [ -n "$r" ] && grep -qF "$DEFAULT_MODEL" <<<"$r" && [ "$(vllm_running)" = 1 ]; then
    pass "ac1: init.sh ran $IMAGE with the model; one vllm container running"
  else fail "ac1: rc=$INIT_RC run='$r' running=$(vllm_running). docker log: $(tr '\n' '|' < "$DLOG") out: $(echo "$INIT_OUT" | tail -3)"; fi
}
test_ac1_never_invokes_docker_model() {
  run_init "$LOCAL_ON"
  grep -qE '^docker model' "$DLOG" && fail "ac1: init.sh invoked docker model: $(grep '^docker model' "$DLOG" | tr '\n' '|')" \
    || pass "ac1: init.sh never invokes docker model"
}
test_ac1_default_url_port_is_published() {
  run_init "$LOCAL_ON"
  local p r; p=$(default_port); r=$(run_cmds | grep -F "$IMAGE" | head -1)
  if ! [[ "$p" =~ ^[0-9]+$ ]]; then fail "ac1: cannot read default port from bin/system1.sh (got '$p')"; return; fi
  if grep -qE "(^| )(-p|--publish)[ =]$p:|(^| )(-p|--publish)[ =][0-9.]+:$p:|--network[ =]host.*--port[ =]$p( |$)" <<<"$r" \
     && ! grep -qE "(-p|--publish)[ =]127\.0\.0\.1:|(-p|--publish)[ =]localhost:" <<<"$r"; then
    pass "ac1: default SYSTEM1_URL port $p published on host interfaces (reachable via host.docker.internal)"
  else fail "ac1: port $p not published reachably in: $r"; fi
}

# ---------- AC2 ----------
test_ac2_default_model_is_liquid_d1_2b_everywhere() {
  run_init "$LOCAL_ON"
  local r ok=1 f; r=$(run_cmds | grep -F "$IMAGE" | head -1)
  grep -qF "$DEFAULT_MODEL" <<<"$r" && ! grep -qF "hf.co/" <<<"$r" || { ok=0; echo "  init serves: $r"; }
  for f in bin/system1.sh bin/system1-class.sh; do
    grep -E '^SYSTEM1_MODEL=' "$f" | grep -qF "$DEFAULT_MODEL" && ! grep -E '^SYSTEM1_MODEL=' "$f" | grep -q 'hf\.co' \
      || { ok=0; echo "  $f default model: $(grep -E '^SYSTEM1_MODEL=' "$f")"; }
  done
  [ "$ok" = 1 ] && pass "ac2: init.sh, system1.sh and system1-class.sh default to $DEFAULT_MODEL" || fail "ac2: default model wrong"
}

# ---------- AC3 ----------
test_ac3_model_override_served() {
  run_init "${LOCAL_ON}SYSTEM1_MODEL=example-org/other-1B\n"
  local r; r=$(run_cmds | grep -F "$IMAGE" | head -1)
  if grep -qF "example-org/other-1B" <<<"$r" && ! grep -qF "$DEFAULT_MODEL" <<<"$r"; then pass "ac3: SYSTEM1_MODEL override served by vLLM"
  else fail "ac3: override not honoured. run: $r"; fi
}

# ---------- AC4 ----------
test_ac4_rerun_idempotent_single_container() {
  run_init "$LOCAL_ON"
  local rc1=$INIT_RC
  rerun_init
  if [ "$rc1" = 0 ] && [ "$INIT_RC" = 0 ] && [ "$(vllm_running)" = 1 ] && [ "$(awk -F'|' -v i="$IMAGE" '$3==i' "$DSTATE/containers" | wc -l | tr -d ' ')" = 1 ]; then
    pass "ac4: second init.sh succeeds, exactly one vllm container serving the model"
  else fail "ac4: rc1=$rc1 rc2=$INIT_RC running=$(vllm_running). containers: $(tr '\n' ';' < "$DSTATE/containers") out: $(echo "$INIT_OUT" | tail -3)"; fi
}
test_ac4_rerun_with_stopped_container_recovers() {
  run_init "$LOCAL_ON"
  sed -i 's/|running|/|exited|/' "$DSTATE/containers"   # previous container exists but is stopped
  rerun_init
  if [ "$INIT_RC" = 0 ] && [ "$(vllm_running)" = 1 ] && [ "$(awk -F'|' -v i="$IMAGE" '$3==i' "$DSTATE/containers" | wc -l | tr -d ' ')" = 1 ]; then
    pass "ac4: re-run with a stopped vllm container -> succeeds, exactly one running"
  else fail "ac4: stopped-container re-run rc=$INIT_RC containers: $(tr '\n' ';' < "$DSTATE/containers") out: $(echo "$INIT_OUT" | tail -3)"; fi
}

# ---------- AC5 ----------
test_ac5_start_failure_exits_nonzero_naming_image() {
  local kit proj
  DOCKER_FAIL_RUN=1; export DOCKER_FAIL_RUN
  run_init "$LOCAL_ON"
  unset DOCKER_FAIL_RUN
  if [ "$INIT_RC" != 0 ] && grep -qF "vllm/vllm-openai" <<<"$INIT_OUT" && grep -qiE 'fail|error|cannot|could not' <<<"$INIT_OUT"; then
    pass "ac5: docker run failure -> non-zero exit, message names the vLLM image"
  else fail "ac5: rc=$INIT_RC out: $(echo "$INIT_OUT" | tail -4)"; fi
}

# ---------- AC6 ----------
test_ac6_local_unset_starts_nothing() {
  local c
  for c in "" "SYSTEM1_ENABLED=1\n" "SYSTEM1_ENABLED=1\nSYSTEM1_URL=https://example.invalid/v1\nSYSTEM1_API_KEY=k\n"; do
    run_init "$c"
    if [ "$INIT_RC" = 0 ] && ! grep -qE '^docker model' "$DLOG" && ! grep -qF "$IMAGE" "$DLOG" && [ "$(vllm_running)" = 0 ]; then
      pass "ac6: SYSTEM1_LOCAL unset ($(printf '%b' "$c" | head -1 | tr -d '\n')) -> no vllm container, no docker model"
    else fail "ac6: unexpected docker activity or failure rc=$INIT_RC: $(tr '\n' '|' < "$DLOG")"; fi
  done
}

# ---------- AC7 ----------
test_ac7_default_url_targets_vllm_endpoint() {
  local a b; a=$(grep -E '^SYSTEM1_URL=' bin/system1.sh | head -1); b=$(grep -E '^SYSTEM1_URL=' bin/system1-class.sh | head -1)
  local ua ub; ua=$(sed -E 's/.*:-([^}]*)\}.*/\1/' <<<"$a"); ub=$(sed -E 's/.*:-([^}]*)\}.*/\1/' <<<"$b")
  if [ -n "$ua" ] && [ "$ua" = "$ub" ] && [[ "$ua" == */v1 ]] && [[ "$ua" != *engines* ]] && [[ "$ua" == http://host.docker.internal:* ]]; then
    pass "ac7: both scripts default to the same vLLM base URL ($ua, request path /v1/chat/completions)"
  else fail "ac7: defaults differ or are not a vLLM /v1 endpoint: '$ua' vs '$ub'"; fi
}
# dynamic: system1-class.sh with a stub curl records the URL it posts to.
run_class() {  # run_class [env assignment]
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
test_ac7_request_goes_to_default_vllm_chat_completions() {
  run_class ""
  local p; p=$(default_port)
  if [[ "$CALLED" == "http://host.docker.internal:$p/v1/chat/completions" ]]; then pass "ac7: system1-class.sh unset URL -> $CALLED"
  else fail "ac7: unset SYSTEM1_URL posted to '$CALLED'"; fi
}
test_ac7_url_override_still_wins() {
  run_class "SYSTEM1_URL=http://example.invalid:9/v1"
  [ "$CALLED" = "http://example.invalid:9/v1/chat/completions" ] && pass "ac7: SYSTEM1_URL override still used" || fail "ac7: override ignored, posted to '$CALLED'"
}

# ---------- AC8 ----------
FILES=(README.md .env.example docs/ARCHITECTURE.md docker-compose.yml bin)
test_ac8_no_docker_model_runner_references() {
  local hits; hits=$(grep -rniE 'docker model|model[ -]runner|hf\.co/LiquidAI' "${FILES[@]}" 2>/dev/null)
  [ -z "$hits" ] && pass "ac8: no Docker Model Runner / docker model / hf.co/LiquidAI/d1-2B references" || fail "ac8: stale references:
$(echo "$hits" | head -10)"
}
test_ac8_ports_agree_with_default_url() {
  local p bad; p=$(default_port)
  # any System 1 port mention that is not the default's port
  bad=$(grep -rnE 'SYSTEM1|System 1|vllm|vLLM' "${FILES[@]}" 2>/dev/null | grep -oE '[A-Za-z0-9_./:-]*:[0-9]{4,5}\b' | grep -E 'host\.docker\.internal|localhost|--tcp|12434' | grep -vE ":$p\$")
  [ -z "$bad" ] && [[ "$p" =~ ^[0-9]+$ ]] && pass "ac8: every System 1 port mention matches default URL port $p" || fail "ac8: disagreeing port mentions (default '$p'): $bad"
}
test_ac8_docs_describe_local_vllm_hosting() {
  local ok=1
  for f in README.md .env.example; do
    grep -qi 'vllm' "$f" && grep -q 'SYSTEM1_LOCAL' "$f" && grep -qF "$DEFAULT_MODEL" "$f" || { ok=0; echo "  $f lacks vLLM / SYSTEM1_LOCAL / $DEFAULT_MODEL"; }
  done
  grep -qF 'vllm/vllm-openai' README.md || { ok=0; echo "  README does not name the vllm/vllm-openai image"; }
  [ "$ok" = 1 ] && pass "ac8: README and .env.example describe enabling local vLLM hosting" || fail "ac8: docs incomplete"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
