#!/usr/bin/env bash
# Acceptance tests for agent-factory-y330: System 1 runs in a llama.cpp server container and is
# called through POST /v1/systemone (no Docker Model Runner, no /chat/completions).
# Derived ONLY from docs/stories/agent-factory-y330.md (test_acN_...).
#
# The llama.cpp response contract is the architect's call (story: "design must code to that spec"),
# so the fake server's reply is deliberately tolerant: the decision/class is offered at top level, under
# common wrapper keys (answers/result/response/output) AND as chat-style choices[0].message.content.
# Tests assert on transport (method, path, auth, body keys) and on the resulting bd/loop behaviour.
# Docker is a stub (logs calls, remembers containers in $DSTATE/containers); init.sh runs for real.
#
# Run directly: bash tests/agent-factory-y330_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
DEFAULT_MODEL="ggml-org/vllm-d3-mini-GGUF"
IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"
HI=m-high-y330; MED=m-medium-y330; LO=m-low-y330
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "SKIP: python3 missing"; exit 0; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }

TMP="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

# ============ docker / init.sh harness ============
cat > "$TMP/stubs/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_LOG:-/dev/null}"
C="$DSTATE/containers"; touch "$C"
case "$1" in
  model) echo "docker: 'model' is not a docker command" >&2; exit 1 ;;   # DMR is never available here
  run)
    [ "${DOCKER_FAIL_RUN:-}" = 1 ] && { echo "docker: Error response from daemon: could not select device driver" >&2; exit 125; }
    name=""; prev=""
    for a in "$@"; do [ "$prev" = --name ] && name=$a; case "$a" in --name=*) name=${a#--name=};; esac; prev=$a; done
    if [ -n "$name" ] && grep -qxF "$name" "$C"; then echo "docker: Conflict. The container name \"$name\" is already in use" >&2; exit 125; fi
    [ -n "$name" ] && echo "$name" >> "$C"; echo "abc123"; exit 0 ;;
  ps|container) cat "$C"; exit 0 ;;
  inspect)
    for a in "$@"; do grep -qxF "$a" "$C" && { echo true; exit 0; }; done
    echo "Error: No such object" >&2; exit 1 ;;
  start|restart) exit 0 ;;
  compose)
    case " $* " in *" run "*) ( cd "$PROJECT_DIR" && { echo ".agent-factory/" >> .gitignore; git add .gitignore && git commit -q -m s; } );; esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
cat > "$TMP/stubs/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "${DOCKER_LOG:-/dev/null}"
echo '{"status":"ok"}'; exit 0
STUB
chmod +x "$TMP/stubs/docker" "$TMP/stubs/curl"

run_init() {  # run_init "<env lines>" [DSTATE] -> INIT_OUT INIT_RC DLOG DSTATE
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
  INIT_OUT=$(cd "$PROJ" && DSTATE="$DSTATE" DOCKER_LOG="$DLOG" PATH="$TMP/stubs:$PATH" PROJECT_DIR="$PROJ" HOME="$TMP/home" "$KIT/bin/init.sh" 2>&1) || INIT_RC=$?
}
runs() { grep -E '^docker run ' "$DLOG"; }
LOCAL_ON="SYSTEM1_ENABLED=1\nSYSTEM1_LOCAL=1\n"
mkdir -p "$TMP/home"

# ---------- AC1 ----------
test_ac1_init_starts_llamacpp_container() {
  run_init "$LOCAL_ON"
  local r; r=$(runs | head -1)
  local ok=1 why=""
  [ "$INIT_RC" = 0 ] || { ok=0; why="$why rc=$INIT_RC;"; }
  [[ "$r" == *"$IMAGE"* ]] || { ok=0; why="$why image;"; }
  [[ "$r" == *"-hf $DEFAULT_MODEL"* ]] || { ok=0; why="$why -hf default model;"; }
  [[ "$r" =~ 8080:8080 ]] || { ok=0; why="$why port 8080;"; }
  [[ "$r" == *".cache/llama.cpp"* ]] || { ok=0; why="$why cache volume;"; }
  [ "$ok" = 1 ] && pass "ac1: init starts $IMAGE -hf $DEFAULT_MODEL, :8080, ~/.cache/llama.cpp" || fail "ac1:$why docker run: '$r' out: $(echo "$INIT_OUT" | tail -3)"
}
test_ac1_model_override_via_hf() {
  run_init "${LOCAL_ON}SYSTEM1_MODEL=example/other-GGUF\n"
  local r; r=$(runs | head -1)
  [[ "$r" == *"-hf example/other-GGUF"* && "$r" != *"$DEFAULT_MODEL"* ]] && pass "ac1: SYSTEM1_MODEL passed to -hf" || fail "ac1: override not used: '$r'"
}
test_ac1_no_docker_model_needed() {
  run_init "$LOCAL_ON"   # stub `docker model` always fails: init must still succeed and never use it
  if [ "$INIT_RC" = 0 ] && ! grep -qE '^docker model' "$DLOG" && ! grep -qiE 'model runner' <<<"$INIT_OUT"; then
    pass "ac1: DMR unavailable, init succeeds and never calls docker model"
  else fail "ac1: rc=$INIT_RC docker model calls: $(grep -E '^docker model' "$DLOG" | tr '\n' '|') out: $(echo "$INIT_OUT" | tail -3)"; fi
}
test_ac1_reuses_running_container() {
  run_init "$LOCAL_ON"; local rc1=$INIT_RC
  rerun_init
  local n; n=$(runs | wc -l | tr -d ' ')
  [ "$rc1" = 0 ] && [ "$INIT_RC" = 0 ] && [ "$n" -le 1 ] && pass "ac1: second init reuses running container (docker run x$n, rc 0)" \
    || fail "ac1: rc1=$rc1 rc2=$INIT_RC docker run count=$n out: $(echo "$INIT_OUT" | tail -3)"
}
test_ac1_container_start_failure_is_clear() {
  DOCKER_FAIL_RUN=1; export DOCKER_FAIL_RUN
  run_init "$LOCAL_ON"; unset DOCKER_FAIL_RUN
  [ "$INIT_RC" != 0 ] && grep -qiE 'system ?1|llama' <<<"$INIT_OUT" && grep -qiE 'fail|error|could not|cannot' <<<"$INIT_OUT" \
    && pass "ac1: docker run failure -> non-zero exit with a clear System 1/llama.cpp message" || fail "ac1: rc=$INIT_RC out: $(echo "$INIT_OUT" | tail -4)"
}

# ---------- AC6 (init half) ----------
test_ac6_init_no_container_when_disabled() {
  local c
  for c in "" "SYSTEM1_ENABLED=0\nSYSTEM1_LOCAL=1\n" "SYSTEM1_LOCAL=1\n" "SYSTEM1_ENABLED=1\n"; do
    run_init "$c"
    if [ "$INIT_RC" = 0 ] && ! grep -qE '^docker (run|model)' "$DLOG" && ! grep -q 'llama' "$DLOG"; then pass "ac6: init with '$(printf '%b' "$c" | tr '\n' ' ')' starts no System 1 container"
    else fail "ac6: rc=$INIT_RC docker activity: $(grep -E '^docker (run|model)' "$DLOG" | tr '\n' '|')"; fi
  done
}

# ============ fake llama.cpp server + script harnesses ============
cat > "$TMP/server.py" <<'PY'
import http.server, json, os, time
d = os.environ["S1_DIR"]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() or ""
        with open(d + "/requests.log", "a") as f:
            f.write(json.dumps({"method": "POST", "path": self.path, "auth": self.headers.get("Authorization", ""), "body": body}) + "\n")
        mode = open(d + "/mode").read().strip()
        if mode == "hang": time.sleep(60); return
        if mode == "http500":
            self.send_response(500); self.end_headers(); self.wfile.write(b"boom"); return
        out = open(d + "/reply").read()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(out.encode())
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(d + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY

cat > "$TMP/stubs/bd" <<'STUB'
#!/usr/bin/env bash
echo "bd $*" >> "$W/bdlog"
F="$W/issues.json"
edit() { jq "$@" "$F" > "$F.tmp" && mv "$F.tmp" "$F"; }
flagval() { local f=$1; shift; local a=("$@"); for ((i=0;i<${#a[@]};i++)); do [ "${a[$i]}" = "$f" ] && { echo "${a[$((i+1))]}"; return; }; done; }
case "$1" in
  ready|list)
    label=$(flagval --label "$@")
    if [ -n "$label" ]; then jq -c --arg l "$label" '[.[] | select((.labels // []) | index($l))]' "$F"; else cat "$F"; fi ;;
  blocked) echo '[]' ;;
  show) jq -c --arg id "$2" '[.[] | select(.id == $id)]' "$F" ;;
  update)
    id=$2; shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --claim) edit --arg id "$id" '(.[]|select(.id==$id)) |= (.status="in_progress")' ;;
        --assignee) edit --arg id "$id" --arg v "$2" '(.[]|select(.id==$id)) |= (.assignee=$v)'; shift ;;
        --status) edit --arg id "$id" --arg v "$2" '(.[]|select(.id==$id)) |= (.status=$v)'; shift ;;
        --append-notes) edit --arg id "$id" --arg v "$2" '(.[]|select(.id==$id)) |= (.notes=((.notes // "") + $v + "\n"))'; shift ;;
      esac; shift
    done ;;
  label)
    sub=$2; id=$3; shift 3
    for l in "$@"; do
      if [ "$sub" = add ]; then edit --arg id "$id" --arg v "$l" '(.[]|select(.id==$id)) |= (.labels=((.labels//[])+[$v]|unique))'
      else edit --arg id "$id" --arg v "$l" '(.[]|select(.id==$id)) |= (.labels=((.labels//[])-[$v]))'; fi
    done ;;
  comment|comments)
    [ "$1" = comments ] && [ "$2" = add ] && shift
    edit --arg id "$2" --arg v "$3" '(.[]|select(.id==$id)) |= (.comments=((.comments//[])+[$v]))' ;;
  unclaim) edit --arg id "$2" '(.[]|select(.id==$id)) |= (.assignee="" | .status="open")' ;;
  close) edit --arg id "$2" '(.[]|select(.id==$id)) |= (.status="closed")' ;;
esac
exit 0
STUB
cat > "$TMP/stubs/claude" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$W/claude_args"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0}'
touch "$W/data/control/STOP"
exit 0
STUB
chmod +x "$TMP/stubs/bd" "$TMP/stubs/claude"

ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN"
git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

cat > "$TMP/route.json" <<'JSON'
[{"id":"t-1","title":"fix widget ISSUE-MARKER-y330","description":"Widget is broken","status":"open","assignee":"","labels":["role:engineer","stage:implement","story:story-x","needs-team-lead"],"notes":"stuck"}]
JSON
cat > "$TMP/intake.json" <<'JSON'
[{"id":"t-1","title":"new thing ISSUE-MARKER-y330","description":"Please add a thing","status":"open","assignee":"","labels":[],"notes":""}]
JSON
cat > "$TMP/eng.json" <<'JSON'
[{"id":"t-1","title":"story-x: implement widget","description":"Implement the widget. ISSUE-MARKER-y330","status":"open","assignee":"","labels":["role:engineer","stage:implement","story:story-x"]}]
JSON

# fat OBJECT-JSON -> reply carrying the decision at top level, under wrapper keys, and chat-style
fat() { jq -nc --argjson o "$1" '$o + {answers:$o, result:$o, response:$o, output:$o, choices:[{index:0,finish_reason:"stop",message:{role:"assistant",content:($o|tojson)}}]}'; }
ROUTE_REPLY='{"decision":"route","role":"architect","stage":"design","reason":"needs design"}'
PO_REPLY='{"decision":"po","reason":"needs a story"}'
cls() { printf '{"class":"%s","model_class":"%s","complexity":"%s","decision":"%s","reason":"r"}' "$1" "$1" "$1" "$1"; }

# start_server MODE REPLYOBJ -> sets W, S1URL(host:port), launches server
start_server() {
  W="$(mktemp -d "$TMP/run.XXXXXX")"; mkdir -p "$W/data/control" "$W/home" "$W/s1"
  : > "$W/bdlog"; : > "$W/claude_args"; : > "$W/s1/requests.log"
  echo "$1" > "$W/s1/mode"
  if [ "${3:-}" = raw ]; then printf '%s' "$2" > "$W/s1/reply"; else fat "$2" > "$W/s1/reply"; fi
  S1_DIR="$W/s1" python3 "$TMP/server.py" & SRV=$!
  for _ in $(seq 50); do [ -s "$W/s1/port" ] && break; sleep 0.1; done
  HOSTPORT="127.0.0.1:$(cat "$W/s1/port")"
}
stop_server() { kill "${SRV:-}" 2>/dev/null; wait "${SRV:-}" 2>/dev/null; SRV=""; }
last_req() { tail -1 "$W/s1/requests.log"; }
nreq() { wc -l < "$W/s1/requests.log" | tr -d ' '; }
req_path() { last_req | jq -r '.path'; }
has_label() { jq -e --arg l "$1" '.[] | select(.id == "t-1") | (.labels // []) | index($l)' "$W/issues.json" >/dev/null; }

# run_s1 FIXTURE [env assignments] ; needs W prepared by start_server (or W created for unreachable)
run_s1() {
  local fixture=$1; shift
  cp "$fixture" "$W/issues.json"
  local r="$W/repo"; rm -rf "$r"; git clone -q "$ORIGIN" "$r" 2>/dev/null
  S1_RC=0
  ( export W SYSTEM1_ENABLED=1 SYSTEM1_MODEL=fake-s1 SYSTEM1_TIMEOUT=3 REPO="$r" KIT_DIR="$KIT_DIR"
    unset SYSTEM1_URL SYSTEM1_API_KEY
    [ $# -gt 0 ] && export "$@"
    PATH="$TMP/stubs:$PATH" bash "$KIT_DIR/bin/system1.sh" t-1 >"$W/s1.out" 2>&1 ) || S1_RC=$?
}
run_class() {  # run_class FIXTURE [env] -> CLS_OUT CLS_RC
  local fixture=$1; shift
  cp "$fixture" "$W/issues.json"
  CLS_RC=0
  CLS_OUT=$( export W SYSTEM1_ENABLED=1 SYSTEM1_MODEL=fake-s1 SYSTEM1_TIMEOUT=3
    unset SYSTEM1_URL SYSTEM1_API_KEY
    [ $# -gt 0 ] && export "$@"
    PATH="$TMP/stubs:$PATH" bash "$KIT_DIR/bin/system1-class.sh" t-1 2>/dev/null ) || CLS_RC=$?
}

# ---------- AC2 ----------
test_ac2_system1_posts_to_systemone() {
  start_server ok "$ROUTE_REPLY"
  run_s1 "$TMP/route.json" SYSTEM1_URL="http://$HOSTPORT"
  local p; p=$(req_path); local m; m=$(last_req | jq -r '.method')
  stop_server
  [[ "$p" == */v1/systemone ]] && [[ "$p" != *chat/completions* ]] && [ "$m" = POST ] \
    && pass "ac2: system1.sh POSTs to $p" || fail "ac2: method=$m path='$p' (want POST .../v1/systemone), out: $(cat "$W/s1.out" | tail -3)"
}
test_ac2_body_is_systemone_shaped() {
  start_server ok "$ROUTE_REPLY"
  run_s1 "$TMP/route.json" SYSTEM1_URL="http://$HOSTPORT"
  local b; b=$(last_req | jq -r '.body'); stop_server
  if jq -e '(.model=="fake-s1") and has("state") and has("questions")' <<<"$b" >/dev/null 2>&1 && grep -q "ISSUE-MARKER-y330" <<<"$b"; then
    pass "ac2: body has model, state, questions and carries the issue details"
  else fail "ac2: body not systemone shaped / lacks issue: $(echo "$b" | head -c 300)"; fi
}
test_ac2_route_decision_applied() {
  start_server ok "$ROUTE_REPLY"
  run_s1 "$TMP/route.json" SYSTEM1_URL="http://$HOSTPORT"; stop_server
  if has_label role:architect && has_label stage:design && ! has_label role:engineer && ! has_label needs-human; then pass "ac2: route decision from response applied (role:architect stage:design)"
  else fail "ac2: labels after route: $(jq -c '.[0].labels' "$W/issues.json") out: $(tail -3 "$W/s1.out")"; fi
}
test_ac2_intake_po_decision_applied() {
  start_server ok "$PO_REPLY"
  run_s1 "$TMP/intake.json" SYSTEM1_URL="http://$HOSTPORT"; stop_server
  has_label role:po && ! has_label needs-human && pass "ac2: intake 'po' decision from response applied" || fail "ac2: labels: $(jq -c '.[0].labels' "$W/issues.json")"
}
test_ac2_human_decision_applied() {
  start_server ok '{"decision":"human","reason":"unclear"}'
  run_s1 "$TMP/route.json" SYSTEM1_URL="http://$HOSTPORT"; stop_server
  has_label needs-human && pass "ac2: human decision -> needs-human" || fail "ac2: labels: $(jq -c '.[0].labels' "$W/issues.json")"
}
test_ac2_default_url_targets_llamacpp_port_8080() {
  # No SYSTEM1_URL: the default must point at llama.cpp on port 8080 and end in /v1/systemone.
  local f ok=1
  for f in bin/system1.sh bin/system1-class.sh; do
    grep -E '^SYSTEM1_URL=' "$f" | grep -q ':8080' || { ok=0; echo "  $f default URL lacks :8080: $(grep -E '^SYSTEM1_URL=' "$f")"; }
    grep -E '^SYSTEM1_URL=' "$f" | grep -q '12434' && { ok=0; echo "  $f still defaults to DMR port 12434"; }
  done
  [ "$ok" = 1 ] && pass "ac2: scripts default SYSTEM1_URL to llama.cpp :8080" || fail "ac2: default URL wrong"
}

# ---------- AC3 ----------
test_ac3_class_posts_to_systemone_and_yields_class() {
  local c want got p
  for c in high medium low; do
    start_server ok "$(cls $c)"
    run_class "$TMP/eng.json" SYSTEM1_URL="http://$HOSTPORT"
    p=$(req_path); got=$CLS_OUT; stop_server
    [[ "$p" == */v1/systemone ]] && [ "$got" = "$c" ] && [ "$CLS_RC" = 0 ] \
      && pass "ac3: system1-class.sh POST $p -> '$c'" || fail "ac3: class $c: path='$p' out='$got' rc=$CLS_RC"
  done
}
test_ac3_class_body_shape() {
  start_server ok "$(cls high)"
  run_class "$TMP/eng.json" SYSTEM1_URL="http://$HOSTPORT"
  local b; b=$(last_req | jq -r '.body'); stop_server
  jq -e '(.model=="fake-s1") and has("state") and has("questions")' <<<"$b" >/dev/null 2>&1 && grep -q "ISSUE-MARKER-y330" <<<"$b" \
    && pass "ac3: class request body has model/state/questions and the issue" || fail "ac3: body: $(echo "$b" | head -c 300)"
}

# run_loop ROLE FIXTURE MODE REPLYOBJ [env...] : REAL agent-loop.sh. MODE ok|http500|hang|down|off
run_loop() {
  local role=$1 fixture=$2 mode=$3 reply=$4; shift 4
  local url=""
  case "$mode" in
    ok|http500|hang) start_server "$mode" "$reply"; url="http://$HOSTPORT" ;;
    *) W="$(mktemp -d "$TMP/run.XXXXXX")"; mkdir -p "$W/data/control" "$W/home" "$W/s1"; : > "$W/bdlog"; : > "$W/claude_args"; : > "$W/s1/requests.log"
       [ "$mode" = down ] && url="http://127.0.0.1:1" ;;
  esac
  cp "$fixture" "$W/issues.json"
  ( for _ in $(seq 300); do [ -s "$W/claude_args" ] && break; sleep 0.1; done; sleep 1; touch "$W/data/control/STOP" ) & WATCH=$!
  RC=0
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home" SYSTEM1_TIMEOUT=3
    unset MODEL_HIGH MODEL_MEDIUM MODEL_LOW MODEL_ENGINEER MODEL_QA SYSTEM1_ENABLED SYSTEM1_URL SYSTEM1_MODEL SYSTEM1_API_KEY
    export MODEL_HIGH=$HI MODEL_MEDIUM=$MED MODEL_LOW=$LO
    [ $# -gt 0 ] && export "$@"
    [ "$mode" = off ] || export SYSTEM1_ENABLED=1 SYSTEM1_URL="$url" SYSTEM1_MODEL=fake-s1
    PATH="$TMP/stubs:$PATH" ROLE="$role" KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 IDLE_SLEEP=1 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 \
      timeout 60 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
  kill "$WATCH" 2>/dev/null; wait "$WATCH" 2>/dev/null; stop_server
}
model_used() { grep -oE -- '--model [^ ]+' "$W/claude_args" | head -1 | awk '{print $2}'; }

test_ac3_loop_classifies_via_systemone() {
  local c want
  for c in high low; do
    case $c in high) want=$HI;; low) want=$LO;; esac
    run_loop engineer "$TMP/eng.json" ok "$(cls $c)"
    [ "$(model_used)" = "$want" ] && [[ "$(req_path)" == */v1/systemone ]] \
      && pass "ac3: agent-loop class '$c' via /v1/systemone -> --model $want" || fail "ac3: loop class $c -> model '$(model_used)' (want $want) path '$(req_path)'"
  done
}

# ---------- AC4 ----------
test_ac4_decision_failures_go_needs_human() {
  local mode reply why
  for why in http500 hang down garbage empty; do
    case $why in
      http500) start_server http500 "$ROUTE_REPLY" ;;
      hang) start_server hang "$ROUTE_REPLY" ;;
      down) start_server ok "$ROUTE_REPLY"; stop_server; HOSTPORT="127.0.0.1:1" ;;
      garbage) start_server ok "not json at all" raw ;;
      empty) start_server ok "{}" raw ;;
    esac
    run_s1 "$TMP/route.json" SYSTEM1_URL="http://$HOSTPORT" SYSTEM1_TIMEOUT=2
    stop_server
    if has_label needs-human && ! has_label architect && jq -e '.[0].notes | test("System 1"; "i")' "$W/issues.json" >/dev/null; then pass "ac4: system1.sh $why -> needs-human with a System 1 note"
    else fail "ac4: $why: labels $(jq -c '.[0].labels' "$W/issues.json") notes $(jq -c '.[0].notes' "$W/issues.json")"; fi
  done
}
test_ac4_class_failures_exit_nonzero_empty() {
  local why
  for why in http500 down garbage empty; do
    case $why in
      http500) start_server http500 "$(cls high)" ;;
      down) start_server ok "$(cls high)"; stop_server; HOSTPORT="127.0.0.1:1" ;;
      garbage) start_server ok "not json at all" raw ;;
      empty) start_server ok "{}" raw ;;
    esac
    run_class "$TMP/eng.json" SYSTEM1_URL="http://$HOSTPORT"; stop_server
    [ "$CLS_RC" != 0 ] && [ -z "$CLS_OUT" ] && pass "ac4: system1-class.sh $why -> exit non-zero, no class on stdout" || fail "ac4: $why rc=$CLS_RC out='$CLS_OUT'"
  done
}
test_ac4_loop_falls_back_to_medium() {
  local why
  for why in http500 down garbage; do
    case $why in
      http500) run_loop engineer "$TMP/eng.json" http500 "$(cls high)" ;;
      down) run_loop engineer "$TMP/eng.json" down "" ;;
      garbage) run_loop engineer "$TMP/eng.json" ok '{"nothing":"useful"}' ;;
    esac
    [ "$(model_used)" = "$MED" ] && ! has_label needs-human && pass "ac4: loop classification $why -> MODEL_MEDIUM, not needs-human" || fail "ac4: loop $why -> model '$(model_used)' want $MED"
  done
}

# ---------- AC5 ----------
test_ac5_url_setting_selects_endpoint() {
  start_server ok "$ROUTE_REPLY"
  run_s1 "$TMP/route.json" SYSTEM1_URL="http://$HOSTPORT"
  local n1; n1=$(nreq); stop_server
  [ "$n1" -ge 1 ] && pass "ac5: system1.sh sent its request to the host:port in SYSTEM1_URL" || fail "ac5: no request reached SYSTEM1_URL server"
  start_server ok "$(cls low)"
  run_class "$TMP/eng.json" SYSTEM1_URL="http://$HOSTPORT"
  local n2; n2=$(nreq); stop_server
  [ "$n2" -ge 1 ] && pass "ac5: system1-class.sh sent its request to the host:port in SYSTEM1_URL" || fail "ac5: class request did not reach SYSTEM1_URL"
}
test_ac5_hosted_url_with_v1_not_doubled() {
  start_server ok "$ROUTE_REPLY"
  run_s1 "$TMP/route.json" SYSTEM1_URL="http://$HOSTPORT/v1"
  local p; p=$(req_path); stop_server
  [[ "$p" == */systemone ]] && [[ "$p" != */v1/v1/* ]] && [[ "$p" != *chat/completions* ]] \
    && pass "ac5: SYSTEM1_URL ending /v1 -> $p (no doubled /v1)" || fail "ac5: path '$p'"
}
test_ac5_api_key_sent() {
  start_server ok "$ROUTE_REPLY"
  run_s1 "$TMP/route.json" SYSTEM1_URL="http://$HOSTPORT" SYSTEM1_API_KEY=sekret-y330
  local a; a=$(last_req | jq -r '.auth'); stop_server
  [ "$a" = "Bearer sekret-y330" ] && pass "ac5: SYSTEM1_API_KEY sent as Bearer token (system1.sh)" || fail "ac5: auth header '$a'"
  start_server ok "$(cls low)"
  run_class "$TMP/eng.json" SYSTEM1_URL="http://$HOSTPORT" SYSTEM1_API_KEY=sekret-y330
  a=$(last_req | jq -r '.auth'); stop_server
  [ "$a" = "Bearer sekret-y330" ] && pass "ac5: SYSTEM1_API_KEY sent as Bearer token (system1-class.sh)" || fail "ac5: class auth header '$a'"
}

# ---------- AC6 (loop half) ----------
test_ac6_loop_disabled_makes_no_request() {
  start_server ok "$(cls high)"
  cp "$TMP/eng.json" "$W/issues.json"
  ( for _ in $(seq 300); do [ -s "$W/claude_args" ] && break; sleep 0.1; done; sleep 1; touch "$W/data/control/STOP" ) & local wp=$!
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home" MODEL_HIGH=$HI MODEL_MEDIUM=$MED MODEL_LOW=$LO SYSTEM1_URL="http://$HOSTPORT" SYSTEM1_MODEL=fake-s1
    unset SYSTEM1_ENABLED MODEL_ENGINEER MODEL_QA SYSTEM1_API_KEY
    PATH="$TMP/stubs:$PATH" ROLE=engineer KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 IDLE_SLEEP=1 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 timeout 60 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || true
  kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
  local n; n=$(nreq); stop_server
  [ "$n" = 0 ] && [ "$(model_used)" = "$MED" ] && pass "ac6: SYSTEM1_ENABLED unset -> zero System 1 requests, MODEL_MEDIUM" || fail "ac6: requests=$n model='$(model_used)'"
}

# ---------- AC7 ----------
test_ac7_docs_describe_llamacpp_systemone() {
  local ok=1 f
  grep -qi 'systemone' docs/ARCHITECTURE.md && grep -qi 'llama\.cpp' docs/ARCHITECTURE.md && grep -q 'server-cuda' docs/ARCHITECTURE.md || { ok=0; echo "  ARCHITECTURE.md lacks llama.cpp / systemone / server-cuda"; }
  for f in README.md .env.example; do
    grep -qi 'llama\.cpp' "$f" && grep -q '/v1/systemone' "$f" || { ok=0; echo "  $f lacks llama.cpp or /v1/systemone"; }
  done
  [ "$ok" = 1 ] && pass "ac7: ARCHITECTURE/README/.env.example describe llama.cpp + /v1/systemone" || fail "ac7: docs incomplete"
}
test_ac7_no_dmr_references() {
  local hits f
  hits=$(for f in README.md .env.example docs/ARCHITECTURE.md docker-compose.yml bin; do grep -rnIE -i '12434|docker model|model runner|engines/v1' "$f" 2>/dev/null | sed "s#^#$f: #"; done)
  [ -z "$hits" ] && pass "ac7: no Docker Model Runner / port 12434 / engines/v1 references in docs, bin, compose" || fail "ac7: stale DMR references:
$(echo "$hits" | head -10)"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
