#!/usr/bin/env bash
# One-time host-side setup. Run from the kit root: bin/init.sh
set -euo pipefail
cd "$(dirname "$0")/.."

chmod +x bin/*.sh
if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env - add your ANTHROPIC_API_KEY (or CLAUDE_CODE_OAUTH_TOKEN), then re-run bin/init.sh"
  exit 1
fi
grep -q '^HOST_UID=' .env || { echo "HOST_UID=$(id -u)" >> .env; echo "HOST_GID=$(id -g)" >> .env; }

for r in po architect qa engineer reviewer shell; do
  mkdir -p "data/workspaces/$r" "data/claude/$r"
done
mkdir -p data/dolt data/logs data/control
[ -d data/origin.git ] || git init -q --bare -b main data/origin.git

docker compose build agent
docker compose up -d dolt
echo "Waiting for Dolt..."
for _ in $(seq 30); do
  docker compose exec -T dolt dolt sql -q "select 1" >/dev/null 2>&1 && break
  sleep 2
done

ROLE=shell docker compose run --rm --entrypoint bash agent /work/bin/init-project.sh
echo
echo "Done. Next: bin/smoke-test.sh (see README), then bin/start.sh"
