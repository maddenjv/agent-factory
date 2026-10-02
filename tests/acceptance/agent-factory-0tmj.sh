#!/usr/bin/env bash
# Acceptance tests for agent-factory-0tmj (agent image builds when no dotfiles/ exist).
# One test function per acceptance criterion in docs/stories/agent-factory-0tmj.md:
#   bash tests/acceptance/agent-factory-0tmj.sh
# Written before implementation, from the story only.
# Image tests need docker + network (the Dockerfile pulls npm/go packages) and build from a scratch
# copy of the repo under throwaway tags, so factory-agent:latest is never touched. Without docker
# they are SKIPped (reported, not failed); the git-ignore/doc check (AC4, AC5) always runs.
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
mktmp() { local d; d=$(mktemp -d); cleanup_dirs+=("$d"); echo "$d"; }

HAVE_DOCKER=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then HAVE_DOCKER=1; fi
RUN_ID="t$$"
W=$(mktmp)

# make_ctx <mode>: scratch build context = tracked tree, with dotfiles/ forced into a known state
#   absent  - unmodified git archive of HEAD (fresh clone: dotfiles/ holds only the tracked .gitkeep)
#   empty   - dotfiles/ exists but is completely empty (.gitkeep removed too)
#   full    - dotfiles/ holds .bashrc and .gitconfig
make_ctx() {
  local d; d=$(mktmp)
  git -C "$KIT_DIR" archive HEAD | tar -x -C "$d"
  case "$1" in
    empty) rm -rf "$d/dotfiles"; mkdir -p "$d/dotfiles" ;;
    full)  rm -rf "$d/dotfiles"; mkdir -p "$d/dotfiles"
           echo "# af-test-bashrc-$RUN_ID" > "$d/dotfiles/.bashrc"
           printf '[user]\n\tname = af-test-%s\n' "$RUN_ID" > "$d/dotfiles/.gitconfig" ;;
  esac
  echo "$d"
}
img() { echo "af-0tmj-$1-$RUN_ID"; }
build_img() {  # <ctx> <suffix>; log in $W/build-<suffix>.log
  cleanup_imgs+=("$(img "$2")")
  docker build -t "$(img "$2")" "$1" >"$W/build-$2.log" 2>&1
}
in_img() { local s=$1; shift; docker run --rm --entrypoint bash "$(img "$s")" -c "$*"; }

if [ "$HAVE_DOCKER" = 1 ]; then
  build_img "$(make_ctx absent)" A; A_RC=$?
  build_img "$(make_ctx empty)"  B; B_RC=$?
  build_img "$(make_ctx full)"   C; C_RC=$?
fi

test_ac1_no_dotfiles_dir_builds() {
  local n="AC1 no dotfiles/ directory: image build succeeds"
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker)"; return; }
  [ "$A_RC" = 0 ] && ok "$n" || bad "$n - $(tail -5 "$W/build-A.log")"
}

test_ac1_gitkeep_not_in_home() {
  local n="AC1/AC3 .gitkeep placeholder does not land in the image's home dir"
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker)"; return; }
  local s out
  for s in A B C; do
    out=$(in_img $s 'h=$(getent passwd "$(id -un)" | cut -d: -f6); ls -A "$h"; [ ! -e "$h/.gitkeep" ]' 2>&1) \
      || { bad "$n - image $s has .gitkeep in home: $out"; return; }
  done
  ok "$n"
}

test_ac2_empty_dotfiles_dir_builds() {
  local n="AC2 empty dotfiles/ directory: image build succeeds"
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker)"; return; }
  [ "$B_RC" = 0 ] && ok "$n" || bad "$n - $(tail -5 "$W/build-B.log")"
}

test_ac3_supplied_dotfiles_in_home_owned_by_user() {
  local n="AC3 supplied .bashrc/.gitconfig land in user's home, owned by that user"
  [ "$HAVE_DOCKER" = 1 ] || { skp "$n (no docker)"; return; }
  [ "$C_RC" = 0 ] || { bad "$n - build failed: $(tail -5 "$W/build-C.log")"; return; }
  local out
  out=$(in_img C 'u=$(id -un); h=$(getent passwd "$u" | cut -d: -f6)
    for f in .bashrc .gitconfig; do
      [ -f "$h/$f" ] || { echo "missing $h/$f"; exit 1; }
      [ "$(stat -c %U "$h/$f")" = "$u" ] || { echo "$h/$f owned by $(stat -c %U "$h/$f")"; exit 1; }
    done
    grep -q "af-test-bashrc-'"$RUN_ID"'" "$h/.bashrc" || { echo ".bashrc content wrong"; exit 1; }
    grep -q "af-test-'"$RUN_ID"'" "$h/.gitconfig" || { echo ".gitconfig content wrong"; exit 1; }
    [ "$u" != root ] || { echo "ran as root"; exit 1; }' 2>&1) \
    && ok "$n" || bad "$n - $out"
}

test_ac4_dotfiles_never_tracked() {
  local n="AC4 files in dotfiles/ stay git-ignored"
  local d st; d=$(mktmp)
  git -C "$KIT_DIR" archive HEAD | tar -x -C "$d"
  git -C "$d" init -q -b main; git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c user.email=t@t -c user.name=t commit -q -m base
  mkdir -p "$d/dotfiles"
  echo "x" > "$d/dotfiles/.bashrc"; echo "x" > "$d/dotfiles/.gitconfig"; echo "x" > "$d/dotfiles/aliases"
  st=$(git -C "$d" status --porcelain)
  if grep -q dotfiles <<<"$st"; then bad "$n - dotfiles content shows in git status: $st"; else ok "$n"; fi
}

test_ac5_docs_say_optional() {
  local n="AC5 README.md and docs/ARCHITECTURE.md describe dotfiles/ as optional"
  local f missing=""
  for f in README.md docs/ARCHITECTURE.md; do
    # every file that mentions dotfiles/ must say optional on a line mentioning it (or adjacent)
    if grep -qi 'dotfiles' "$f"; then
      grep -i -B2 -A2 'dotfiles' "$f" | grep -qi 'optional' || missing="$missing $f"
    fi
  done
  grep -qi 'dotfiles' docs/ARCHITECTURE.md || missing="$missing docs/ARCHITECTURE.md(no-mention)"
  [ -z "$missing" ] && ok "$n" || bad "$n - no 'optional' near dotfiles in:$missing"
}

test_ac1_no_dotfiles_dir_builds
test_ac1_gitkeep_not_in_home
test_ac2_empty_dotfiles_dir_builds
test_ac3_supplied_dotfiles_in_home_owned_by_user
test_ac4_dotfiles_never_tracked
test_ac5_docs_say_optional

echo "passed=$pass failed=$fail skipped=$skip"
[ "$fail" -eq 0 ]
