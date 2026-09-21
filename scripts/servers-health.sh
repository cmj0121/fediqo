#!/usr/bin/env bash
# HTTPS to each protocol host on loopback, through Caddy's local CA.
# Used by `make servers` and by the Swift gate (the Swift side does the same
# asks through Fediqo's client).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CA="${FEDIQO_SERVERS_CA:-$ROOT/servers/.run/root.crt}"

if [ ! -f "$CA" ]; then
    echo >&2 "servers-health: no local CA at $CA — has make servers finished?"
    exit 1
fi

curl_https() {
    local host="$1" path="$2"
    curl -fsS --max-time 10 \
        --cacert "$CA" \
        --resolve "$host:443:127.0.0.1" \
        "https://$host$path" >/dev/null
}

curl_https mastodon.localhost /health
curl_https discourse.localhost /srv/status
curl_https discuz.localhost /forum.php

echo "servers: mastodon.localhost discourse.localhost discuz.localhost answered HTTPS"
