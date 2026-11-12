#!/usr/bin/env bash
# Acceptance tests for agent-factory-ape0: README.md is back in sync with the implementation.
# The story's single criterion is "review README against the implementation and update it";
# these tests turn that into checkable claims (test_acN_...), all derived from README vs. repo:
#   AC1  every script/file path README mentions exists
#   AC2  user-facing bin scripts (restart-story.sh, smoke-test.sh) are documented
#   AC3  tmux layout described matches bin/start.sh (team-lead pane; board lives in ops window)
#   AC4  every env var README names is known to .env.example or the code; guardrail knobs are named
#   AC5  README section headings cited by other docs exist ("Before running unattended")
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$KIT_DIR/README.md"
FAILS=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }

test_ac1_referenced_files_exist() {
  local missing="" p
  while IFS= read -r p; do
    [ -e "$KIT_DIR/$p" ] || missing+=" $p"
  done < <(grep -oE '\b(bin|agents|docs|tests)/[A-Za-z0-9_./-]*[A-Za-z0-9_]\.(sh|md|yml)\b' "$README" | grep -v '<' | sort -u)
  # bare script names (feature.sh, approve.sh, ...) must exist in bin/
  while IFS= read -r p; do
    [ -e "$KIT_DIR/bin/$p" ] || missing+=" bin/$p"
  done < <(grep -oE '(^|[^/A-Za-z0-9_-])[a-z0-9]+(-[a-z0-9]+)*\.sh\b' "$README" | sed -E 's/^[^a-z0-9]//' | sort -u)
  [ -z "$missing" ] && pass "ac1: every file README references exists" || fail "ac1: README references missing files:$missing"
}

test_ac2_user_facing_scripts_documented() {
  local s missing=""
  for s in restart-story.sh smoke-test.sh; do
    grep -q "$s" "$README" || missing+=" $s"
  done
  [ -z "$missing" ] && pass "ac2: README documents restart-story.sh and smoke-test.sh" || fail "ac2: README never mentions:$missing"
}

test_ac3_tmux_layout_matches_start_sh() {
  local ok=1
  # start.sh creates a team-lead pane in the agents window
  grep -n 'pane team-lead' "$KIT_DIR/bin/start.sh" >/dev/null || { fail "ac3: precondition: start.sh has no team-lead pane"; return; }
  if ! grep -qiE 'panes?:?[^.]*team-lead|team-lead[^.]*pane' "$README"; then
    fail "ac3: README does not say team-lead has a pane in the agents window"; ok=0
  fi
  # board is in the ops window, not the agents window
  if grep -qE 'panes: board po|board \| po' "$README"; then
    fail "ac3: README still lists the board as a pane of the agents window (start.sh puts it in ops)"; ok=0
  fi
  if ! grep -qiE 'board[^.]*ops|ops[^.]*board' "$README"; then
    fail "ac3: README does not say the board is in the ops window"; ok=0
  fi
  [ $ok = 1 ] && pass "ac3: README tmux layout matches start.sh"
}

test_ac4_env_vars_consistent() {
  local v missing="" unknown=""
  for v in MAX_TURNS ITERATION_TIMEOUT MAX_ATTEMPTS_PER_ISSUE MAX_CONSECUTIVE_FAILURES; do
    grep -qw "$v" "$README" || missing+=" $v"
  done
  while IFS= read -r v; do
    grep -qw "$v" "$KIT_DIR/.env.example" || grep -rqw "$v" "$KIT_DIR/bin" "$KIT_DIR/docker-compose.yml" "$KIT_DIR/agents" || unknown+=" $v"
  done < <(grep -oE '\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b' "$README" | grep -E '^(SYSTEM1|MODEL|MAX|DAILY|HUMAN|NOTIFY|QUOTA|DOLT|HOST|CONTAINER|HARNESS|ITERATION|IDLE|ALERT)_' | sort -u)
  [ -z "$missing" ] || fail "ac4: guardrail env vars not named in README:$missing"
  [ -z "$unknown" ] || fail "ac4: README names env vars absent from .env.example/code:$unknown"
  [ -z "$missing$unknown" ] && pass "ac4: README env vars consistent with .env.example/code"
}

test_ac5_cited_readme_sections_exist() {
  local sec missing=""
  while IFS= read -r sec; do
    grep -qE "^#+ .*$sec" "$README" || missing+=" [$sec]"
  done < <(grep -rhoE 'README "[^"]+"' "$KIT_DIR/docs/ARCHITECTURE.md" "$KIT_DIR/bin" "$KIT_DIR/agents" 2>/dev/null | sed -E 's/README "//; s/"$//' | sort -u)
  # ARCHITECTURE.md wraps this citation over two lines
  grep -qE '^#+ .*Before running unattended' "$README" || missing+=" [Before running unattended]"
  [ -z "$missing" ] && pass "ac5: README sections cited elsewhere exist" || fail "ac5: cited README sections missing:$missing"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
[ "$FAILS" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILS FAILED"; exit 1; }
