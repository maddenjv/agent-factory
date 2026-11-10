#!/usr/bin/env bash
# Acceptance tests for agent-factory-hcql: per-task model class selection via System 1.
# Derived ONLY from docs/stories/agent-factory-hcql.md (test_acN_...). Assumed interfaces (the story
# leaves them open; adjust the constants here, not the assertions, if the design differs):
#   - env: MODEL_HIGH / MODEL_MEDIUM / MODEL_LOW, MODEL_<ROLE> pin, SYSTEM1_ENABLED/URL/MODEL
#   - System 1 reply (choices[0].message.content) is a JSON object carrying the class under several
#     plausible keys; a bare word is also tested (CLASS_JSON / the "plain" test).
#   - The model reaches the harness as `--model <name>` on the stub `claude` command line.
#   - The loop log is $DATA_DIR/logs/<role>/loop.log (also echoed to stdout).
# Harness: REAL bin/agent-loop.sh (ROLE=engineer unless noted) against a stub bd, a stub claude that
# records its args, and a local fake OpenAI-compatible server (python3).
# Run directly: bash tests/agent-factory-hcql_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
HI=m-high-hcql; MED=m-medium-hcql; LO=m-low-hcql; PIN=m-pin-hcql

TMP="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"
if ! command -v python3 >/dev/null; then echo "SKIP: python3 missing"; exit 0; fi

cat > "$TMP/server.py" <<'PY'
import http.server, json, os, time
d = os.environ["S1_DIR"]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() or "{}"
        with open(d + "/requests.log", "a") as f: f.write(body.replace("\n", " ") + "\n")
        mode = open(d + "/mode").read().strip()
        if mode == "hang": time.sleep(60); return
        if mode == "http500":
            self.send_response(500); self.end_headers(); self.wfile.write(b"boom"); return
        content = open(d + "/reply").read()
        out = json.dumps({"id": "x", "object": "chat.completion", "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": content}}]})
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
chmod +x "$TMP/stubs/"*

ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN"
git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

cat > "$TMP/eng.json" <<'JSON'
[{"id":"t-1","title":"story-x: implement widget","description":"Implement the widget. ISSUE-MARKER-hcql","status":"open","assignee":"","labels":["role:engineer","stage:implement","story:story-x"]}]
JSON
sed 's/role:engineer/role:qa/; s/stage:implement/stage:verify/' "$TMP/eng.json" > "$TMP/qa.json"

# run_loop ROLE FIXTURE MODE REPLY [env assignments...]
# MODE: ok|http500|hang|down (System 1 enabled, various server behaviour) | off (not enabled)
# | unconfigured (enabled flag but empty URL). Sets W, RC.
run_loop() {
  local role=$1 fixture=$2 mode=$3 reply=$4; shift 4
  W="$(mktemp -d "$TMP/run.XXXXXX")"; mkdir -p "$W/data/control" "$W/home" "$W/s1"
  : > "$W/bdlog"; : > "$W/claude_args"; : > "$W/s1/requests.log"
  cp "$fixture" "$W/issues.json"
  local url=""
  case "$mode" in
    ok|http500|hang)
      echo "$mode" > "$W/s1/mode"; printf '%s' "$reply" > "$W/s1/reply"
      S1_DIR="$W/s1" python3 "$TMP/server.py" & SRV=$!
      for _ in $(seq 50); do [ -s "$W/s1/port" ] && break; sleep 0.1; done
      url="http://127.0.0.1:$(cat "$W/s1/port")/v1" ;;
    down) url="http://127.0.0.1:1/v1" ;;
  esac
  ( for _ in $(seq 300); do [ -s "$W/claude_args" ] && break; sleep 0.1; done; sleep 1; touch "$W/data/control/STOP" ) & WATCH=$!
  RC=0
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home" SYSTEM1_TIMEOUT=3
    unset MODEL_HIGH MODEL_MEDIUM MODEL_LOW MODEL_ENGINEER MODEL_QA SYSTEM1_ENABLED SYSTEM1_URL SYSTEM1_MODEL
    [ $# -gt 0 ] && export "$@"
    case "$mode" in
      off) ;;
      unconfigured) export SYSTEM1_ENABLED=1 SYSTEM1_URL= ;;
      *) export SYSTEM1_ENABLED=1 SYSTEM1_URL="$url" SYSTEM1_MODEL=fake-s1 ;;
    esac
    PATH="$TMP/stubs:$PATH" ROLE="$role" KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 IDLE_SLEEP=1 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 \
      timeout 60 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
  kill "$WATCH" "${SRV:-}" 2>/dev/null; wait "$WATCH" "${SRV:-}" 2>/dev/null; SRV=""
}
model_used() { grep -oE -- '--model [^ ]+' "$W/claude_args" | head -1 | awk '{print $2}'; }
requests() { wc -l < "$W/s1/requests.log" | tr -d ' '; }
loglines() { cat "$W/out" "$W/data/logs"/*/loop.log 2>/dev/null; }
has_label() { jq -e --arg l "$1" '.[] | select(.id == "t-1") | (.labels // []) | index($l)' "$W/issues.json" >/dev/null; }
CLASSES="MODEL_HIGH=$HI MODEL_MEDIUM=$MED MODEL_LOW=$LO"
cls() { printf '{"class":"%s","model_class":"%s","complexity":"%s","decision":"%s","reason":"r"}' "$1" "$1" "$1" "$1"; }

# ---------- AC1 ----------
test_ac1_each_class_selects_its_model() {
  local c want got
  for c in high medium low; do
    case $c in high) want=$HI;; medium) want=$MED;; low) want=$LO;; esac
    run_loop engineer "$TMP/eng.json" ok "$(cls $c)" $CLASSES
    got=$(model_used)
    [ "$got" = "$want" ] && [ "$(requests)" -ge 1 ] \
      && pass "ac1: System 1 says $c -> --model $want (engineer)" \
      || fail "ac1: System 1 says $c -> model '$got' (want $want), s1 requests=$(requests). out: $(tail -5 "$W/out")"
  done
}
test_ac1_other_role_qa() {
  run_loop qa "$TMP/qa.json" ok "$(cls low)" $CLASSES
  [ "$(model_used)" = "$LO" ] && pass "ac1: qa role also gets class model (low)" || fail "ac1: qa got '$(model_used)' want $LO"
}
test_ac1_plain_word_answer() {
  run_loop engineer "$TMP/eng.json" ok "high" $CLASSES
  [ "$(model_used)" = "$HI" ] && pass "ac1: bare word 'high' accepted" || fail "ac1: bare 'high' -> '$(model_used)' want $HI"
}
test_ac1_request_carries_issue() {
  run_loop engineer "$TMP/eng.json" ok "$(cls high)" $CLASSES
  grep -q "ISSUE-MARKER-hcql" "$W/s1/requests.log" && grep -q "role:engineer" "$W/s1/requests.log" \
    && pass "ac1: System 1 request carries the issue description and labels" || fail "ac1: request lacks issue description/labels"
}

# ---------- AC2 ----------
test_ac2_disabled_uses_medium_no_request() {
  run_loop engineer "$TMP/eng.json" off "" $CLASSES
  [ "$(model_used)" = "$MED" ] && [ "$(requests)" = 0 ] \
    && pass "ac2: System 1 off -> MODEL_MEDIUM, no request" || fail "ac2: off -> '$(model_used)' (want $MED), requests=$(requests)"
}
test_ac2_enabled_but_unconfigured_uses_medium() {
  run_loop engineer "$TMP/eng.json" unconfigured "" $CLASSES
  [ "$(model_used)" = "$MED" ] && ! has_label needs-human \
    && pass "ac2: enabled but not configured -> MODEL_MEDIUM" || fail "ac2: unconfigured -> '$(model_used)' (want $MED)"
}

# ---------- AC3 ----------
check_fallback() {  # check_fallback DESC
  local ok=1 why=""
  [ "$(model_used)" = "$MED" ] || { ok=0; why="$why model '$(model_used)' want $MED;"; }
  has_label needs-human && { ok=0; why="$why needs-human set;"; }
  loglines | grep -iE 'fallback|fall(ing)? back' | grep -q "t-1" || { ok=0; why="$why log lacks fallback line naming t-1;"; }
  [ "$ok" = 1 ] && pass "ac3: $1 -> MODEL_MEDIUM, fallback logged, not needs-human" || fail "ac3: $1:$why"
}
test_ac3_unreachable() { run_loop engineer "$TMP/eng.json" down "" $CLASSES; check_fallback "System 1 unreachable"; }
test_ac3_http_error() { run_loop engineer "$TMP/eng.json" http500 "" $CLASSES; check_fallback "HTTP 500"; }
test_ac3_timeout() { run_loop engineer "$TMP/eng.json" hang "" $CLASSES SYSTEM1_TIMEOUT=2; check_fallback "timeout"; }
test_ac3_garbage_answer() { run_loop engineer "$TMP/eng.json" ok "I would say it is quite hard" $CLASSES; check_fallback "non-class answer"; }
test_ac3_unknown_class_value() { run_loop engineer "$TMP/eng.json" ok "$(cls extreme)" $CLASSES; check_fallback "class 'extreme'"; }
test_ac3_fallback_reason_logged() {
  run_loop engineer "$TMP/eng.json" http500 "" $CLASSES
  loglines | grep -iE 'fall' | grep -qiE '500|http|fail|error|unreach|reason' \
    && pass "ac3: fallback log line includes a reason" || fail "ac3: no reason in fallback log: $(loglines | grep -i fall)"
}

# ---------- AC4 ----------
test_ac4_chosen_class_var_empty_uses_role_default() {
  run_loop engineer "$TMP/eng.json" ok "$(cls high)" MODEL_MEDIUM=$MED MODEL_LOW=$LO
  local m; m=$(model_used)
  [ "$m" != "$MED" ] && [ "$m" != "$LO" ] && [ "$(requests)" -ge 1 ] \
    && loglines | grep -qiE 'default' \
    && pass "ac4: MODEL_HIGH empty -> role default ('${m:-<none>}'), log says so" || fail "ac4: got '$m'; log: $(loglines | grep -i model | tail -3)"
}
test_ac4_role_default_is_existing_tier() {
  run_loop engineer "$TMP/eng.json" ok "$(cls high)" MODEL_MEDIUM=$MED
  [ "$(model_used)" = sonnet ] && pass "ac4: empty class var -> existing engineer default (sonnet)" || fail "ac4: got '$(model_used)' want sonnet"
}
test_ac4_medium_empty_on_fallback_path() {
  run_loop engineer "$TMP/eng.json" off "" MODEL_HIGH=$HI MODEL_LOW=$LO
  [ "$(model_used)" = sonnet ] && loglines | grep -qiE 'default' \
    && pass "ac4: MODEL_MEDIUM empty on fallback path -> role default, log says so" || fail "ac4: got '$(model_used)'"
}

# ---------- AC5 ----------
test_ac5_role_pin_wins_without_consulting_system1() {
  run_loop engineer "$TMP/eng.json" ok "$(cls high)" $CLASSES MODEL_ENGINEER=$PIN
  [ "$(model_used)" = "$PIN" ] && [ "$(requests)" = 0 ] \
    && pass "ac5: MODEL_ENGINEER pin wins, System 1 not consulted" || fail "ac5: got '$(model_used)' requests=$(requests)"
}

# ---------- AC6 ----------
test_ac6_log_records_issue_class_source_model() {
  run_loop engineer "$TMP/eng.json" ok "$(cls low)" $CLASSES
  local l; l=$(loglines | grep 't-1' | grep "$LO" | grep -i 'low' | grep -iE 'system ?1|system1')
  [ -n "$l" ] && pass "ac6: log line has issue id, class, System 1 source, model" || fail "ac6: no such line; log: $(loglines | grep -E "$LO|t-1" | head -5)"
}
test_ac6_fallback_line_has_fields() {
  run_loop engineer "$TMP/eng.json" http500 "" $CLASSES
  local l; l=$(loglines | grep 't-1' | grep "$MED" | grep -i 'medium' | grep -iE 'fall')
  [ -n "$l" ] && pass "ac6: fallback log line has issue id, class medium, fallback source, model" || fail "ac6: no such line; log: $(loglines | grep -E "$MED|t-1" | head -5)"
}

# ---------- AC7 ----------
test_ac7_nothing_set_unchanged() {
  run_loop engineer "$TMP/eng.json" off ""
  [ "$(model_used)" = sonnet ] && [ "$(requests)" = 0 ] && pass "ac7: no new vars, S1 off -> engineer default sonnet, no request" || fail "ac7: got '$(model_used)'"
  run_loop engineer "$TMP/eng.json" off "" MODEL_ENGINEER=$PIN
  [ "$(model_used)" = "$PIN" ] && pass "ac7: existing MODEL_ENGINEER still honoured" || fail "ac7: pin got '$(model_used)'"
}
test_ac7_s1_enabled_no_class_vars_unchanged() {
  run_loop engineer "$TMP/eng.json" ok "$(cls high)"
  [ "$(model_used)" = sonnet ] && pass "ac7: S1 on but no class vars -> role default" || fail "ac7: got '$(model_used)'"
}

# ---------- AC8 ----------
test_ac8_env_example_documents() {
  local v ok=1
  for v in MODEL_HIGH MODEL_MEDIUM MODEL_LOW; do grep -q "$v" .env.example || { ok=0; echo "  .env.example lacks $v"; }; done
  grep -iE 'fall' .env.example | grep -qiE 'MODEL_MEDIUM|medium' || { ok=0; echo "  .env.example lacks fallback rule"; }
  [ "$ok" = 1 ] && pass "ac8: .env.example documents classes and fallback" || fail "ac8: .env.example incomplete"
}
test_ac8_readme_and_architecture_mention() {
  local ok=1 f
  for f in README.md docs/ARCHITECTURE.md; do
    grep -q 'MODEL_HIGH' "$f" && grep -q 'MODEL_LOW' "$f" || { ok=0; echo "  $f lacks MODEL_HIGH/MODEL_LOW"; }
  done
  [ "$ok" = 1 ] && pass "ac8: README and ARCHITECTURE mention the model-class decision" || fail "ac8: docs incomplete"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
