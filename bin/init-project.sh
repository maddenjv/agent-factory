#!/usr/bin/env bash
# Runs once inside a container, directly against PROJECT_DIR (no separate clone, no relay repo -
# see bin/lib.sh): adds beads + story/design scaffolding to the real project and commits it.
set -euo pipefail
KIT_DIR="${KIT_DIR:?KIT_DIR must be set}"
PROJECT_DIR="${PROJECT_DIR:?PROJECT_DIR must be set}"
cd "$PROJECT_DIR"
git config --global --add safe.directory '*' 2>/dev/null || true

branch=$(git symbolic-ref --short -q HEAD || true)
if [ "$branch" != "main" ]; then
  echo "error: $PROJECT_DIR is on branch '${branch:-<detached HEAD>}', not main." >&2
  echo "agent-factory's flow assumes a 'main' trunk (see agents/CLAUDE.project.md)." >&2
  echo "git checkout main here first, then re-run bin/init.sh." >&2
  exit 1
fi
# (the clean-working-tree check runs once, host-side, in bin/init.sh - before it creates
# .agent-factory/, which would otherwise make this repo look "dirty" to a check run from here)

mkdir -p docs/stories docs/design
touch docs/stories/.gitkeep docs/design/.gitkeep

# Multi-agent conventions (roles, beads workflow, needs-human). A brand-new project gets this
# file outright; a project with its own CLAUDE.md already (the normal case) gets it appended,
# once - grep guards against doubling it up on a repeat bin/init.sh run.
if [ -f CLAUDE.md ]; then
  grep -qF 'Project conventions (shared by every agent)' CLAUDE.md \
    || { printf '\n\n---\n\n' >> CLAUDE.md; cat "$KIT_DIR/agents/CLAUDE.project.md" >> CLAUDE.md; }
else
  cp "$KIT_DIR/agents/CLAUDE.project.md" CLAUDE.md
fi

# Own runtime state (workspaces, control, logs, claude config, the dolt db) - never committed.
grep -qxF '.agent-factory/' .gitignore 2>/dev/null || echo '.agent-factory/' >> .gitignore

# Beads: server mode against the shared Dolt container. Deliberately NO BEADS_DOLT_* env here -
# `bd init` has been reported to skip creating .beads/ when those are already set.
if [ ! -d .beads ]; then
  bd init --quiet --server --server-host dolt --server-port 3306
fi
bd setup claude >/dev/null 2>&1 || true

# The JSONL export is noise in git when several agents work in parallel (merge conflicts),
# and Dolt is the source of truth. Keep it out of history.
grep -qxF '.beads/issues.jsonl' .gitignore 2>/dev/null || echo '.beads/issues.jsonl' >> .gitignore
git rm -q -r --cached --ignore-unmatch .beads/issues.jsonl >/dev/null 2>&1 || true

# Explicit paths only - never -A/., so an unrelated in-progress change in this project can't get
# swept into this commit.
git add docs/stories docs/design .gitignore .beads CLAUDE.md 2>/dev/null || true
if ! git diff --cached --quiet; then
  git commit -q --no-verify -m "agent-factory: scaffolding and beads init"
  echo "Committed agent-factory scaffolding to $PROJECT_DIR (main)."
else
  echo "agent-factory scaffolding already present in $PROJECT_DIR; nothing to commit."
fi
bd ready --json >/dev/null && echo "bd can reach the Dolt server: OK"
