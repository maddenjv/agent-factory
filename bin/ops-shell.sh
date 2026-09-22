#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
KIT_DIR="${KIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
git config --global --add safe.directory '*' 2>/dev/null
export PATH="$KIT_DIR/bin:$PATH"
echo 'Ops shell.  bd ready | bd blocked | feature.sh "Title" "desc" | approve.sh <id> | smoke-test.sh'
echo "Project: ${PROJECT_DIR:-$PWD}"
exec bash
