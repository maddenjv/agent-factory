#!/usr/bin/env bash
# Acceptance tests for agent-factory-mgq7: agents can use the project's Python virtualenv inside
# the containers. One function per acceptance criterion in docs/stories/agent-factory-mgq7.md
# (test_acN_...). Written from the story's acceptance criteria only - not from the design doc.
#
# Black-box and real: these start the actual agent image (docker compose run, entrypoint
# bin/agent-loop.sh with a STOP file so it does startup and exits, PREFLIGHT=0 so no claude/bd is
# needed) against a scratch PROJECT_DIR holding a real host .venv, then probe the same container
# with `bash -lc` ("python" with no path, as an agent's shell would run it). Startup and probe share
# one container on purpose: the story does not say where the container venv lives (image layer,
# volume, project dir), so the only thing assumed is that it is ready after agent-loop.sh's startup
# and that `python` resolves to it in a login shell. If the implementation does its setup elsewhere
# (e.g. host-side in bin/start.sh) adjust start_probe() - not the assertions.
#
# Needs: docker + a built factory-agent image that has python3/venv (agent-factory-ncij), host
# python3 with venv+pip, network (six/tomli are fetched from PyPI by the host pip and, per the
# story, by the container). Missing prerequisites => SKIP (exit 0), never a false PASS.
# The scratch host .venv also gets one hand-made dist-info for a package that exists nowhere (AC7).
#
# Run directly: bash tests/agent-factory-mgq7_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }
finish() { echo "pass=$PASS fail=$FAIL skip=$SKIP"; [ "$FAIL" -eq 0 ]; }

BADPKG="af-mgq7-unavailable-pkg"
need_skip() { skip "$1"; echo "SKIP: prerequisites missing ($1) - nothing asserted"; finish; exit $?; }

command -v docker >/dev/null 2>&1 || need_skip "docker not available"
command -v python3 >/dev/null 2>&1 || need_skip "host python3 not available"
IMAGE="${AGENT_IMAGE:-factory-agent:latest}"
docker image inspect "$IMAGE" >/dev/null 2>&1 || need_skip "image $IMAGE not built"
docker run --rm --entrypoint bash "$IMAGE" -lc 'python3 -c "import venv, ensurepip" && python3 -m venv --help >/dev/null' >/dev/null 2>&1 \
  || need_skip "image lacks python3/venv (agent-factory-ncij not landed)"

TMP="$(mktemp -d)"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
GIT="git -c user.name=t -c user.email=t@t -c init.defaultBranch=main"

# ---------------- scratch project + host .venv ----------------
new_project() {  # new_project NAME -> PROJECT_DIR (git repo, .venv git-ignored, env file ready)
  local p="$TMP/$1"; mkdir -p "$p"
  ( cd "$p" && $GIT init -q && echo ".venv/" > .gitignore && echo ".agent-factory/" >> .gitignore \
      && echo x > README && $GIT add .gitignore README && $GIT commit -q -m init ) || return 1
  mkdir -p "$p/.agent-factory/control"
  touch "$p/.agent-factory/control/STOP"
  { [ -f "$KIT_DIR/.env.example" ] && grep -v '^#' "$KIT_DIR/.env.example"
    echo "PREFLIGHT=0"; echo "HOST_UID=$(id -u)"; echo "HOST_GID=$(id -g)"; echo "HOST_USER=${HOST_USER:-$(id -un)}"
  } > "$p/.agent-factory/.env"
  echo "$p"
}
host_pip() { "$1/.venv/bin/python" -m pip install -q --disable-pip-version-check "${@:2}" >/dev/null 2>&1; }
make_host_venv() {  # make_host_venv PROJECT - six==1.16.0, tomli==2.0.1, plus an uninstallable dist-info
  local p="$1"
  python3 -m venv "$p/.venv" >/dev/null 2>&1 || return 1
  host_pip "$p" six==1.16.0 tomli==2.0.1 || return 1
  local sp; sp=$("$p/.venv/bin/python" -c 'import sysconfig;print(sysconfig.get_paths()["purelib"])') || return 1
  mkdir -p "$sp/${BADPKG//-/_}-9.9.9.dist-info"
  printf 'Metadata-Version: 2.1\nName: %s\nVersion: 9.9.9\n' "$BADPKG" > "$sp/${BADPKG//-/_}-9.9.9.dist-info/METADATA"
  : > "$sp/${BADPKG//-/_}-9.9.9.dist-info/RECORD"; echo pip > "$sp/${BADPKG//-/_}-9.9.9.dist-info/INSTALLER"
}
snapshot() {  # snapshot DIR - names, types, sizes, mtimes, link targets and content hashes
  ( cd "$1" && find . -printf '%p|%y|%s|%T@|%l\n' | sort; find . -type f -print0 | sort -z | xargs -0 -r sha256sum )
}

# start_probe PROJECT 'probe commands' -> runs startup then probes in ONE container; output in $OUT, rc in $RC
start_probe() {
  local p="$1" probe="$2"
  OUT=$(cd "$p" && export PROJECT_DIR="$p" KIT_DIR AGENT_ENV_FILE="$p/.agent-factory/.env" ROLE=qa &&
    docker compose -f "$KIT_DIR/docker-compose.yml" --env-file "$p/.agent-factory/.env" run --rm -T --no-deps \
      --entrypoint bash agent -lc "bash '$KIT_DIR/bin/agent-loop.sh'; echo '=== PROBE ==='; cd '$p/.agent-factory/workspaces/qa' && { $probe; }" 2>&1)
  RC=$?
}
probe_part() { printf '%s\n' "$OUT" | sed -n '/^=== PROBE ===$/,$p' | tail -n +2; }
startup_part() { printf '%s\n' "$OUT" | sed '/^=== PROBE ===$/,$d'; }

IMPORT_PROBE='python - <<PY
import importlib.metadata as m, sys
print("EXE", sys.executable, "PREFIX", sys.prefix, "BASE", sys.base_prefix)
for d in sorted(m.distributions(), key=lambda d: d.metadata["Name"].lower()):
    print("PKG", d.metadata["Name"].lower(), d.version)
PY'

# ---------------- AC1 ----------------
test_ac1_python_resolves_to_container_venv() {
  local p; p=$(new_project ac1) && make_host_venv "$p" || { fail "AC1: fixture setup failed"; return; }
  start_probe "$p" 'command -v python; python -c "import sys; print(\"EXE\", sys.executable, \"PREFIX\", sys.prefix, \"BASE\", sys.base_prefix)"'
  local pr; pr=$(probe_part)
  local exe; exe=$(printf '%s\n' "$pr" | sed -n 's/^EXE \(.*\) PREFIX .*/\1/p' | head -1)
  local prefix; prefix=$(printf '%s\n' "$pr" | sed -n 's/.* PREFIX \(.*\) BASE .*/\1/p' | head -1)
  local base; base=$(printf '%s\n' "$pr" | sed -n 's/.* BASE \(.*\)$/\1/p' | head -1)
  if [ -z "$exe" ]; then fail "AC1: python did not run in the container; output: $(printf '%s' "$pr" | head -c 400)"; return; fi
  case "$exe $(printf '%s\n' "$pr" | head -1)" in *"$p/.venv"*) fail "AC1: python resolves into the host .venv ($exe)"; return;; esac
  if [ "$prefix" != "$base" ]; then pass "AC1: python (no path) runs from a container virtualenv ($exe), not the host .venv"
  else fail "AC1: python is not inside a virtualenv (prefix == base_prefix == $prefix)"; fi
}

# ---------------- AC2 ----------------
test_ac2_host_packages_importable_at_same_versions() {
  local p; p=$(new_project ac2) && make_host_venv "$p" || { fail "AC2: fixture setup failed"; return; }
  start_probe "$p" 'python -c "import six, tomli, importlib.metadata as m; print(\"V\", six.__version__, m.version(\"tomli\"))"'
  if probe_part | grep -qx 'V 1.16.0 2.0.1'; then pass "AC2: six 1.16.0 and tomli 2.0.1 import at the host versions"
  else fail "AC2: imports/versions wrong; probe output: $(probe_part | head -c 400)"; fi
}

# ---------------- AC3 ----------------
test_ac3_host_venv_untouched() {
  local p; p=$(new_project ac3) && make_host_venv "$p" || { fail "AC3: fixture setup failed"; return; }
  snapshot "$p/.venv" > "$TMP/ac3.before"
  start_probe "$p" 'python -c "import six, tomli"; pip --version >/dev/null 2>&1 || true'
  start_probe "$p" 'python -c "import six, tomli"'   # second start too: reuse path must not touch it either
  snapshot "$p/.venv" > "$TMP/ac3.after"
  if diff -q "$TMP/ac3.before" "$TMP/ac3.after" >/dev/null; then pass "AC3: host .venv byte-for-byte and mtime identical after two starts"
  else fail "AC3: host .venv changed: $(diff "$TMP/ac3.before" "$TMP/ac3.after" | head -5 | tr '\n' ' ')"; fi
}

# ---------------- AC4 ----------------
test_ac4_unchanged_venv_is_reused_not_reinstalled() {
  local p; p=$(new_project ac4) && make_host_venv "$p" || { fail "AC4: fixture setup failed"; return; }
  start_probe "$p" 'python -c "import six"'
  startup_part | grep -qiE 'Collecting|Downloading|Installing collected|Successfully installed' \
    || echo "note: first start showed no install output (cannot prove first build in output)"
  start_probe "$p" 'python -c "import six, tomli; print(\"OK\")"'
  local s; s=$(startup_part)
  if ! probe_part | grep -qx OK; then fail "AC4: venv unusable after restart: $(probe_part | head -c 300)"; return; fi
  if printf '%s\n' "$s" | grep -qiE 'Collecting|Downloading|Installing collected|Successfully installed'; then
    fail "AC4: restart with unchanged host .venv reinstalled packages: $(printf '%s' "$s" | grep -iE 'Collecting|Downloading|Installing|installed' | head -3 | tr '\n' ' ')"
  else pass "AC4: restart with unchanged host .venv shows no package installation and the venv works"; fi
}

# ---------------- AC5 ----------------
test_ac5_changed_host_packages_are_synced() {
  local p; p=$(new_project ac5) && make_host_venv "$p" || { fail "AC5: fixture setup failed"; return; }
  start_probe "$p" 'python -c "import six"'
  # change: six 1.16.0 -> 1.15.0 (changed version), tomli removed, idna added (one of each)
  host_pip "$p" six==1.15.0 idna==3.4 && "$p/.venv/bin/python" -m pip uninstall -y -q tomli >/dev/null 2>&1 \
    || { fail "AC5: could not mutate host .venv"; return; }
  start_probe "$p" 'python -c "import six, idna, importlib.metadata as m; print(\"V\", six.__version__, idna.__version__)"
    python -c "import tomli" 2>/dev/null && echo TOMLI_PRESENT || echo TOMLI_ABSENT'
  local pr; pr=$(probe_part)
  if printf '%s\n' "$pr" | grep -qx 'V 1.15.0 3.4' && printf '%s\n' "$pr" | grep -qx TOMLI_ABSENT; then
    pass "AC5: container venv follows host change (six changed, idna added, tomli removed)"
  else fail "AC5: container venv did not match the new host set: $(printf '%s' "$pr" | head -c 400)"; fi
}

# ---------------- AC6 ----------------
test_ac6_no_host_venv_startup_unchanged() {
  local p; p=$(new_project ac6) || { fail "AC6: fixture setup failed"; return; }
  start_probe "$p" 'command -v python >/dev/null 2>&1 && python -c "import sys; print(\"PYPFX\", sys.prefix)"; ls -d .venv venv 2>/dev/null; true'
  local s; s=$(startup_part)
  local bad=""
  [ "$RC" -eq 0 ] || bad="$bad rc=$RC;"
  printf '%s\n' "$s" | grep -qiE 'venv|virtualenv|warning|error|pip' && bad="$bad startup output mentions venv/warning/error/pip: $(printf '%s\n' "$s" | grep -iE 'venv|virtualenv|warning|error|pip' | head -2 | tr '\n' ' ');"
  [ -e "$p/.venv" ] && bad="$bad host .venv created;"
  probe_part | grep -E '^(PYPFX|\.venv|venv)' | grep -qE 'venv' && bad="$bad a venv was created/activated;"
  [ -z "$bad" ] && pass "AC6: no .venv => clean startup, no warning, no venv" || fail "AC6:$bad"
}

# ---------------- AC7 ----------------
test_ac7_uninstallable_package_reported_rest_installed() {
  local p; p=$(new_project ac7) && make_host_venv "$p" || { fail "AC7: fixture setup failed"; return; }
  start_probe "$p" 'python -c "import six, tomli, importlib.metadata as m; print(\"V\", six.__version__, m.version(\"tomli\"))"'
  local bad=""
  probe_part | grep -qx 'V 1.16.0 2.0.1' || bad="$bad remaining packages not installed ($(probe_part | head -c 200));"
  startup_part | grep -qi "$BADPKG" || bad="$bad startup output does not name $BADPKG;"
  printf '%s\n' "$OUT" | grep -q '=== PROBE ===' || bad="$bad startup did not complete;"
  [ -z "$bad" ] && pass "AC7: startup completes, names $BADPKG, installs the other packages" || fail "AC7:$bad"
}

# ---------------- AC8 ----------------
test_ac8_venv_not_in_git_status() {
  local p; p=$(new_project ac8) && make_host_venv "$p" || { fail "AC8: fixture setup failed"; return; }
  start_probe "$p" 'echo "BEFORE:"; git status --porcelain; echo hello > af_new_file.txt; echo "AFTER:"; git status --porcelain; python -c "import six"; echo "PYOK"'
  local pr; pr=$(probe_part)
  local before after
  before=$(printf '%s\n' "$pr" | sed -n '/^BEFORE:$/,/^AFTER:$/p' | sed '1d;$d')
  after=$(printf '%s\n' "$pr" | sed -n '/^AFTER:$/,/^PYOK$/p' | sed '1d;$d')
  if ! printf '%s\n' "$pr" | grep -qx PYOK; then fail "AC8: probe did not complete: $(printf '%s' "$pr" | head -c 300)"; return; fi
  if [ -z "$before" ] && [ "$after" = "?? af_new_file.txt" ]; then pass "AC8: clone's git status shows nothing from the venv (only the agent's own new file)"
  else fail "AC8: git status polluted. before=[$before] after=[$after]"; fi
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
finish
