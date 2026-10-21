#!/usr/bin/env bash
# Throw the local protocol servers away: containers, volumes, generated secrets.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v docker >/dev/null 2>&1; then
    echo >&2 "servers-down: docker is not on PATH"
    exit 1
fi

# The profiles are named whether or not they were brought up: a `down` without one would leave
# its container and volume behind.
docker compose -f servers/compose.yml --project-directory servers --env-file servers/.env \
    --profile gotosocial --profile worker down --volumes --remove-orphans 2>/dev/null \
    || docker compose -f servers/compose.yml --project-directory servers \
        --profile gotosocial --profile worker down --volumes --remove-orphans

rm -rf servers/.run
echo "servers: thrown away"
