#!/usr/bin/env bash
# Acceptance tests for agent-factory-is2h: model hierarchy System 1 > MODEL_<ROLE> > MODEL_MEDIUM > role default.
# Derived ONLY from docs/stories/agent-factory-is2h.md (test_acN_...). Harness copied from the hcql test:
# REAL bin/agent-loop.sh (ROLE=engineer) against stub bd, stub claude (records `--model X`) and a fake
# /v1/systemone server. Run directly: bash tests/agent-factory-is2h_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
HI=m-high-is2h; MED=m-med-is2h; LO=m-low-is2h; PIN=m-pin-is2h

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
        # y330 contract: serve a /v1/systemone typed-choice answer (id "class")
        try: choice = json.loads(content)["class"]
        except Exception: choice = content.strip() if content.strip() in ("high", "medium", "low") else "banana"
        if "not-an-answer" in content or content.startswith("I would"): out = json.dumps({"answers": {}, "usage": {}})
        else: out = json.dumps({"answers": {"class": {"choice": choice, "confidence": 0.9, "probabilities": {}}}, "usage": {}})
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
[{"id":"t-1","title":"story-x: implement widget","description":"Implement the widget. ISSUE-MARKER-is2h","status":"open","assignee":"","labels":["role:engineer","stage:implement","story:story-x"]}]
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
    unset MODEL_HIGH MODEL_MEDIUM MODEL_LOW MODEL_ENGINEER MODEL_QA MODEL_TEAM_LEAD SYSTEM1_ENABLED SYSTEM1_URL SYSTEM1_MODEL
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


PINNED="MODEL_ENGINEER=$PIN"
modelline() { loglines | grep -E 'model:.*t-1' | tail -1; }

# ---------- AC1: valid System 1 class beats MODEL_<ROLE> ----------
test_ac1_system1_class_beats_role_pin() {
  local c want got
  for c in high medium low; do
    case $c in high) want=$HI;; medium) want=$MED;; low) want=$LO;; esac
    run_loop engineer "$TMP/eng.json" ok "$(cls $c)" $CLASSES $PINNED
    got=$(model_used)
    [ "$got" = "$want" ] && [ "$(requests)" -ge 1 ] \
      && pass "ac1: S1 says $c with MODEL_ENGINEER set -> $want" \
      || fail "ac1: S1 says $c -> '$got' (want $want), requests=$(requests)"
  done
}

# ---------- AC2: S1 unusable -> MODEL_<ROLE> ----------
check_pin_fallback() {  # $1 label
  local got; got=$(model_used)
  [ "$got" = "$PIN" ] && pass "ac2: $1 -> MODEL_ENGINEER" || fail "ac2: $1 -> '$got' (want $PIN); log: $(loglines | grep -i model | tail -3)"
}
test_ac2_pin_when_system1_fails() {
  run_loop engineer "$TMP/eng.json" http500 "" $CLASSES $PINNED; check_pin_fallback "S1 http error"
  run_loop engineer "$TMP/eng.json" hang "" $CLASSES $PINNED SYSTEM1_TIMEOUT=2; check_pin_fallback "S1 timeout"
  run_loop engineer "$TMP/eng.json" down "" $CLASSES $PINNED; check_pin_fallback "S1 unreachable"
  run_loop engineer "$TMP/eng.json" ok "banana" $CLASSES $PINNED; check_pin_fallback "S1 invalid class"
}
test_ac2_pin_when_class_var_empty() {
  run_loop engineer "$TMP/eng.json" ok "$(cls high)" MODEL_MEDIUM=$MED MODEL_LOW=$LO $PINNED
  check_pin_fallback "S1 says high but MODEL_HIGH empty (MODEL_MEDIUM set)"
  run_loop engineer "$TMP/eng.json" ok "$(cls low)" MODEL_HIGH=$HI $PINNED
  check_pin_fallback "S1 says low but MODEL_LOW empty, no MODEL_MEDIUM"
}

# ---------- AC3: S1 disabled -> MODEL_<ROLE>, no request ----------
test_ac3_disabled_uses_pin_no_request() {
  run_loop engineer "$TMP/eng.json" off "" $CLASSES $PINNED
  [ "$(model_used)" = "$PIN" ] && [ "$(requests)" = 0 ] \
    && pass "ac3: S1 disabled -> MODEL_ENGINEER, no S1 request" \
    || fail "ac3: got '$(model_used)' requests=$(requests)"
  run_loop engineer "$TMP/eng.json" off "" $PINNED
  [ "$(model_used)" = "$PIN" ] && [ "$(requests)" = 0 ] \
    && pass "ac3: S1 disabled, no class vars -> MODEL_ENGINEER, no request" \
    || fail "ac3: (no class vars) got '$(model_used)' requests=$(requests)"
}

# ---------- AC4: MODEL_MEDIUM fallback ----------
test_ac4_model_medium_fallback() {
  local mode
  run_loop engineer "$TMP/eng.json" off "" $CLASSES
  [ "$(model_used)" = "$MED" ] && pass "ac4: S1 disabled, no pin -> MODEL_MEDIUM" || fail "ac4: disabled -> '$(model_used)' (want $MED)"
  run_loop engineer "$TMP/eng.json" off "" MODEL_MEDIUM=$MED
  [ "$(model_used)" = "$MED" ] && pass "ac4: only MODEL_MEDIUM set, S1 disabled -> MODEL_MEDIUM" || fail "ac4: only-medium -> '$(model_used)'"
  run_loop engineer "$TMP/eng.json" http500 "" $CLASSES
  [ "$(model_used)" = "$MED" ] && pass "ac4: S1 error, no pin -> MODEL_MEDIUM" || fail "ac4: s1 error -> '$(model_used)'"
  run_loop engineer "$TMP/eng.json" ok "banana" $CLASSES
  [ "$(model_used)" = "$MED" ] && pass "ac4: S1 invalid class, no pin -> MODEL_MEDIUM" || fail "ac4: invalid -> '$(model_used)'"
  run_loop engineer "$TMP/eng.json" ok "$(cls high)" MODEL_MEDIUM=$MED MODEL_LOW=$LO
  [ "$(model_used)" = "$MED" ] && pass "ac4: S1 says high, MODEL_HIGH empty, no pin -> MODEL_MEDIUM" || fail "ac4: high-empty -> '$(model_used)'"
}

# ---------- AC5: role default ----------
test_ac5_role_default() {
  run_loop engineer "$TMP/eng.json" off ""
  [ "$(model_used)" = sonnet ] && [ "$(requests)" = 0 ] && pass "ac5: nothing set -> engineer tier default (sonnet)" || fail "ac5: nothing set -> '$(model_used)'"
  run_loop engineer "$TMP/eng.json" ok "$(cls high)" 
  [ "$(model_used)" = sonnet ] && pass "ac5: S1 on, no model vars -> sonnet" || fail "ac5: s1 on, no vars -> '$(model_used)'"
  run_loop engineer "$TMP/eng.json" http500 "" MODEL_HIGH=$HI MODEL_LOW=$LO
  [ "$(model_used)" = sonnet ] && pass "ac5: S1 error, MODEL_MEDIUM empty, no pin -> sonnet" || fail "ac5: -> '$(model_used)'"
}

# ---------- AC6: log records source and fallback reason ----------
test_ac6_log_source_and_reason() {
  local l
  run_loop engineer "$TMP/eng.json" ok "$(cls low)" $CLASSES $PINNED; l=$(modelline)
  echo "$l" | grep -q "$LO" && echo "$l" | grep -qi 'system1\|system 1' && ! echo "$l" | grep -qi 'fallback' \
    && pass "ac6: System 1 source logged" || fail "ac6: S1 line: '$l'"
  run_loop engineer "$TMP/eng.json" http500 "" $CLASSES $PINNED; l=$(modelline)
  echo "$l" | grep -q "$PIN" && echo "$l" | grep -q 'MODEL_ENGINEER' && echo "$l" | grep -qi 'fallback\|system1\|system 1' \
    && pass "ac6: MODEL_<ROLE> source + system1 reason logged" || fail "ac6: pin line: '$l'"
  run_loop engineer "$TMP/eng.json" off "" $PINNED; l=$(modelline)
  echo "$l" | grep -q 'MODEL_ENGINEER' && echo "$l" | grep -qi 'disabled\|not enabled\|off' \
    && pass "ac6: pin source with 'disabled' reason logged" || fail "ac6: disabled pin line: '$l'"
  run_loop engineer "$TMP/eng.json" off "" $CLASSES; l=$(modelline)
  echo "$l" | grep -q "$MED" && echo "$l" | grep -q 'MODEL_MEDIUM' \
    && pass "ac6: MODEL_MEDIUM source logged" || fail "ac6: medium line: '$l'"
  run_loop engineer "$TMP/eng.json" off ""; l=$(modelline)
  echo "$l" | grep -qi 'default' && echo "$l" | grep -q 'sonnet' \
    && pass "ac6: role default source logged" || fail "ac6: default line: '$l'"
}

# ---------- AC7: docs ----------
test_ac7_docs_state_order() {
  local f ok=1
  for f in README.md .env.example docs/ARCHITECTURE.md; do
    grep -q 'MODEL_<ROLE>' "$f" && grep -qi 'system *1' "$f" && grep -q 'MODEL_MEDIUM' "$f" \
      || { ok=0; echo "  $f lacks MODEL_<ROLE>/System 1/MODEL_MEDIUM"; }
    # stale statements: MODEL_<ROLE> "wins" / "always wins" / skips System 1
    if grep -iE 'MODEL_<ROLE>[^.]*(wins|skips System 1|always wins)|(wins|skips System 1)[^.]*MODEL_<ROLE>' "$f" >/dev/null; then
      ok=0; echo "  $f still says MODEL_<ROLE> wins/skips System 1: $(grep -inE 'MODEL_<ROLE>[^.]*(wins|skips System 1)' "$f" | head -2)"
    fi
  done
  [ "$ok" = 1 ] && pass "ac7: README, .env.example, ARCHITECTURE state the new order" || fail "ac7: docs not updated"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
