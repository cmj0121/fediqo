#!/usr/bin/env bash
# Throw the local protocol servers away: containers, volumes, generated secrets.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v docker >/dev/null 2>&1; then
    echo >&2 "servers-down: docker is not on PATH"
    exit 1
fi

docker compose -f servers/compose.yml --project-directory servers --env-file servers/.env \
    down --volumes --remove-orphans 2>/dev/null \
    || docker compose -f servers/compose.yml --project-directory servers \
        down --volumes --remove-orphans

rm -rf servers/.run
echo "servers: thrown away"
