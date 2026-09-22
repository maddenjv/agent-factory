#!/usr/bin/env bash
# Runs once inside a container, directly against PROJECT_DIR (no separate clone, no relay repo -
# see bin/lib.sh): adds beads + story/design scaffolding to the real project and commits it.
set -euo pipefail
KIT_DIR="${KIT_DIR:?KIT_DIR must be set}"
PROJECT_DIR="${PROJECT_DIR:?PROJECT_DIR must be set}"
# shellcheck disable=SC1091
source "$KIT_DIR/bin/env.sh"   # BEADS_DOLT_SERVER_HOST=dolt etc - every bd call below needs it
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

# Beads: server mode against the shared Dolt container, connecting here via its Docker-internal
# hostname (this runs inside a container - BEADS_DOLT_SERVER_HOST=dolt from env.sh, above, also
# covers this). `bd init` has been reported to skip creating .beads/ when BEADS_DOLT_* env vars
# are already set, so pass them as flags instead, same values.
if [ ! -d .beads ]; then
  # bd auto-detects a configured "origin" remote and tries to verify refs/dolt/data on it over
  # SSH - which hangs/fails here (no SSH keys in the container, deliberately - see README) and,
  # worse, has been seen to cascade into a failed database creation. Our issues live ONLY in the
  # shared Dolt server (see docker-compose.yml); nothing about them is meant to sync via your
  # project's real git remote, so origin is hidden from bd for this one command. The trap
  # restores it on any exit from this script, success or failure - never left off by an error.
  origin_url=$(git remote get-url origin 2>/dev/null || true)
  if [ -n "$origin_url" ]; then
    git remote remove origin
    trap 'git remote get-url origin >/dev/null 2>&1 || git remote add origin "$origin_url"' EXIT
  fi
  bd init --quiet --server --server-host dolt --server-port 3306
  bd config set dolt.local-only true >/dev/null 2>&1 || true   # belt and braces for later bd calls
  # ...but "dolt" isn't reachable from your own host shell, only from inside a container. Every
  # bd call in THIS script still goes through it fine (BEADS_DOLT_SERVER_HOST above overrides
  # whatever's on disk), so it's safe to repoint the file here at the loopback address
  # docker-compose.yml publishes the port on - letting `bd` work directly from PROJECT_DIR on
  # your host too, not just from inside a container pane. The port goes in .beads/dolt-server.port
  # (the primary source bd now expects it from) rather than metadata.json's dolt_server_port,
  # which bd deprecated (a stray copy left in metadata.json can leak into a DIFFERENT project's
  # config if it's ever cloned/copied as a template) - removed here to silence that warning. Same
  # host-vs-container override rule applies: BEADS_DOLT_SERVER_PORT=3306 (env.sh) always wins
  # inside a container regardless of what this file says.
  echo "${DOLT_HOST_PORT:-3306}" > .beads/dolt-server.port
  jq '.dolt_server_host = "127.0.0.1" | del(.dolt_server_port)' .beads/metadata.json > .beads/metadata.json.tmp \
    && mv .beads/metadata.json.tmp .beads/metadata.json
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
