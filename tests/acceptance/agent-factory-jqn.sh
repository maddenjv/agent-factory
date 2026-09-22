#!/usr/bin/env bash
# Acceptance tests for agent-factory-jqn (.env per project).
# One test function per acceptance criterion in docs/stories/agent-factory-jqn.md - see that
# file and docs/design/agent-factory-jqn.md ("Test strategy (for QA)") for the criteria/commands
# these are derived from. No unit-test framework applies here (docs/ARCHITECTURE.md "Test
# strategy"); this is a plain shell acceptance script, run directly:
#   bash tests/acceptance/agent-factory-jqn.sh
# PASS/FAIL/SKIP is printed per criterion; overall exit is non-zero if any criterion FAILs.
# SKIP means "docker/shellcheck isn't available in this environment" (or the agent image hasn't
# been built yet) - not a pass, and not counted as a failure of the implementation under test.
#
# Written before the implementation exists (stage:tests): every test here targets bin/lib.sh,
# bin/init.sh, docker-compose.yml and README.md as they are DESIGNED to behave
# (docs/design/agent-factory-jqn.md), not as they behave today. Until agent-factory-0kq lands,
# AC1/AC2/AC3/AC4/AC5/AC6 are all expected to FAIL for that reason (no AGENT_ENV_FILE, no
# project-level .env support) - that is a correct failure, not a broken test.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$KIT_DIR"

pass=0
fail=0
skip=0

ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
skp() { echo "SKIP: $1"; skip=$((skip+1)); }

have_docker()     { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
have_agent_image() { docker image inspect factory-agent:latest >/dev/null 2>&1; }
have_shellcheck() { command -v shellcheck >/dev/null 2>&1; }

# --- fixtures -----------------------------------------------------------------------------
# Every test below runs against a scratch copy of this kit (never the real $KIT_DIR) and a
# scratch project repo (never the real $PROJECT_DIR) so tests can freely write .env files
# without touching the developer's own checkout or its git history.
cleanup_dirs=()
trap 'for d in "${cleanup_dirs[@]}"; do rm -rf "$d"; done' EXIT

make_tmpkit() {  # clean tracked-file copy of this repo - no local .env, no .git
  local d
  d=$(mktemp -d)
  git -C "$KIT_DIR" archive HEAD | tar -x -C "$d"
  cleanup_dirs+=("$d")
  echo "$d"
}

make_tmpproject() {  # scratch git repo standing in for PROJECT_DIR
  local d
  d=$(mktemp -d)
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t.example -c user.name=t commit -q --allow-empty -m init
  cleanup_dirs+=("$d")
  echo "$d"
}

# Resolves AGENT_ENV_FILE the same way any bin/*.sh script would: by sourcing lib.sh with
# PROJECT_DIR pointed at $2 and KIT_DIR implied by $1 (lib.sh derives KIT_DIR from its own
# location). Runs in a subshell so lib.sh's `exit 1` (e.g. non-git PROJECT_DIR) can't kill this
# whole test script; prints "<unset>" if AGENT_ENV_FILE never got exported.
resolve_agent_env_file() {  # resolve_agent_env_file <kitdir> <projectdir>
  local kitdir=$1 projdir=$2
  ( PROJECT_DIR="$projdir" source "$kitdir/bin/lib.sh" >/dev/null 2>&1
    echo "${AGENT_ENV_FILE:-<unset>}" )
}

# AC1: project-level .env (PROJECT_DIR/.agent-factory/.env) wins over kit-level .env when both
# are present, for values read by a running role container (proxy-tested here via lib.sh's
# resolution plus, when docker is available, a real container read of MODEL_ENGINEER).
test_ac1_project_env_overrides_kit_env() {
  local tmpkit tmpproject resolved
  tmpkit=$(make_tmpkit)
  tmpproject=$(make_tmpproject)
  echo "MODEL_ENGINEER=kit-level-value" > "$tmpkit/.env"
  mkdir -p "$tmpproject/.agent-factory"
  echo "MODEL_ENGINEER=project-level-value" > "$tmpproject/.agent-factory/.env"

  resolved=$(resolve_agent_env_file "$tmpkit" "$tmpproject")
  if [ "$resolved" != "$tmpproject/.agent-factory/.env" ]; then
    bad "ac1: AGENT_ENV_FILE resolved to '$resolved', expected project-level .env ($tmpproject/.agent-factory/.env)"
    return
  fi

  if ! have_docker; then
    skp "ac1: lib.sh resolution correct; docker not available to verify a running container sees MODEL_ENGINEER=project-level-value"
    return
  fi
  if ! have_agent_image; then
    skp "ac1: lib.sh resolution correct; factory-agent:latest image not built locally, skipping live container check"
    return
  fi
  local out
  out=$(PROJECT_DIR="$tmpproject" KIT_DIR="$tmpkit" AGENT_ENV_FILE="$tmpproject/.agent-factory/.env" \
        docker compose -f "$tmpkit/docker-compose.yml" run --rm --entrypoint bash agent -lc 'echo "$MODEL_ENGINEER"' 2>/dev/null)
  if [ "$out" = "project-level-value" ]; then
    ok "ac1: project-level .env value (MODEL_ENGINEER) wins inside a running container"
  else
    bad "ac1: running container saw MODEL_ENGINEER='$out', expected 'project-level-value'"
  fi
}

# AC2: with no project-level .env, the kit-level $KIT_DIR/.env is used, unchanged from today.
test_ac2_falls_back_to_kit_env_when_no_project_env() {
  local tmpkit tmpproject resolved
  tmpkit=$(make_tmpkit)
  tmpproject=$(make_tmpproject)
  echo "MODEL_ENGINEER=kit-level-value" > "$tmpkit/.env"
  # deliberately no $tmpproject/.agent-factory/.env

  resolved=$(resolve_agent_env_file "$tmpkit" "$tmpproject")
  if [ "$resolved" != "$tmpkit/.env" ]; then
    bad "ac2: AGENT_ENV_FILE resolved to '$resolved', expected kit-level fallback ($tmpkit/.env)"
    return
  fi
  ok "ac2: with no project-level .env, AGENT_ENV_FILE falls back to \$KIT_DIR/.env"
}

# AC3: the two files are never merged - a project .env that only sets some variables must not
# silently inherit the rest from the kit-level .env.
test_ac3_no_partial_merge() {
  local tmpkit tmpproject
  tmpkit=$(make_tmpkit)
  tmpproject=$(make_tmpproject)
  echo -e "MODEL_ENGINEER=kit-level-value\nNOTIFY_URL=http://kit.example/hook" > "$tmpkit/.env"
  mkdir -p "$tmpproject/.agent-factory"
  echo "MODEL_ENGINEER=project-level-value" > "$tmpproject/.agent-factory/.env"   # NOTIFY_URL absent here

  # Structural check: docker-compose.yml's env_file must be a single scalar path (driven by the
  # AGENT_ENV_FILE resolved above), never a list of multiple files - that's what makes merging
  # impossible by construction, independent of which values are set.
  if ! grep -Eq 'env_file:\s*\$\{AGENT_ENV_FILE' docker-compose.yml; then
    bad "ac3: docker-compose.yml's agent.env_file is not driven by \${AGENT_ENV_FILE...} - can't confirm single-file (non-merging) load"
    return
  fi

  if ! have_docker; then
    skp "ac3: docker-compose.yml structurally single-file; docker not available to verify NOTIFY_URL is absent (not merged) in a running container"
    return
  fi
  if ! have_agent_image; then
    skp "ac3: docker-compose.yml structurally single-file; factory-agent:latest image not built locally, skipping live container check"
    return
  fi
  local out
  out=$(PROJECT_DIR="$tmpproject" KIT_DIR="$tmpkit" AGENT_ENV_FILE="$tmpproject/.agent-factory/.env" \
        docker compose -f "$tmpkit/docker-compose.yml" run --rm --entrypoint bash agent -lc 'echo "${NOTIFY_URL:-<absent>}"' 2>/dev/null)
  if [ "$out" = "<absent>" ]; then
    ok "ac3: kit-only variable (NOTIFY_URL) is absent, not merged in, when project .env is loaded"
  else
    bad "ac3: NOTIFY_URL='$out' leaked in from the kit-level .env despite a project-level .env being in effect"
  fi
}

# AC4: fresh project, neither .env exists yet - bin/init.sh creates the starter at the
# project-level path ($DATA_DIR/.env, from .env.example), not at $KIT_DIR/.env.
test_ac4_fresh_init_creates_project_level_env() {
  local tmpkit tmpproject out status
  tmpkit=$(make_tmpkit)
  tmpproject=$(make_tmpproject)
  # sanity: neither .env exists yet in either scratch tree
  [ -f "$tmpkit/.env" ] && { bad "ac4: test setup bug - tmpkit already has a .env"; return; }

  out=$(PROJECT_DIR="$tmpproject" bash "$tmpkit/bin/init.sh" 2>&1)
  status=$?

  if [ "$status" -ne 1 ]; then
    bad "ac4: bin/init.sh exited $status on a fresh project with no .env anywhere, expected 1 (create-and-stop flow); output: $out"
    return
  fi
  if [ -f "$tmpkit/.env" ]; then
    bad "ac4: bin/init.sh created \$KIT_DIR/.env - starter .env must go under the project's own .agent-factory/, not the kit"
    return
  fi
  if [ ! -f "$tmpproject/.agent-factory/.env" ]; then
    bad "ac4: bin/init.sh did not create $tmpproject/.agent-factory/.env; output: $out"
    return
  fi
  if ! grep -q "$tmpproject/.agent-factory/.env" <<<"$out"; then
    bad "ac4: bin/init.sh's message doesn't name the project-level path it created ($tmpproject/.agent-factory/.env); output: $out"
    return
  fi
  if ! diff -q "$tmpkit/.env.example" "$tmpproject/.agent-factory/.env" >/dev/null 2>&1; then
    bad "ac4: created .env doesn't match .env.example's starter contents"
    return
  fi
  ok "ac4: fresh init creates the starter .env at the project-level path, from .env.example, exits 1, and names the path"
}

# AC5: a project that already has an established kit-level $KIT_DIR/.env (from before this
# change) and has never had a project-level one keeps working unchanged, no migration required.
test_ac5_preexisting_kit_env_keeps_working_unmigrated() {
  local tmpkit tmpproject before after
  tmpkit=$(make_tmpkit)
  tmpproject=$(make_tmpproject)
  echo "MODEL_ENGINEER=established-kit-value" > "$tmpkit/.env"   # pre-existing, pre-change file

  before=$(resolve_agent_env_file "$tmpkit" "$tmpproject")
  # Re-running resolution (e.g. a second script invocation for the same project) must be stable
  # and still require no manual migration step - no project-level .env should appear on its own.
  after=$(resolve_agent_env_file "$tmpkit" "$tmpproject")

  if [ -e "$tmpproject/.agent-factory/.env" ]; then
    bad "ac5: a project-level .env appeared on its own - that's a migration step, not the 'keeps working unmigrated' behavior AC5 requires"
    return
  fi
  if [ "$before" != "$tmpkit/.env" ] || [ "$after" != "$tmpkit/.env" ]; then
    bad "ac5: AGENT_ENV_FILE resolved to '$before' then '$after' for an established kit-only project, expected '$tmpkit/.env' both times"
    return
  fi
  ok "ac5: pre-existing kit-level .env keeps resolving correctly with zero manual migration"
}

# AC6: README's Setup section documents the per-project .env, the kit-level fallback, and the
# no-merge precedence rule, so operators managing more than one project know where to look.
test_ac6_readme_documents_precedence() {
  local missing=0
  grep -Eq '\.agent-factory/\.env' README.md || { bad "ac6: README.md doesn't mention the project-level .env path (<project>/.agent-factory/.env)"; missing=1; }
  grep -Eiq 'fallback|falls back' README.md || { bad "ac6: README.md doesn't describe the kit-level .env as a fallback"; missing=1; }
  grep -Eiq 'not merged|no merg|never both|one or the other' README.md || { bad "ac6: README.md doesn't state that the two .env files are never merged"; missing=1; }
  [ "$missing" -eq 1 ] && return
  ok "ac6: README documents the per-project .env, the kit-level fallback, and the no-merge rule"
}

# Cross-cutting: shellcheck the touched scripts (docs/ARCHITECTURE.md convention for bash
# changes). Not tied to a single AC; informational quality gate for the implementer.
test_shellcheck_touched_scripts() {
  if ! have_shellcheck; then
    skp "shellcheck: not installed in this environment"
    return
  fi
  # -x (follow sourced files) needs to run from bin/ itself, since lib.sh is sourced via a
  # relative path resolved from the sourcing script's own directory - otherwise shellcheck
  # reports a bogus SC1091 ("lib.sh does not exist") that has nothing to do with the scripts'
  # actual content.
  if (cd bin && shellcheck -x lib.sh init.sh start.sh); then
    ok "shellcheck: bin/lib.sh, bin/init.sh, bin/start.sh clean"
  else
    bad "shellcheck: findings in bin/lib.sh, bin/init.sh, and/or bin/start.sh"
  fi
}

test_ac1_project_env_overrides_kit_env
test_ac2_falls_back_to_kit_env_when_no_project_env
test_ac3_no_partial_merge
test_ac4_fresh_init_creates_project_level_env
test_ac5_preexisting_kit_env_keeps_working_unmigrated
test_ac6_readme_documents_precedence
test_shellcheck_touched_scripts

echo "---"
echo "pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
