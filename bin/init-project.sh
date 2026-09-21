#!/usr/bin/env bash
# Runs once inside a container: seeds the project repo (CLAUDE.md, docs/, .beads) and pushes main.
set -euo pipefail
cd /work/repo
git config --global user.name "factory-init"
git config --global user.email "init@factory.local"
git config --global --add safe.directory '*'

[ -d .git ] || git clone -q /origin.git . 2>/dev/null || git init -q -b main
git remote get-url origin >/dev/null 2>&1 || git remote add origin /origin.git
git checkout -q -B main

mkdir -p docs/stories docs/design
touch docs/stories/.gitkeep docs/design/.gitkeep
[ -f CLAUDE.md ] || cp /work/agents/CLAUDE.project.md CLAUDE.md

# Beads: server mode against the shared Dolt container. Deliberately NO BEADS_DOLT_* env here.
if [ ! -d .beads ]; then
  bd init --quiet --server --server-host dolt --server-port 3306
fi
bd setup claude >/dev/null 2>&1 || true

# The JSONL export is noise in git when several agents work in parallel (merge conflicts),
# and Dolt is the source of truth. Keep it out of history.
grep -qxF '.beads/issues.jsonl' .gitignore 2>/dev/null || echo '.beads/issues.jsonl' >> .gitignore
git rm -q -r --cached --ignore-unmatch .beads/issues.jsonl >/dev/null 2>&1 || true

git add -A
git commit -q --no-verify -m "Initialise project scaffolding and Beads" || true
git push -q --no-verify -u origin main
echo "Seeded /origin.git (main) and initialised Beads."
bd ready --json >/dev/null && echo "bd can reach the Dolt server: OK"
