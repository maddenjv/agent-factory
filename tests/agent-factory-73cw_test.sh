#!/usr/bin/env bash
# Acceptance tests for agent-factory-73cw: a "System 1" model makes team-lead's finite routing /
# no-story intake decisions. One or more tests per acceptance criterion in
# docs/stories/agent-factory-73cw.md (test_acN_...). Written BEFORE the implementation and from the
# story only, so every name below is an ASSUMED interface (the story leaves them open); if the design
# picks different ones, change the constants in this block - not the assertions.
#
#   SYSTEM1_FLAG  = SYSTEM1_ENABLED   (set to 1 = on; unset/empty = off)
#   SYSTEM1_URL   = SYSTEM1_URL       (OpenAI-compatible base URL, e.g. http://host:12434/engines/v1;
#                                      the client POSTs <base>/chat/completions)
#   SYSTEM1_MODEL = SYSTEM1_MODEL     (model name sent in the request body; also the model served by the
#                                      vLLM container bin/init.sh starts, default LiquidAI/d1-2B)
#   SYSTEM1_KEY   = SYSTEM1_API_KEY   (optional; sent as "Authorization: Bearer <key>")
#
# The model's answer is a JSON object in choices[0].message.content. The decision vocabulary is also
# assumed; the fake model replies with a superset of plausible keys so any reasonable schema parses:
#   route (issue with a story: label, or needs-team-lead):
#             {"decision":"route","role":"qa","stage":"verify","reason":"..."}  |  {"decision":"human","reason":"..."}
#   intake (unrouted issue with NO story: label - AC3'):
#             {"decision":"po|direct|human","reason":"..."}
# AC3 is read as AC3' per docs/design/agent-factory-73cw.md: there is no PO stage in a chain; the
# unrouted-issue intake decides po (route to po) / direct (script builds the story + full five-stage
# chain, no PO) / human. SYSTEM1_LOCAL=1 + flag => init.sh pulls the model.
#
# Harness: the REAL bin/agent-loop.sh (ROLE=team-lead) runs against a stateful stub `bd` (applies
# label/update/comment/create to a JSON fixture), a stub `claude` (records that a capable-model session
# started), and a local fake OpenAI-compatible HTTP server (python3). Docker is stubbed for AC7.
#
# Run directly: bash tests/agent-factory-73cw_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
SYSTEM1_FLAG=SYSTEM1_ENABLED; SYSTEM1_URL_VAR=SYSTEM1_URL; SYSTEM1_MODEL_VAR=SYSTEM1_MODEL; SYSTEM1_KEY_VAR=SYSTEM1_API_KEY; SYSTEM1_LOCAL_VAR=SYSTEM1_LOCAL
MODEL_NAME="d1-fake-model-73cw"
REASON="REASON-MARKER-7f3a"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stubs"

if ! command -v python3 >/dev/null; then echo "SKIP: python3 missing"; exit 0; fi

# ---------- fake OpenAI-compatible model server ----------
# Behaviour per request is read from $S1_DIR/mode: ok | garbage | badvalue | http500 | hang.
# $S1_DIR/reply holds the content string for ok. Every request is appended to $S1_DIR/requests.log
# as one JSON line {path, auth, model}.
cat > "$TMP/server.py" <<'PY'
import http.server, json, os, sys, time
d = os.environ["S1_DIR"]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() or "{}"
        try: model = json.loads(body).get("model")
        except Exception: model = None
        with open(d + "/requests.log", "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "model": model, "body": body}) + "\n")
        mode = open(d + "/mode").read().strip()
        if mode == "hang": time.sleep(60); return
        if mode == "http500":
            self.send_response(500); self.end_headers(); self.wfile.write(b"boom"); return
        content = {"garbage": "I think maybe the qa folks? hard to say, GARBAGE-OUTPUT-73cw",
                   "badvalue": json.dumps({"role": "wizard", "stage": "teleport", "reason": "BADVALUE-73cw"})}.get(mode)
        if content is None: content = open(d + "/reply").read()
        out = json.dumps({"id": "x", "object": "chat.completion", "model": model, "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": content}}]})
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(out.encode())
http.server.ThreadingHTTPServer(("127.0.0.1", 0), H).serve_forever() if False else None
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(d + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY

# ---------- stateful bd stub ----------
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
        --add-label|--label) edit --arg id "$id" --arg v "$2" '(.[]|select(.id==$id)) |= (.labels=((.labels//[])+[$v]|unique))'; shift ;;
        --remove-label) edit --arg id "$id" --arg v "$2" '(.[]|select(.id==$id)) |= (.labels=((.labels//[])-[$v]))'; shift ;;
        --set-labels) edit --arg id "$id" --arg v "$2" '(.[]|select(.id==$id)) |= (.labels=($v|split(",")))'; shift ;;
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
  create)
    title=$2; labels=$(flagval -l "$@"); [ -n "$labels" ] || labels=$(flagval --labels "$@")
    n=$(( $(jq length "$F") + 1 )); nid="new-$n"
    edit --arg id "$nid" --arg t "$title" --arg l "$labels" '. + [{"id":$id,"title":$t,"status":"open","assignee":"","labels":($l|split(",")),"created":true}]'
    echo "[{\"id\":\"$nid\"}]" ;;
esac
exit 0
STUB
cat > "$TMP/stubs/claude" <<'STUB'
#!/usr/bin/env bash
echo x >> "$W/claude_runs"
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0}'
touch "$W/data/control/STOP"
exit 0
STUB
# docker stub for AC7: logs every call; `docker compose version` and everything else succeed.
cat > "$TMP/stubs/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_LOG:-/dev/null}"
case "$1" in
  model) exit 0 ;;
  *) case " $* " in *" run "*) ( cd "$PROJECT_DIR" && { echo ".agent-factory/" >> .gitignore; git add .gitignore && git commit -q -m s; } );; esac ;;
esac
exit 0
STUB
chmod +x "$TMP/stubs/"*

ORIGIN="$TMP/origin"
git init -q -b main "$ORIGIN"
git -C "$ORIGIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

ORIGIN_T="$TMP/origin_tests"   # an origin whose main has a non-empty tests/ (lets skip_tests be honoured)
git init -q -b main "$ORIGIN_T"; mkdir -p "$ORIGIN_T/tests"; echo ':' > "$ORIGIN_T/tests/x_test.sh"
git -C "$ORIGIN_T" add tests; git -C "$ORIGIN_T" -c user.name=t -c user.email=t@t commit -q -m init

# fixtures -----------------------------------------------------------------
cat > "$TMP/unrouted.json" <<'JSON'
[{"id":"t-1","title":"Login page returns 500 after deploy","description":"Seen in logs/web.log: KeyError session_id. Needs a fix.","status":"open","assignee":"","labels":["story:story-x"]}]
JSON
# intake: unrouted AND no story: label (e.g. a bug report with logs) - the po / direct / human decision
cat > "$TMP/intake.json" <<'JSON'
[{"id":"t-1","title":"Login page returns 500 after deploy","description":"Seen in logs/web.log: KeyError session_id. DESC-MARKER-73cw","status":"open","assignee":"","labels":[]}]
JSON
cat > "$TMP/escalated.json" <<'JSON'
[{"id":"t-1","title":"story-x: implement","description":"Implement.","status":"in_progress","assignee":"engineer","labels":["role:engineer","stage:implement","story:story-x","needs-team-lead"],"notes":"engineer: design doc missing section 3"}]
JSON

# run_loop FIXTURE MODE REPLY [extra env assignments...]
# MODE: ok|garbage|badvalue|http500|hang|down|off (off = flag unset). Sets W, RC.
run_loop() {
  local fixture=$1 mode=$2 reply=$3; shift 3
  W="$(mktemp -d "$TMP/run.XXXXXX")"; mkdir -p "$W/data/control" "$W/home" "$W/s1"
  : > "$W/bdlog"; : > "$W/claude_runs"; : > "$W/s1/requests.log"
  cp "$fixture" "$W/issues.json"
  local url=""
  if [ "$mode" != off ] && [ "$mode" != down ]; then
    echo "$mode" > "$W/s1/mode"; printf '%s' "$reply" > "$W/s1/reply"
    S1_DIR="$W/s1" python3 "$TMP/server.py" & SRV=$!
    for _ in $(seq 50); do [ -s "$W/s1/port" ] && break; sleep 0.1; done
    url="http://127.0.0.1:$(cat "$W/s1/port")/v1"
  elif [ "$mode" = down ]; then url="http://127.0.0.1:1/v1"   # nothing listens
  fi
  # watcher: once a non-claim mutation happened (or 20s), give the loop 2s to finish, then STOP it
  ( for _ in $(seq 200); do
      grep -E '^bd (update|label|comment|comments|create|close|unclaim)' "$W/bdlog" | grep -qv -- '--claim' && break
      [ -s "$W/claude_runs" ] && break; sleep 0.1; done
    sleep 2; touch "$W/data/control/STOP" ) & WATCH=$!
  RC=0
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home" "$@"
    if [ "$mode" != off ]; then export "$SYSTEM1_FLAG=1" "$SYSTEM1_URL_VAR=$url" "$SYSTEM1_MODEL_VAR=$MODEL_NAME"; fi
    PATH="$TMP/stubs:$PATH" ROLE=team-lead KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="${S1_ORIGIN:-$ORIGIN}" \
      PREFLIGHT=0 IDLE_SLEEP=1 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 \
      timeout 40 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || RC=$?
  kill "$WATCH" "${SRV:-}" 2>/dev/null; wait "$WATCH" "${SRV:-}" 2>/dev/null; SRV=""
}
claude_runs() { wc -l < "$W/claude_runs" | tr -d ' '; }
labels() { jq -r '.[] | select(.id == "t-1") | (.labels // []) | join(" ")' "$W/issues.json"; }
has_label() { jq -e --arg l "$1" '.[] | select(.id == "t-1") | (.labels // []) | index($l)' "$W/issues.json" >/dev/null; }
record() { jq -r '.[] | select(.id == "t-1") | ((.comments // []) + [(.notes // "")]) | join("\n")' "$W/issues.json"; }
requests() { wc -l < "$W/s1/requests.log" | tr -d ' '; }
ROUTE_QA='{"decision":"route","role":"qa","stage":"verify","target":"qa:verify","needs_human":false,"reason":"'"$REASON"'"}'
ROUTE_HUMAN='{"decision":"human","role":"human","stage":"","target":"human","needs_human":true,"reason":"'"$REASON"'"}'
INTAKE_PO='{"decision":"po","reason":"'"$REASON"'"}'
INTAKE_DIRECT='{"decision":"direct","reason":"'"$REASON"'"}'
INTAKE_HUMAN='{"decision":"human","reason":"'"$REASON"'"}'

# ---------- AC1: flag unset => unchanged capable-model session ----------
test_ac1_flag_unset_runs_capable_model_session() {
  local f
  for f in unrouted escalated; do
    run_loop "$TMP/$f.json" off ""
    if [ "$(claude_runs)" = 1 ]; then pass "ac1: flag unset, $f issue -> capable-model (claude) session started"
    else fail "ac1: flag unset, $f issue -> claude ran $(claude_runs) times (want 1). out: $(tail -5 "$W/out")"; fi
  done
}

# ---------- AC2: routing decision applied via bd ----------
test_ac2_unrouted_issue_routed_to_chosen_role() {
  run_loop "$TMP/unrouted.json" ok "$ROUTE_QA"
  local ok=1 why=""
  [ "$(requests)" -ge 1 ] || { ok=0; why="$why no model request;"; }
  has_label role:qa || { ok=0; why="$why role:qa missing (labels: $(labels));"; }
  has_label stage:verify || { ok=0; why="$why stage:verify missing;"; }
  has_label needs-human && { ok=0; why="$why needs-human set;"; }
  [ "$(claude_runs)" = 0 ] || { ok=0; why="$why claude session started;"; }
  record | grep -q "$REASON" || { ok=0; why="$why decision reason not recorded;"; }
  [ "$ok" = 1 ] && pass "ac2: unrouted issue labelled role:qa/stage:verify with recorded reason, no claude" || fail "ac2: unrouted routing:$why"
}

test_ac2_escalation_rerouted_and_stale_claim_released() {
  run_loop "$TMP/escalated.json" ok "$ROUTE_QA"
  local ok=1 why="" a
  has_label role:qa || { ok=0; why="$why role:qa missing (labels: $(labels));"; }
  has_label stage:verify || { ok=0; why="$why stage:verify missing;"; }
  has_label role:engineer && { ok=0; why="$why old role:engineer kept;"; }
  has_label stage:implement && { ok=0; why="$why old stage:implement kept;"; }
  has_label needs-team-lead && { ok=0; why="$why needs-team-lead not cleared;"; }
  a=$(jq -r '.[0].assignee // ""' "$W/issues.json")
  case "$a" in engineer|team-lead) ok=0; why="$why stale claim not released (assignee=$a);";; esac
  [ "$(claude_runs)" = 0 ] || { ok=0; why="$why claude session started;"; }
  record | grep -q "$REASON" || { ok=0; why="$why reason not recorded;"; }
  [ "$ok" = 1 ] && pass "ac2: needs-team-lead issue rerouted, stale claim released, reason recorded" || fail "ac2: escalation reroute:$why"
}

test_ac2_human_decision_labels_needs_human() {
  local f
  for f in unrouted escalated; do
    run_loop "$TMP/$f.json" ok "$ROUTE_HUMAN"
    local ok=1 why=""
    has_label needs-human || { ok=0; why="$why needs-human missing (labels: $(labels));"; }
    [ "$(claude_runs)" = 0 ] || { ok=0; why="$why claude session started;"; }
    record | grep -q "$REASON" || { ok=0; why="$why reason not recorded;"; }
    [ "$ok" = 1 ] && pass "ac2: model says human ($f) -> needs-human with reason" || fail "ac2: human decision ($f):$why"
  done
}

# ---------- AC3' (see header): intake decision for unrouted no-story issues; chain skip flags ----------
chain_creates() { grep -E '^bd create' "$W/bdlog"; }
check_full_chain() {  # args: roles/stages that must be created; sets ok/why in caller via echo
  local c; c=$(chain_creates); local m=""
  for rs in "$@"; do echo "$c" | grep -q "role:${rs%%/*},stage:${rs##*/}" || m="$m missing $rs;"; done
  echo "$m"
}
test_ac3_intake_po_routes_to_po() {
  run_loop "$TMP/intake.json" ok "$INTAKE_PO"
  local ok=1 why=""
  has_label role:po || { ok=0; why="$why role:po missing (labels: $(labels));"; }
  has_label needs-human && { ok=0; why="$why needs-human set;"; }
  [ -z "$(chain_creates)" ] || { ok=0; why="$why chain built for po decision;"; }
  [ "$(claude_runs)" = 0 ] || { ok=0; why="$why claude session started;"; }
  record | grep -q "$REASON" || { ok=0; why="$why reason not recorded;"; }
  [ "$(jq -r '.[0].assignee // ""' "$W/issues.json")" != team-lead ] || { ok=0; why="$why claim not released;"; }
  [ "$ok" = 1 ] && pass "ac3': intake 'po' -> role:po, reason recorded, no chain, no claude" || fail "ac3': intake po:$why"
}
test_ac3_intake_human_labels_needs_human() {
  run_loop "$TMP/intake.json" ok "$INTAKE_HUMAN"
  local ok=1 why=""
  has_label needs-human || { ok=0; why="$why needs-human missing (labels: $(labels));"; }
  has_label role:po && { ok=0; why="$why role:po set;"; }
  [ "$(claude_runs)" = 0 ] || { ok=0; why="$why claude session started;"; }
  record | grep -q "$REASON" || { ok=0; why="$why reason not recorded;"; }
  [ "$ok" = 1 ] && pass "ac3': intake 'human' -> needs-human with reason" || fail "ac3': intake human:$why"
}
test_ac3_intake_direct_builds_story_and_full_chain_without_po() {
  run_loop "$TMP/intake.json" ok "$INTAKE_DIRECT"
  local ok=1 why="" c m; c=$(chain_creates)
  [ "$(claude_runs)" = 0 ] || { ok=0; why="$why claude session started;"; }
  m=$(check_full_chain architect/design qa/tests engineer/implement qa/verify reviewer/review)
  [ -z "$m" ] || { ok=0; why="$why chain incomplete:$m"; }
  echo "$c" | grep -q "role:po" && { ok=0; why="$why a po stage was created;"; }
  has_label story:t-1 || { ok=0; why="$why original issue lacks story:t-1 (labels: $(labels));"; }
  [ "$(jq -r '.[0].status' "$W/issues.json")" = closed ] || { ok=0; why="$why original issue not closed;"; }
  record | grep -q "$REASON" || { ok=0; why="$why reason not recorded;"; }
  record | grep -q "$MODEL_NAME" || { ok=0; why="$why model not named;"; }
  git -C "$ORIGIN" rev-parse -q --verify refs/heads/story/t-1 >/dev/null || { ok=0; why="$why branch story/t-1 not pushed to origin;"; }
  git -C "$ORIGIN" show story/t-1:docs/stories/t-1.md 2>/dev/null | grep -q "DESC-MARKER-73cw" \
    || { ok=0; why="$why docs/stories/t-1.md missing or lacks the issue description;"; }
  [ "$ok" = 1 ] && pass "ac3': intake 'direct' -> story doc + branch pushed, full five-stage chain, no po, issue closed" \
    || fail "ac3': intake direct:$why (creates: $(echo "$c" | tr '\n' '|'))"
}
test_ac3_intake_rejects_route_decision() {
  run_loop "$TMP/intake.json" ok "$ROUTE_QA"   # route is not an allowed intake decision
  check_failure "intake issue given a 'route' decision (invalid for intake)"
  [ -z "$(chain_creates)" ] && ! has_label role:qa && pass "ac3': invalid intake decision applied nothing" || fail "ac3': invalid intake decision still acted"
}
test_ac3_route_kind_rejects_intake_decision() {
  run_loop "$TMP/unrouted.json" ok "$INTAKE_DIRECT"   # story-labelled unrouted issue: route/human only
  check_failure "story-labelled issue given an intake 'direct' decision"
  [ -z "$(chain_creates)" ] && pass "ac3': no chain built for invalid route-kind decision" || fail "ac3': chain built for invalid decision"
}
# ---------- AC4: endpoint/model/key from env; local and remote ----------
test_ac4_request_uses_configured_model_and_endpoint_path() {
  run_loop "$TMP/unrouted.json" ok "$ROUTE_QA"
  local line; line=$(head -1 "$W/s1/requests.log")
  [ -n "$line" ] || { fail "ac4: no request reached the configured endpoint"; return; }
  echo "$line" | jq -e --arg m "$MODEL_NAME" '.model == $m and (.path | endswith("/chat/completions"))' >/dev/null \
    && pass "ac4: POST <base>/chat/completions with the configured model name" \
    || fail "ac4: unexpected request: $line"
}
test_ac4_local_no_key_sends_no_authorization() {
  run_loop "$TMP/unrouted.json" ok "$ROUTE_QA"
  local line; line=$(head -1 "$W/s1/requests.log")
  [ -n "$line" ] || { fail "ac4: no request"; return; }
  echo "$line" | jq -e '.auth == null or .auth == "" or .auth == "Bearer "' >/dev/null \
    && pass "ac4: no API key configured -> no bearer token sent (local runner)" \
    || fail "ac4: unexpected Authorization with no key: $line"
}
test_ac4_remote_key_sent_as_bearer() {
  run_loop "$TMP/unrouted.json" ok "$ROUTE_QA" "$SYSTEM1_KEY_VAR=sk-test-73cw"
  local line; line=$(head -1 "$W/s1/requests.log")
  [ -n "$line" ] || { fail "ac4: no request with key configured"; return; }
  echo "$line" | jq -e '.auth == "Bearer sk-test-73cw"' >/dev/null && has_label role:qa \
    && pass "ac4: API key sent as 'Authorization: Bearer <key>' and decision applied" \
    || fail "ac4: key/decision wrong: $line labels=$(labels)"
}
test_ac4_env_example_documents_settings() {
  local v ok=1
  for v in "$SYSTEM1_FLAG" "$SYSTEM1_URL_VAR" "$SYSTEM1_MODEL_VAR" "$SYSTEM1_KEY_VAR"; do
    grep -Eq "^#?[[:space:]]*$v=" .env.example || { ok=0; echo "  .env.example lacks $v"; }
  done
  [ "$ok" = 1 ] && pass "ac4: .env.example lists the flag, URL, model and optional key" || fail "ac4: .env.example incomplete"
}

# ---------- AC5: failure => needs-human with note + raw output; capable model NOT started ----------
check_failure() {  # check_failure TAG [raw-output-marker]
  local ok=1 why=""
  has_label needs-human || { ok=0; why="$why needs-human missing (labels: $(labels));"; }
  [ -n "$(jq -r '.[0].notes // ""' "$W/issues.json")$(record)" ] || { ok=0; why="$why no note;"; }
  [ "$(claude_runs)" = 0 ] || { ok=0; why="$why capable-model session started;"; }
  if [ -n "${2:-}" ]; then record | grep -q "$2" || { ok=0; why="$why raw model output not in note;"; }; fi
  [ "$ok" = 1 ] && pass "ac5: $1 -> needs-human with note, no claude" || fail "ac5: $1:$why"
}
test_ac5_unreachable() { run_loop "$TMP/unrouted.json" down ""; check_failure "unreachable endpoint (unrouted)"
                         run_loop "$TMP/escalated.json" down ""; check_failure "unreachable endpoint (needs-team-lead)"
                         run_loop "$TMP/intake.json" down ""; check_failure "unreachable endpoint (intake)"; }
test_ac5_http_error() { run_loop "$TMP/unrouted.json" http500 ""; check_failure "HTTP 500"; }
test_ac5_timeout() { run_loop "$TMP/unrouted.json" hang "" SYSTEM1_TIMEOUT=2 SYSTEM1_TIMEOUT_SECS=2 SYSTEM1_REQUEST_TIMEOUT=2; check_failure "timeout"; }
test_ac5_garbage_output() { run_loop "$TMP/unrouted.json" garbage ""; check_failure "non-JSON output" GARBAGE-OUTPUT-73cw; }
test_ac5_invalid_decision_value() { run_loop "$TMP/escalated.json" badvalue ""; check_failure "unknown role/stage" BADVALUE-73cw; }
test_ac5_flag_set_without_endpoint() {
  # flag on but URL/model not configured: must fail to needs-human, not silently fall back to claude
  W="$(mktemp -d "$TMP/run.XXXXXX")"; mkdir -p "$W/data/control" "$W/home"; : > "$W/bdlog"; : > "$W/claude_runs"
  cp "$TMP/unrouted.json" "$W/issues.json"
  ( for _ in $(seq 200); do grep -E '^bd (update|label|comment)' "$W/bdlog" | grep -qv -- '--claim' && break; [ -s "$W/claude_runs" ] && break; sleep 0.1; done
    sleep 2; touch "$W/data/control/STOP" ) & local wt=$!
  ( export W HOME="$W/home" CONTAINER_HOME="$W/home" "$SYSTEM1_FLAG=1"
    unset "$SYSTEM1_URL_VAR" "$SYSTEM1_MODEL_VAR" "$SYSTEM1_KEY_VAR"
    PATH="$TMP/stubs:$PATH" ROLE=team-lead KIT_DIR="$KIT_DIR" PROJECT_DIR="$W" DATA_DIR="$W/data" ORIGIN="$ORIGIN" \
      PREFLIGHT=0 IDLE_SLEEP=1 MAX_ATTEMPTS_PER_ISSUE=1 MAX_CONSECUTIVE_FAILURES=1 \
      timeout 40 bash "$KIT_DIR/bin/agent-loop.sh" >"$W/out" 2>&1 ) || true
  kill "$wt" 2>/dev/null; wait "$wt" 2>/dev/null
  check_failure "flag set but endpoint/model unconfigured"
}

# ---------- AC6: bd show says which model decided and why ----------
test_ac6_record_names_model_and_reason() {
  local f
  for f in unrouted escalated; do
    run_loop "$TMP/$f.json" ok "$ROUTE_QA"
    local r; r=$(record)
    if echo "$r" | grep -q "$MODEL_NAME" && echo "$r" | grep -q "$REASON"; then pass "ac6: $f decision record names model '$MODEL_NAME' and the reason"
    else fail "ac6: $f record lacks model name and/or reason. record: $r"; fi
  done
  run_loop "$TMP/intake.json" ok "$INTAKE_PO"; r=$(record)
  if echo "$r" | grep -q "$MODEL_NAME" && echo "$r" | grep -q "$REASON"; then pass "ac6: intake decision record names model and reason"
  else fail "ac6: intake record lacks model/reason: $r"; fi
}
test_ac6_failure_note_names_model() {
  run_loop "$TMP/unrouted.json" garbage ""
  record | grep -q "$MODEL_NAME" && pass "ac6: failure note names the model" || fail "ac6: failure note lacks model name: $(record)"
}

# ---------- AC7: init.sh pulls/starts the model only when flag set; README documents ----------
run_init() {  # run_init "<env-file-extra-lines>" -> sets INIT_OUT, DLOG
  local kit proj
  kit=$(mktemp -d "$TMP/kit.XXXXXX"); proj=$(mktemp -d "$TMP/proj.XXXXXX"); DLOG="$TMP/dockerlog.$RANDOM"; : > "$DLOG"
  (cd "$KIT_DIR" && tar --exclude=.git -c .) | tar -x -C "$kit"
  git -C "$proj" init -q -b main
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
  git -C "$proj" config user.email t@t; git -C "$proj" config user.name t
  mkdir -p "$proj/.agent-factory"; cp "$KIT_DIR/.env.example" "$proj/.agent-factory/.env"
  printf '%b' "$1" >> "$proj/.agent-factory/.env"
  INIT_OUT=$(cd "$proj" && DOCKER_LOG="$DLOG" PATH="$TMP/stubs:$PATH" PROJECT_DIR="$proj" "$kit/bin/init.sh" 2>&1)
}
test_ac7_flag_set_pulls_default_model() {
  run_init "$SYSTEM1_FLAG=1\n$SYSTEM1_LOCAL_VAR=1\n"
  grep -E '^docker run .*vllm/vllm-openai:latest .*--model LiquidAI/d1-2B' "$DLOG" >/dev/null \
    && pass "ac7: flag set -> docker run vllm/vllm-openai:latest --model LiquidAI/d1-2B" \
    || fail "ac7: no 'docker run vllm/vllm-openai:latest --model LiquidAI/d1-2B'. docker log: $(tr '\n' '|' < "$DLOG") out: $(echo "$INIT_OUT" | tail -3)"
}
test_ac7_model_overridable() {
  run_init "$SYSTEM1_FLAG=1\n$SYSTEM1_LOCAL_VAR=1\n$SYSTEM1_MODEL_VAR=example/other-1B\n"
  grep -E '^docker run .*vllm/vllm-openai:latest .*--model example/other-1B' "$DLOG" >/dev/null && ! grep -q 'LiquidAI/d1-2B' "$DLOG" \
    && pass "ac7: model overridable via $SYSTEM1_MODEL_VAR" \
    || fail "ac7: override not honoured. docker log: $(tr '\n' '|' < "$DLOG")"
}
test_ac7_remote_flag_without_local_pulls_nothing() {
  run_init "$SYSTEM1_FLAG=1\n$SYSTEM1_URL_VAR=https://example.invalid/v1\n"
  grep -q '^docker run' "$DLOG" && fail "ac7: flag set but SYSTEM1_LOCAL unset, docker run called: $(grep '^docker run' "$DLOG" | tr '\n' '|')" \
    || pass "ac7: flag set without SYSTEM1_LOCAL (remote) -> no docker run call"
}
test_ac7_flag_unset_pulls_nothing() {
  run_init ""
  grep -q '^docker run' "$DLOG" && fail "ac7: flag unset but docker run was called: $(grep '^docker run' "$DLOG" | tr '\n' '|')" \
    || pass "ac7: flag unset -> no docker run call"
}
test_ac7_readme_documents_env() {
  local v ok=1
  for v in "$SYSTEM1_FLAG" "$SYSTEM1_URL_VAR" "$SYSTEM1_MODEL_VAR" "$SYSTEM1_KEY_VAR"; do
    grep -q "$v" README.md || { ok=0; echo "  README lacks $v"; }
  done
  grep -q 'LiquidAI/d1-2B' README.md || { ok=0; echo "  README lacks default model LiquidAI/d1-2B"; }
  [ "$ok" = 1 ] && pass "ac7: README documents the System 1 env settings and default model" || fail "ac7: README incomplete"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
