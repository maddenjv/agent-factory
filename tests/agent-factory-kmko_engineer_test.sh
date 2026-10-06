#!/usr/bin/env bash
# Engineer unit tests for agent-factory-kmko: init-project.sh commits without any git identity,
# never writes identity to config, and honours identity env vars. No Docker needed (bd stubbed).
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bin"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/bd"; chmod +x "$T/bin/bd"
fail=0; ok() { [ "$1" = 0 ] && echo "ok - $2" || { echo "FAIL - $2"; fail=1; }; }

run() { # run <dir> [env...]; no host identity at any level
  ( cd "$1" && shift && env -i PATH="$T/bin:$PATH" HOME="$T/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      KIT_DIR="$KIT" PROJECT_DIR="$PWD" BEADS_DIR=x "$@" bash "$KIT/bin/init-project.sh" ) 2>&1
}
mkrepo() { mkdir -p "$T/home" "$1"; git -C "$1" init -q -b main; mkdir "$1/.beads"; }

mkrepo "$T/a"; before=$(sha1sum "$T/a/.git/config")
out=$(run "$T/a"); ok $? "no identity: exits 0"
[ "$(git -C "$T/a" log -1 --format=%an main)" = agent-factory ]; ok $? "default author"
[ "$(sha1sum "$T/a/.git/config")" = "$before" ]; ok $? "git config untouched"
out=$(run "$T/a"); ok $? "rerun exits 0"; echo "$out" | grep -q 'already present'; ok $? "rerun reports already present"

mkrepo "$T/b"
run "$T/b" GIT_AUTHOR_NAME=Jo GIT_AUTHOR_EMAIL=jo@x.org >/dev/null; ok $? "env identity exits 0"
[ "$(git -C "$T/b" log -1 --format='%an <%ae> %cn')" = "Jo <jo@x.org> Jo" ]; ok $? "env identity used"

mkrepo "$T/c"
run "$T/c" GIT_AUTHOR_NAME=Jo >/dev/null; ok $? "only name exits 0"
[ "$(git -C "$T/c" log -1 --format='%an %ae')" = "Jo agent-factory@factory.local" ]; ok $? "only name: email defaulted"

grep -q 'GIT_AUTHOR_NAME="\$git_name"' "$KIT/bin/init.sh" && grep -q 'GIT_COMMITTER_EMAIL="\$git_email"' "$KIT/bin/init.sh"; ok $? "init.sh passes identity env"
! grep -nE 'git config .*user\.(name|email)' "$KIT"/bin/init.sh "$KIT"/bin/init-project.sh | grep -v 'git -C "\$PROJECT_DIR" config user\.' >/dev/null; ok $? "no identity writes"
exit $fail
