#!/usr/bin/env bash
# Acceptance tests for agent-factory-eyiz (bin/init.sh messages name the chosen harness's auth).
# One test per acceptance criterion in docs/stories/agent-factory-eyiz.md (test_acN_...).
# Run: bash tests/acceptance/agent-factory-eyiz.sh   (exit non-zero if any FAIL)
#
# Docker is replaced by a stub `docker` on PATH (as in agent-factory-6ixl.sh); no real docker needed.
# The assertions look at everything bin/init.sh prints (stdout+stderr), which covers the
# "Created ..." message (AC1-3) and every other message (AC4).
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
make_stub() {
  local d; d=$(mktemp -d); cleanup_dirs+=("$d")
  cat > "$d/docker" <<'STUB'
#!/usr/bin/env bash
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

CLAUDE_TERMS=('~/.claude' 'CLAUDE_CODE_OAUTH_TOKEN' 'ANTHROPIC_API_KEY' 'Claude')
COPILOT_TERMS=('~/.copilot' 'COPILOT_GITHUB_TOKEN' 'GH_TOKEN' 'GITHUB_TOKEN')

# has_all <text> <term...> / has_none <text> <term...>; print offending/missing term on failure
missing_term() { local t=$1; shift; for x in "$@"; do grep -qF -- "$x" <<<"$t" || { echo "$x"; return 0; }; done; return 1; }
present_term() { local t=$1; shift; for x in "$@"; do ! grep -qF -- "$x" <<<"$t" || { echo "$x"; return 0; }; done; return 1; }

created_line() { grep -F 'Created ' <<<"$1"; }

test_ac1_created_message_names_chosen_harness() {
  local kit proj stub line m
  # copilot
  kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
  run_init "$kit" "$proj" "$stub" --harness=copilot
  line=$(created_line "$out")
  [ -n "$line" ] || { bad "ac1(copilot): no 'Created ...' message; out: $out"; return; }
  if m=$(missing_term "$line" '~/.copilot' 'copilot login' COPILOT_GITHUB_TOKEN GH_TOKEN GITHUB_TOKEN); then
    bad "ac1(copilot): Created message lacks '$m': $line"
  else ok "ac1(copilot): Created message names ~/.copilot, copilot login and the copilot token vars"; fi
  # claude-code, explicit flag and no flag
  local variant
  for variant in --harness=claude-code ""; do
    kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
    run_init "$kit" "$proj" "$stub" ${variant:+"$variant"}
    line=$(created_line "$out")
    [ -n "$line" ] || { bad "ac1(claude-code '${variant}'): no 'Created ...' message; out: $out"; continue; }
    if m=$(missing_term "$line" '~/.claude' CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY); then
      bad "ac1(claude-code '${variant}'): Created message lacks '$m': $line"
    else ok "ac1(claude-code '${variant}'): Created message names ~/.claude and the claude token vars"; fi
  done
}

test_ac2_copilot_output_has_no_claude_terms() {
  local kit proj stub m
  kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
  run_init "$kit" "$proj" "$stub" --harness=copilot
  if m=$(present_term "$out" "${CLAUDE_TERMS[@]}"); then
    bad "ac2: copilot output contains '$m': $out"
  else ok "ac2: copilot output has no ~/.claude / CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY / Claude"; fi
}

test_ac3_claude_output_has_no_copilot_terms() {
  local kit proj stub m variant
  for variant in --harness=claude-code ""; do
    kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
    run_init "$kit" "$proj" "$stub" ${variant:+"$variant"}
    if m=$(present_term "$out" "${COPILOT_TERMS[@]}"); then
      bad "ac3('${variant}'): claude-code output contains '$m': $out"
    else ok "ac3('${variant}'): claude-code output has no copilot login/token terms"; fi
  done
}

test_ac4_other_messages_follow_harness_in_effect() {
  local kit proj stub m
  # Error path (dirty tree) under copilot flag: no Claude terms.
  kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub); echo wip > "$proj/stray.txt"
  run_init "$kit" "$proj" "$stub" --harness=copilot
  if [ "$status" -ne 0 ] && ! m=$(present_term "$out" "${CLAUDE_TERMS[@]}"); then
    ok "ac4: copilot error output free of Claude terms"
  else bad "ac4: copilot dirty-tree run (status $status) output: $out"; fi
  # Re-run: harness in effect comes from .env's HARNESS=copilot (no flag); full output stays copilot-clean.
  kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
  run_init "$kit" "$proj" "$stub" --harness=copilot
  run_init "$kit" "$proj" "$stub"
  if [ "$status" -eq 0 ] && ! m=$(present_term "$out" "${CLAUDE_TERMS[@]}"); then
    ok "ac4: re-run with HARNESS=copilot from .env (no flag) prints no Claude terms"
  else bad "ac4: copilot re-run (status $status, term '${m:-}') output: $out"; fi
  # Pre-existing .env with HARNESS=copilot, no flag, dirty tree: error message is copilot-clean.
  kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
  mkdir -p "$proj/.agent-factory"; printf 'HARNESS=copilot\n' > "$proj/.agent-factory/.env"; echo wip > "$proj/stray.txt"
  run_init "$kit" "$proj" "$stub"
  if ! m=$(present_term "$out" "${CLAUDE_TERMS[@]}"); then ok "ac4: error with HARNESS=copilot in .env has no Claude terms"
  else bad "ac4: .env-selected copilot error output contains '$m': $out"; fi
  # Claude-code default: error/Done output free of copilot terms.
  kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub); echo wip > "$proj/stray.txt"
  run_init "$kit" "$proj" "$stub"
  if ! m=$(present_term "$out" "${COPILOT_TERMS[@]}"); then ok "ac4: claude-code error output has no copilot terms"
  else bad "ac4: claude-code error output contains '$m': $out"; fi
  # Messages mentioning no agent-specific auth stay unchanged.
  kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
  run_init "$kit" "$proj" "$stub" --harness=copilot
  if grep -q '^Waiting for Dolt' <<<"$out" && grep -q '^Done\. Next: .*bin/start\.sh' <<<"$out"; then
    ok "ac4: 'Waiting for Dolt...' and 'Done. Next: ...' messages unchanged"
  else bad "ac4: neutral messages changed; out: $out"; fi
}

test_ac5_claude_default_unchanged() {
  local kit proj stub env
  kit=$(make_tmpkit); proj=$(make_tmpproject); stub=$(make_stub)
  run_init "$kit" "$proj" "$stub"
  env="$proj/.agent-factory/.env"
  if [ "$status" -ne 0 ]; then bad "ac5: default run exit $status; out: $out"; return; fi
  if [ "$(grep -c '^HARNESS=claude-code$' "$env")" = 1 ] && ! grep -q 'copilot' <(grep -v '^#' "$env" | grep '^HARNESS='); then
    ok "ac5: default exit 0, .env records HARNESS=claude-code once"
  else bad "ac5: .env HARNESS lines wrong: $(grep HARNESS "$env")"; fi
  if diff <(grep -v '^\(HOST_UID\|HOST_GID\|HOST_USER\|CONTAINER_HOME\|HARNESS\)=' "$env") "$kit/.env.example" >/dev/null; then
    ok "ac5: default .env equals .env.example plus the usual appended keys"
  else bad "ac5: default .env diverges from .env.example"; fi
}

test_ac1_created_message_names_chosen_harness
test_ac2_copilot_output_has_no_claude_terms
test_ac3_claude_output_has_no_copilot_terms
test_ac4_other_messages_follow_harness_in_effect
test_ac5_claude_default_unchanged

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
