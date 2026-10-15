#!/usr/bin/env bash
# Acceptance tests for agent-factory-ncij (dev language toolchains in the agent image).
# One test per acceptance criterion in docs/stories/agent-factory-ncij.md:
#   bash tests/agent-factory-ncij_test.sh
# Written before implementation, from the story only.
# Needs docker + network (the Dockerfile pulls npm/go packages); builds from a scratch copy of the
# repo under throwaway tags (both HARNESS values), so factory-agent:latest is never touched.
# Without docker every test is SKIPped (reported, not failed).
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"

pass=0; fail=0; skip=0
ok()   { echo "PASS: $1"; pass=$((pass+1)); }
bad()  { echo "FAIL: $1"; fail=$((fail+1)); }
skp()  { echo "SKIP: $1"; skip=$((skip+1)); }

cleanup_dirs=(); cleanup_imgs=()
cleanup() {
  for i in "${cleanup_imgs[@]}"; do docker rmi -f "$i" >/dev/null 2>&1; done
  for d in "${cleanup_dirs[@]}"; do rm -rf "$d"; done
}
trap cleanup EXIT

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then HAVE_DOCKER=1; fi
RUN_ID="t$$"
W=$(mktemp -d); cleanup_dirs+=("$W")
HARNESSES="claude-code copilot"
declare -A RC

if [ "$HAVE_DOCKER" = 1 ]; then
  CTX=$(mktemp -d); cleanup_dirs+=("$CTX")
  git -C "$KIT_DIR" archive HEAD | tar -x -C "$CTX"
  for h in $HARNESSES; do
    cleanup_imgs+=("af-ncij-$h-$RUN_ID")
    docker build --build-arg HARNESS="$h" -t "af-ncij-$h-$RUN_ID" "$CTX" >"$W/build-$h.log" 2>&1
    RC[$h]=$?
  done
fi

# check <name> <harness> <shell-snippet>: run the snippet in the image as its default (non-root) user.
check() {
  local n=$1 h=$2; shift 2
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker)"; return; }
  [ "${RC[$h]}" = 0 ] || { bad "$n - build failed: $(tail -5 "$W/build-$h.log")"; return; }
  local out
  out=$(docker run --rm --entrypoint bash "af-ncij-$h-$RUN_ID" -c \
    '[ "$(id -u)" != 0 ] || { echo "ran as root"; exit 1; }; set -e; '"$*" 2>&1) \
    && ok "$n" || bad "$n - $out"
}

ac1()  { check "AC1 [$1] python3 and pip run as non-root" "$1" 'python3 --version; pip --version'; }
ac2()  { check "AC2 [$1] venv can be created and its python runs" "$1" \
  'd=$(mktemp -d); python3 -m venv "$d/v"; "$d/v/bin/python" --version | grep -q "^Python 3"'; }
ac3()  { check "AC3 [$1] perl runs" "$1" 'perl --version | grep -qi perl'; }
ac4()  { check "AC4 [$1] java and javac run" "$1" 'java -version; javac -version'; }
ac5()  { check "AC5 [$1] node and npm run" "$1" 'node --version; npm --version'; }
ac6()  { check "AC6 [$1] gcc, g++ and make run" "$1" 'gcc --version; g++ --version; make --version'; }
ac7c() { check "AC7 [$1] trivial C program compiles and runs" "$1" \
  'd=$(mktemp -d); printf "#include <stdio.h>\nint main(void){puts(\"hello-c\");return 0;}\n" >"$d/t.c"
   gcc -o "$d/t" "$d/t.c"; [ "$("$d/t")" = hello-c ]'; }
ac7cpp() { check "AC7 [$1] trivial C++ program compiles and runs" "$1" \
  'd=$(mktemp -d); printf "#include <iostream>\nint main(){std::cout<<\"hello-cpp\"<<std::endl;return 0;}\n" >"$d/t.cpp"
   g++ -o "$d/t" "$d/t.cpp"; [ "$("$d/t")" = hello-cpp ]'; }
ac8()  { check "AC8 [$1] harness CLI, bd, git, jq, curl, shellcheck still work" "$1" \
  'h='"$([ "$1" = claude-code ] && echo claude || echo copilot)"'
   command -v "$h"; "$h" --version; bd --version; git --version; jq --version; curl --version; shellcheck --version'; }

for h in $HARNESSES; do
  ac1 "$h"; ac2 "$h"; ac3 "$h"; ac4 "$h"; ac5 "$h"; ac6 "$h"; ac7c "$h"; ac7cpp "$h"; ac8 "$h"
done

echo "passed=$pass failed=$fail skipped=$skip"
[ "$fail" -eq 0 ]
