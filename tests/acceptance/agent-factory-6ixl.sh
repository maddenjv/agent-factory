#!/usr/bin/env bash
# Acceptance tests for agent-factory-6ixl (bin/init.sh completes setup in one run).
# One test per acceptance criterion in docs/stories/agent-factory-6ixl.md (test_acN_...).
# Run: bash tests/acceptance/agent-factory-6ixl.sh   (exit non-zero if any FAIL)
#
# Docker is replaced by a stub `docker` on PATH that logs every invocation (and the HARNESS in
# the --env-file at that moment) to $STUB_LOG, and mimics bin/init-project.sh's relevant effect
# for `compose ... run` (ignore .agent-factory/, commit scaffolding on main). No real docker needed.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$KIT_DIR"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

cleanup_dirs=()
trap 'for d in "${cleanup_dirs[@]}"; do rm -rf "$d"; done' EXIT

make_tmpkit() {
  local d; d=$(mktemp -d)
  git -C "$KIT_DIR" archive HEAD | tar -x -C "$d"
  cleanup_dirs+=("$d"); echo "$d"
}
make_tmpproject() {
  local d; d=$(mktemp -d)
  git -C "$d" init -q -b main
  git -C "$d" -c user.email=t@t.example -c user.name=t commit -q --allow-empty -m init
  git -C "$d" config user.email t@t.example; git -C "$d" config user.name t
  cleanup_dirs+=("$d"); echo "$d"
}
make_stub() {  # -> dir containing stub docker; log at $dir/log
  local d; d=$(mktemp -d); cleanup_dirs+=("$d")
  cat > "$d/docker" <<'STUB'
#!/usr/bin/env bash
envfile=""; prev=""
for a in "$@"; do [ "$prev" = "--env-file" ] && envfile="$a"; prev="$a"; done
h=$(grep '^HARNESS=' "$envfile" 2>/dev/null | tail -1)
echo "docker $* [${h:-HARNESS=<none>}]" >> "$STUB_LOG"
case " $* " in
  *" run "*)
    ( cd "$PROJECT_DIR" && { grep -qxF '.agent-factory/' .gitignore 2>/dev/null || echo '.agent-factory/' >> .gitignore
      git add .gitignore && git commit -q -m scaffold; } ) ;;
esac
exit 0
STUB
  chmod +x "$d/docker"; echo "$d"
}

# run_init <kit> <project> <stubdir> [args...]  -> sets out, status
run_init() {
  local kit=$1 proj=$2 stub=$3; shift 3
  out=$(cd "$proj" && PATH="$stub:$PATH" STUB_LOG="$stub/log" PROJECT_DIR="$proj" bash "$kit/bin/init.sh" "$@" 2>&1)
  status=$?
}

test_ac1_single_run_completes() {
  local kit proj stub; kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
  run_init "$kit" "$proj" "$stub"
  [ "$status" -eq 0 ] || { bad "ac1: exit $status, expected 0; output: $out"; return; }
  [ -f "$proj/.agent-factory/.env" ] || { bad "ac1: .agent-factory/.env not created"; return; }
  # content: starter .env == .env.example plus only the HOST_*/CONTAINER_HOME/HARNESS lines init adds on continuing
  local extra
  extra=$(diff "$kit/.env.example" "$proj/.agent-factory/.env" | grep '^<' || true)
  [ -z "$extra" ] || { bad "ac1: .env lost lines from .env.example: $extra"; return; }
  grep -q 'compose.* build' "$stub/log" || { bad "ac1: docker build never invoked; log: $(cat "$stub/log" 2>/dev/null)"; return; }
  grep -q 'compose.* up .*dolt' "$stub/log" || { bad "ac1: dolt never started; log: $(cat "$stub/log")"; return; }
  grep -q 'compose.* run ' "$stub/log" || { bad "ac1: init-project never run; log: $(cat "$stub/log")"; return; }
  grep -q "Done. Next: $kit/bin/start.sh" <<<"$out" || { bad "ac1: missing 'Done. Next: $kit/bin/start.sh'; output: $out"; return; }
  ok "ac1: one run creates .env, builds, starts dolt, initialises project, prints Done, exit 0"
}

test_ac2_env_message() {
  local kit proj stub; kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
  run_init "$kit" "$proj" "$stub"
  local miss=""
  grep -q "$proj/.agent-factory/.env" <<<"$out" || miss="$miss path"
  grep -qi 'token' <<<"$out" || miss="$miss token"
  grep -qi 'model' <<<"$out" || miss="$miss models"
  grep -qi 'budget' <<<"$out" || miss="$miss budget"
  grep -qi 're-run bin/init.sh' <<<"$out" || miss="$miss rerun-instruction"
  [ -z "$miss" ] && ok "ac2: message names .env path, optional settings, and re-run instruction" \
                 || bad "ac2: message missing:$miss; output: $out"
}

test_ac3_rerun_ignores_untracked_agent_factory() {
  local kit proj stub; kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
  # state left by an interrupted first run: .agent-factory/ exists, not ignored, nothing else dirty
  mkdir -p "$proj/.agent-factory"; cp "$kit/.env.example" "$proj/.agent-factory/.env"
  run_init "$kit" "$proj" "$stub"
  if [ "$status" -eq 0 ] && ! grep -q 'uncommitted changes' <<<"$out"; then
    ok "ac3: re-run with only untracked .agent-factory/ passes the dirty check"
  else
    bad "ac3: exit $status; output: $out"
  fi
}

test_ac4_other_dirty_still_refused() {
  local kit proj stub; kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
  mkdir -p "$proj/.agent-factory"; cp "$kit/.env.example" "$proj/.agent-factory/.env"
  echo wip > "$proj/stray.txt"
  local before; before=$(git -C "$proj" rev-parse HEAD)
  run_init "$kit" "$proj" "$stub"
  if [ "$status" -ne 0 ] && grep -q 'uncommitted changes' <<<"$out" \
     && [ "$(git -C "$proj" rev-parse HEAD)" = "$before" ] && ! grep -q ' run ' "$stub/log" 2>/dev/null; then
    ok "ac4: other uncommitted changes still refused, no commit made"
  else
    bad "ac4: exit $status, head moved? $([ "$(git -C "$proj" rev-parse HEAD)" = "$before" ] && echo no || echo yes); output: $out"
  fi
  # also on a fresh project (no .agent-factory yet) combined with a dirty tree
  proj=$(make_tmpproject); echo wip > "$proj/stray.txt"; stub=$(make_stub)
  run_init "$kit" "$proj" "$stub"
  if [ "$status" -ne 0 ] && grep -q 'uncommitted changes' <<<"$out"; then
    ok "ac4: fresh dirty project refused too"
  else
    bad "ac4: fresh dirty project: exit $status; output: $out"
  fi
}

test_ac5_rerun_idempotent() {
  local kit proj stub; kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
  run_init "$kit" "$proj" "$stub"
  [ "$status" -eq 0 ] || { bad "ac5: first run exit $status: $out"; return; }
  echo "MODEL_ENGINEER=custom-value" >> "$proj/.agent-factory/.env"
  local before; before=$(cat "$proj/.agent-factory/.env")
  run_init "$kit" "$proj" "$stub"
  if [ "$status" -eq 0 ] && [ "$(cat "$proj/.agent-factory/.env")" = "$before" ]; then
    ok "ac5: second run succeeds and leaves .env untouched"
  else
    bad "ac5: second run exit $status or .env changed; output: $out"
  fi
}

test_ac6_harness_recorded_and_used() {
  local h kit proj stub
  for h in copilot claude-code; do
    kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
    run_init "$kit" "$proj" "$stub" --harness=$h
    if [ "$status" -ne 0 ]; then bad "ac6($h): exit $status; output: $out"; continue; fi
    if [ "$(grep -c '^HARNESS=' "$proj/.agent-factory/.env")" -ne 1 ] || ! grep -qx "HARNESS=$h" "$proj/.agent-factory/.env"; then
      bad "ac6($h): .env lacks exactly one HARNESS=$h"; continue
    fi
    if grep ' build ' "$stub/log" | grep -q "HARNESS=$h\]"; then
      ok "ac6($h): HARNESS=$h recorded in .env and in effect for the image build"
    else
      bad "ac6($h): build ran without HARNESS=$h in its env file; log: $(cat "$stub/log")"
    fi
  done
}

test_ac1_single_run_completes
test_ac2_env_message
test_ac3_rerun_ignores_untracked_agent_factory
test_ac4_other_dirty_still_refused
test_ac5_rerun_idempotent
test_ac6_harness_recorded_and_used

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
