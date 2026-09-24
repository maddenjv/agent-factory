#!/usr/bin/env bash
# Acceptance tests for agent-factory-6k7: "Document CONTAINER_HOME and correct the
# container-identity description".
#
# Doc-only story (see docs/design/agent-factory-6k7.md's "Test strategy" - no
# make test/script exists for this repo's docs, see ARCHITECTURE.md "Test strategy"), so these
# are plain shell assertions over docs/ARCHITECTURE.md's "Stack" section and README.md's "Setup"
# section, one function per acceptance criterion in docs/stories/agent-factory-6k7.md.
#
# Run directly: bash tests/agent-factory-6k7_test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# Extract docs/ARCHITECTURE.md's "Stack" section (from "## Stack" up to the next "## " heading).
arch_stack_section() {
  sed -n '/^## Stack/,/^## /p' docs/ARCHITECTURE.md | sed '$d'
}

# Extract README.md's "Setup" section (from "## Setup" up to the next "## " heading).
readme_setup_section() {
  sed -n '/^## Setup/,/^## /p' README.md | sed '$d'
}

# --- AC1: ARCHITECTURE.md's Stack section states the account is fixed by the Dockerfile
#          (host user via HOST_USER/HOST_UID/HOST_GID, /home/<host user>) AND separately describes CONTAINER_HOME as a
#          dependent setting used only for docker-compose.yml mounts + agent-loop.sh's sync ---
test_ac1_architecture_distinguishes_fixed_account_from_container_home() {
  local section
  section="$(arch_stack_section)"
  if [ -z "$section" ]; then
    fail "ac1: could not find '## Stack' section in docs/ARCHITECTURE.md"
    return
  fi

  local ok=1
  echo "$section" | grep -q 'HOST_USER' || { fail "ac1: Stack section no longer mentions HOST_USER"; ok=0; }
  echo "$section" | grep -q 'HOST_UID' || { fail "ac1: Stack section no longer mentions HOST_UID"; ok=0; }
  echo "$section" | grep -q '/home/\(<host user>\|\$HOST_USER\)' || { fail "ac1: Stack section no longer mentions the host-derived home path"; ok=0; }
  echo "$section" | grep -q 'Dockerfile' || { fail "ac1: Stack section does not attribute the account to the Dockerfile"; ok=0; }
  [ "$ok" = 1 ] || return

  if ! echo "$section" | grep -q 'CONTAINER_HOME'; then
    fail "ac1: Stack section does not mention CONTAINER_HOME at all (expected as a separate, dependent setting)"
    return
  fi

  # CONTAINER_HOME's two documented uses: docker-compose.yml mount paths, and agent-loop.sh's
  # host-config sync (see docs/design/agent-factory-6k7.md's "Files to change" for ARCHITECTURE.md).
  local uses_ok=1
  echo "$section" | grep -qi 'docker-compose\|mount' || { fail "ac1: Stack section's CONTAINER_HOME description doesn't mention the docker-compose.yml mount-path use"; uses_ok=0; }
  echo "$section" | grep -qi 'agent-loop\|sync' || { fail "ac1: Stack section's CONTAINER_HOME description doesn't mention agent-loop.sh's host-config sync use"; uses_ok=0; }
  [ "$uses_ok" = 1 ] || return

  pass "ac1: ARCHITECTURE.md's Stack section distinguishes the fixed Dockerfile account from CONTAINER_HOME's dependent, mount/sync-only role"
}

# --- AC2: README's Setup section mentions CONTAINER_HOME, its default, and that bin/init.sh
#          auto-populates it into .env alongside HOST_UID/HOST_GID ---
test_ac2_readme_documents_container_home() {
  local section
  section="$(readme_setup_section)"
  if [ -z "$section" ]; then
    fail "ac2: could not find '## Setup' section in README.md"
    return
  fi

  if ! echo "$section" | grep -q 'CONTAINER_HOME'; then
    fail "ac2: Setup section does not mention CONTAINER_HOME"
    return
  fi
  if ! echo "$section" | grep -q '/home/<host user>'; then
    fail "ac2: Setup section mentions CONTAINER_HOME but not its default (/home/<host user>)"
    return
  fi
  if ! echo "$section" | grep -q 'init\.sh'; then
    fail "ac2: Setup section does not attribute CONTAINER_HOME's .env population to bin/init.sh"
    return
  fi
  if ! echo "$section" | grep -qi 'HOST_UID'; then
    fail "ac2: Setup section doesn't tie CONTAINER_HOME's auto-population to HOST_UID/HOST_GID (expected: 'alongside HOST_UID/HOST_GID')"
    return
  fi
  pass "ac2: README's Setup section documents CONTAINER_HOME, its default, and init.sh's auto-population alongside HOST_UID/HOST_GID"
}

# --- AC3: no other drift in the two sections vs. the four source files - regression guard on
#          facts the design's read-through already confirmed match (spot checks, not exhaustive:
#          a full read-through is a human/QA-by-inspection step per the design's Test strategy) ---
test_ac3_no_other_drift_regressions() {
  local arch readme ok=1
  arch="$(arch_stack_section)"
  readme="$(readme_setup_section)"

  # ARCHITECTURE.md Stack: other claims that must still hold (Dockerfile-image details, unrelated
  # to this story but must not have been disturbed by the edit).
  echo "$arch" | grep -q 'bookworm' || { fail "ac3: ARCHITECTURE.md Stack section no longer mentions the Debian bookworm base (unrelated drift introduced by this edit)"; ok=0; }
  echo "$arch" | grep -q 'beads' || { fail "ac3: ARCHITECTURE.md Stack section no longer mentions bd/beads (unrelated drift introduced by this edit)"; ok=0; }

  # README Setup: other claims that must still hold.
  echo "$readme" | grep -q 'KIT_DIR' || { fail "ac3: README Setup section no longer mentions KIT_DIR (unrelated drift introduced by this edit)"; ok=0; }
  echo "$readme" | grep -q 'PROJECT_DIR' || { fail "ac3: README Setup section no longer mentions PROJECT_DIR (unrelated drift introduced by this edit)"; ok=0; }
  echo "$readme" | grep -q 'receive.denyCurrentBranch=updateInstead' || { fail "ac3: README Setup section no longer mentions init.sh's receive.denyCurrentBranch=updateInstead behavior (unrelated drift introduced by this edit)"; ok=0; }

  [ "$ok" = 1 ] && pass "ac3: spot-checked unrelated facts in both sections are undisturbed (full line-by-line read-through against the four source files is a QA-by-inspection step, see docs/design/agent-factory-6k7.md's Test strategy)"
}

# --- AC4: neither edited passage claims or implies CONTAINER_HOME can be changed safely on its
#          own without touching the Dockerfile ---
test_ac4_no_independent_relocation_claim() {
  local section
  section="$(arch_stack_section)"

  if ! echo "$section" | grep -qi 'CONTAINER_HOME'; then
    fail "ac4: cannot check independent-relocation phrasing - Stack section doesn't mention CONTAINER_HOME yet (see ac1)"
    return
  fi

  # Phrasing that would violate AC4: implying CONTAINER_HOME alone relocates the account's home.
  if echo "$section" | grep -Eqi 'CONTAINER_HOME[^.]*(relocat|change the (container|agent)|move the home)'; then
    fail "ac4: Stack section's CONTAINER_HOME description reads as an independent relocation knob:
$section"
    return
  fi

  # The dependency on the Dockerfile must be stated explicitly (not merely implied), per the
  # design's "not an independent way to relocate the account's home" requirement.
  if ! echo "$section" | grep -qi 'Dockerfile'; then
    fail "ac4: Stack section's CONTAINER_HOME description doesn't tie it back to the Dockerfile-fixed account"
    return
  fi

  pass "ac4: ARCHITECTURE.md's CONTAINER_HOME description does not claim or imply independent relocation, and is tied back to the Dockerfile"
}

test_ac1_architecture_distinguishes_fixed_account_from_container_home
test_ac2_readme_documents_container_home
test_ac3_no_other_drift_regressions
test_ac4_no_independent_relocation_claim

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
