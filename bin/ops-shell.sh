#!/usr/bin/env bash
source /work/bin/env.sh
git config --global --add safe.directory '*' 2>/dev/null
cd /work/repo 2>/dev/null || true
export PATH="/work/bin:$PATH"
echo 'Ops shell.  bd ready | bd blocked | feature.sh "Title" "desc" | approve.sh <id> | smoke-test.sh'
exec bash
