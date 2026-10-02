#!/usr/bin/env bash
# Tests for agent-factory-eyiz: bin/init.sh's "Created .env" message names the chosen harness only.
# Run: bash tests/agent-factory-eyiz_test.sh   (exit non-zero if any FAIL). Docker is stubbed.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
tmps=(); trap 'rm -rf "${tmps[@]}"' EXIT

stub=$(mktemp -d); tmps+=("$stub")
printf '#!/usr/bin/env bash\ncase " $* " in *" run "*) ( cd "$PROJECT_DIR" && { echo ".agent-factory/" >> .gitignore; git add .gitignore && git commit -q -m s; } );; esac\nexit 0\n' > "$stub/docker"
chmod +x "$stub/docker"

run_init() {  # args -> init.sh output
  local kit proj
  kit=$(mktemp -d); proj=$(mktemp -d); tmps+=("$kit" "$proj")
  (cd "$KIT_DIR" && tar --exclude=.git -c .) | tar -x -C "$kit"
  git -C "$proj" init -q -b main
  git -C "$proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
  git -C "$proj" config user.email t@t; git -C "$proj" config user.name t
  (cd "$proj" && PATH="$stub:$PATH" PROJECT_DIR="$proj" "$kit/bin/init.sh" "$@" 2>&1)
}

out=$(run_init --harness=copilot)
echo "$out" | grep -q 'Created' && echo "$out" | grep -q '~/.copilot' && echo "$out" | grep -q 'copilot login' \
  && echo "$out" | grep -q 'COPILOT_GITHUB_TOKEN / GH_TOKEN / GITHUB_TOKEN' && ok "AC1 copilot message" || bad "AC1 copilot message"
echo "$out" | grep -Eq '~/\.claude|CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|Claude' && bad "AC2 no claude refs" || ok "AC2 no claude refs"

for a in "" --harness=claude-code; do
  out=$(run_init $a)
  echo "$out" | grep -q '~/.claude' && echo "$out" | grep -q 'CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY' && ok "AC1 claude message ($a)" || bad "AC1 claude message ($a)"
  echo "$out" | grep -Eq '~/\.copilot|COPILOT_GITHUB_TOKEN|GH_TOKEN|GITHUB_TOKEN' && bad "AC3 no copilot refs ($a)" || ok "AC3 no copilot refs ($a)"
done
echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
