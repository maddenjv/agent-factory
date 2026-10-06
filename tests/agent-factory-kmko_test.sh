#!/usr/bin/env bash
# Acceptance tests for agent-factory-kmko: bin/init.sh succeeds on a machine with no git identity.
# One or more tests per acceptance criterion in docs/stories/agent-factory-kmko.md (test_acN_...).
# Derived only from the story, not from any design doc.
#
# Harness: bin/init.sh runs for real on the "host" (HOME = a temp dir whose git config we control,
# GIT_CONFIG_NOSYSTEM=1, no GIT_* identity env). A stub `docker` replaces compose: for
# `compose ... run` it executes the real bin/init-project.sh the way the container would - with a
# separate, empty HOME (the container has no host gitconfig) and only the `-e K=V` / `--env K=V`
# variables init.sh passed on the command line - plus a stub `bd`. So the fix may live either in
# init.sh (forwarding the host identity) or in init-project.sh (fallback identity).
#
# Run: bash tests/agent-factory-kmko_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

cleanup_dirs=()
trap 'for d in "${cleanup_dirs[@]}"; do rm -rf "$d"; done' EXIT
mkd() { local d; d=$(mktemp -d); cleanup_dirs+=("$d"); echo "$d"; }

# World: $W/home (host HOME), $W/chome (container HOME), $W/stubs, $W/proj (clean git project, no
# identity anywhere), $W/kit (copy of the kit at HEAD of the working tree's tracked files).
make_world() {
  W=$(mkd)
  mkdir -p "$W/home" "$W/chome" "$W/stubs" "$W/proj" "$W/kit"
  tar -C "$KIT_DIR" -cf - --exclude=.git --exclude=.agent-factory --exclude=.beads . | tar -x -C "$W/kit"
  cat > "$W/stubs/bd" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = init ]; then mkdir -p .beads; echo '{"dolt_server_port":3306}' > .beads/metadata.json; fi
exit 0
STUB
  cat > "$W/stubs/docker" <<'STUB'
#!/usr/bin/env bash
# Only `compose ... run` does anything: run init-project.sh as the container would.
case " $* " in *" run "*) ;; *) exit 0 ;; esac
envs=(); prev=""
for a in "$@"; do
  case "$prev" in -e|--env) envs+=("$a") ;; esac
  prev="$a"
done
cd "$PROJECT_DIR" || exit 1
env -i PATH="$STUB_PATH" HOME="$CONTAINER_HOME_DIR" GIT_CONFIG_NOSYSTEM=1 \
  KIT_DIR="$KIT_DIR" PROJECT_DIR="$PROJECT_DIR" "${envs[@]}" \
  bash "$KIT_DIR/bin/init-project.sh"
STUB
  chmod +x "$W/stubs/bd" "$W/stubs/docker"
  git -C "$W/proj" init -q -b main
  # a commit can't be made with no identity, so seed history with throwaway -c identity
  echo hello > "$W/proj/README.md"
  git -C "$W/proj" add README.md
  git -C "$W/proj" -c user.name=seed -c user.email=seed@seed.example commit -q -m seed
}

# run_init - sets out, status. Host env is scrubbed of git identity variables.
run_init() {
  local path="$W/stubs:$PATH"
  out=$(cd "$W/proj" && env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME \
        -u GIT_COMMITTER_EMAIL -u EMAIL -u GIT_CONFIG_GLOBAL -u XDG_CONFIG_HOME \
        PATH="$path" STUB_PATH="$path" HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 \
        PROJECT_DIR="$W/proj" KIT_DIR="$W/kit" CONTAINER_HOME_DIR="$W/chome" \
        bash "$W/kit/bin/init.sh" 2>&1)
  status=$?
}

snapshot_config() {  # host-visible git config state
  { cat "$W/home/.gitconfig" 2>/dev/null; echo ---; cat "$W/home/.config/git/config" 2>/dev/null
    echo ---; cat "$W/proj/.git/config"; } | grep -v 'receive.denyCurrentBranch\|denycurrentbranch\|updateInstead'
}
scaffold_commit_subject() { git -C "$W/proj" log -1 --format=%s main 2>/dev/null; }

test_ac1_no_identity_init_succeeds_and_commits() {
  make_world
  run_init
  [ "$status" -eq 0 ] || { fail "ac1: exit $status, expected 0; output: $out"; return; }
  grep -qi 'identity unknown\|tell me who you are' <<<"$out" && { fail "ac1: git identity error in output: $out"; return; }
  local subj; subj=$(scaffold_commit_subject)
  [ "$subj" = "agent-factory: scaffolding and beads init" ] \
    && pass "ac1: init exits 0 and the scaffolding commit is on main" \
    || fail "ac1: HEAD of main is '$subj', not the scaffolding commit; output: $out"
}

test_ac1_scaffolding_files_are_in_the_commit() {
  make_world
  run_init
  local files; files=$(git -C "$W/proj" ls-tree -r --name-only main 2>/dev/null)
  local miss=""
  for f in CLAUDE.md .gitignore docs/stories/.gitkeep docs/design/.gitkeep .beads/metadata.json; do
    grep -qxF "$f" <<<"$files" || miss="$miss $f"
  done
  [ -z "$miss" ] && pass "ac1: scaffolding paths committed on main" || fail "ac1: not committed on main:$miss (status $status, output: $out)"
}

test_ac2_no_identity_written_to_any_config() {
  make_world
  local before; before=$(snapshot_config)
  run_init
  local after; after=$(snapshot_config)
  local leaked=""
  for scope in global system local; do
    git -C "$W/proj" config --$scope --get-regexp '^user\.(name|email)$' >/dev/null 2>&1 \
      && leaked="$leaked $scope"
  done
  HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 git -C "$W/proj" config --get user.name >/dev/null 2>&1 && leaked="$leaked effective-name"
  HOME="$W/home" GIT_CONFIG_NOSYSTEM=1 git -C "$W/proj" config --get user.email >/dev/null 2>&1 && leaked="$leaked effective-email"
  if [ "$status" -ne 0 ]; then fail "ac2: init failed (exit $status) so config check is moot; output: $out"
  elif [ -n "$leaked" ]; then fail "ac2: identity written to:$leaked"
  elif [ "$before" != "$after" ]; then fail "ac2: git config changed. before: $before / after: $after"
  else pass "ac2: user's global/local git config unchanged, no identity written"; fi
}

test_ac3_configured_identity_authors_commit() {
  make_world
  git config --file "$W/home/.gitconfig" user.name "Real Person"
  git config --file "$W/home/.gitconfig" user.email "real@person.example"
  run_init
  [ "$status" -eq 0 ] || { fail "ac3: exit $status; output: $out"; return; }
  [ "$(scaffold_commit_subject)" = "agent-factory: scaffolding and beads init" ] \
    || { fail "ac3: scaffolding commit missing; output: $out"; return; }
  local a; a=$(git -C "$W/proj" log -1 --format='%an <%ae>' main)
  [ "$a" = "Real Person <real@person.example>" ] \
    && pass "ac3: scaffolding commit authored by the configured identity" \
    || fail "ac3: author is '$a', expected 'Real Person <real@person.example>'"
}

test_ac3_project_local_identity_authors_commit() {
  make_world
  git -C "$W/proj" config user.name "Local Dev"
  git -C "$W/proj" config user.email "local@dev.example"
  run_init
  local a; a=$(git -C "$W/proj" log -1 --format='%an <%ae>' main)
  [ "$status" -eq 0 ] && [ "$a" = "Local Dev <local@dev.example>" ] \
    && pass "ac3: project-local identity authors the scaffolding commit" \
    || fail "ac3: exit $status, author '$a'; output: $out"
}

test_ac3_configured_identity_not_overridden_in_committer() {
  make_world
  git config --file "$W/home/.gitconfig" user.name "Real Person"
  git config --file "$W/home/.gitconfig" user.email "real@person.example"
  run_init
  local c; c=$(git -C "$W/proj" log -1 --format='%cn <%ce>' main)
  [ "$c" = "Real Person <real@person.example>" ] \
    && pass "ac3: committer is also the configured identity" \
    || fail "ac3: committer is '$c' (status $status)"
}

test_ac4_only_name_configured_succeeds() {
  make_world
  git config --file "$W/home/.gitconfig" user.name "Only Name"
  run_init
  [ "$status" -eq 0 ] && [ "$(scaffold_commit_subject)" = "agent-factory: scaffolding and beads init" ] \
    && pass "ac4: only user.name set - init succeeds with scaffolding commit" \
    || fail "ac4(name only): exit $status; output: $out"
}

test_ac4_only_email_configured_succeeds() {
  make_world
  git config --file "$W/home/.gitconfig" user.email "only@email.example"
  run_init
  [ "$status" -eq 0 ] && [ "$(scaffold_commit_subject)" = "agent-factory: scaffolding and beads init" ] \
    && pass "ac4: only user.email set - init succeeds with scaffolding commit" \
    || fail "ac4(email only): exit $status; output: $out"
}

test_ac4_partial_identity_not_written_to_config() {
  make_world
  git config --file "$W/home/.gitconfig" user.name "Only Name"
  local before; before=$(snapshot_config)
  run_init
  [ "$status" -eq 0 ] && [ "$before" = "$(snapshot_config)" ] \
    && pass "ac4: partial identity: config unchanged" \
    || fail "ac4: partial identity: exit $status or config changed; output: $out"
}

test_ac5_rerun_succeeds_and_reports_already_present() {
  make_world
  run_init
  [ "$status" -eq 0 ] || { fail "ac5: first run failed (exit $status): $out"; return; }
  local head1; head1=$(git -C "$W/proj" rev-parse main)
  run_init
  [ "$status" -eq 0 ] || { fail "ac5: re-run exit $status; output: $out"; return; }
  grep -q 'scaffolding already present' <<<"$out" || { fail "ac5: no 'scaffolding already present' message; output: $out"; return; }
  [ "$(git -C "$W/proj" rev-parse main)" = "$head1" ] \
    && pass "ac5: re-run succeeds, reports already present, adds no commit" \
    || fail "ac5: re-run created a new commit"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do "$t"; done
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
