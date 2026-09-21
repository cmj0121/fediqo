#!/usr/bin/env bash
# Bring up a real Mastodon, Discourse, and Discuz! on this machine, behind
# loopback HTTPS. Idempotent: a second run waits for health and re-seeds.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_FILE="$ROOT/servers/.env"
RUN_DIR="$ROOT/servers/.run"
COMPOSE=(docker compose -f servers/compose.yml --project-directory servers --env-file "$ENV_FILE")

die() { echo >&2 "servers-up: $*"; exit 1; }

need_docker() {
    command -v docker >/dev/null 2>&1 || die "docker is not on PATH"
    docker info >/dev/null 2>&1 || die "docker is installed but the daemon is not running"
}

set_env_key() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$ENV_FILE"; then
        local tmp
        tmp="$(mktemp)"
        awk -v k="$key" -v v="$value" -F= '
            $1==k { print k "=" v; next }
            { print }
        ' "$ENV_FILE" >"$tmp"
        mv "$tmp" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
    fi
}

env_value() {
    awk -F= -v k="$1" '$1==k { sub(/^[^=]+=/, ""); print; exit }' "$ENV_FILE"
}

ensure_env() {
    if [ ! -f "$ENV_FILE" ]; then
        cp "$ROOT/servers/.env.example" "$ENV_FILE"
        echo "servers-up: wrote $ENV_FILE from the example (gitignored)"
    fi

    [ -n "$(env_value SECRET_KEY_BASE)" ] \
        || set_env_key SECRET_KEY_BASE "$(openssl rand -hex 64)"
    [ -n "$(env_value OTP_SECRET)" ] \
        || set_env_key OTP_SECRET "$(openssl rand -hex 64)"
    [ -n "$(env_value ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY)" ] \
        || set_env_key ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY "$(openssl rand -base64 32)"
    [ -n "$(env_value ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY)" ] \
        || set_env_key ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY "$(openssl rand -base64 32)"
    [ -n "$(env_value ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT)" ] \
        || set_env_key ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT "$(openssl rand -base64 32)"
    [ -n "$(env_value DISCOURSE_SECRET_KEY_BASE)" ] \
        || set_env_key DISCOURSE_SECRET_KEY_BASE "$(openssl rand -hex 64)"
}

fill_vapid() {
    if [ -n "$(env_value VAPID_PRIVATE_KEY)" ] && [ -n "$(env_value VAPID_PUBLIC_KEY)" ]; then
        return
    fi
    echo "servers-up: generating VAPID keys (one Rails boot)"
    local out
    out="$("${COMPOSE[@]}" run --rm --no-deps mastodon-web \
        bundle exec rake mastodon:webpush:generate_vapid_key)"
    local priv pub
    priv="$(printf '%s\n' "$out" | awk -F= '/^VAPID_PRIVATE_KEY=/{print $2}')"
    pub="$(printf '%s\n' "$out" | awk -F= '/^VAPID_PUBLIC_KEY=/{print $2}')"
    [ -n "$priv" ] && [ -n "$pub" ] || die "rake did not print VAPID keys:\n$out"
    set_env_key VAPID_PRIVATE_KEY "$priv"
    set_env_key VAPID_PUBLIC_KEY "$pub"
}

wait_for() {
    local name="$1" tries="$2"
    shift 2
    local i=0
    while [ "$i" -lt "$tries" ]; do
        if "$@" >/dev/null 2>&1; then
            echo "servers-up: $name"
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done
    die "$name did not become ready"
}

export_ca() {
    mkdir -p "$RUN_DIR"
    local i=0
    while [ "$i" -lt 30 ]; do
        if "${COMPOSE[@]}" cp caddy:/data/caddy/pki/authorities/local/root.crt \
            "$RUN_DIR/root.crt" 2>/dev/null && [ -s "$RUN_DIR/root.crt" ]
        then
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done
    die "Caddy did not write a local CA"
}

seed_mastodon() {
    "${COMPOSE[@]}" exec -T mastodon-web \
        bundle exec rails runner "$(cat "$ROOT/servers/mastodon/seed.rb")"

    mkdir -p "$RUN_DIR"
    "${COMPOSE[@]}" cp mastodon-web:/tmp/fediqo-mastodon-token \
        "$RUN_DIR/mastodon-token"
    [ -s "$RUN_DIR/mastodon-token" ] || die "Mastodon seed did not write a token"
}

seed_discourse() {
    "${COMPOSE[@]}" exec -T \
        -e GIT_CONFIG_COUNT=1 \
        -e GIT_CONFIG_KEY_0=safe.directory \
        -e GIT_CONFIG_VALUE_0=/app \
        discourse \
        bash -lc 'cd /app && bundle exec rails runner "$(cat)"' \
        <"$ROOT/servers/discourse/seed.rb"
}

seed_discuz() {
    "${COMPOSE[@]}" cp "$ROOT/servers/discuz/seed.sh" discuz:/tmp/discuz-seed.sh
    "${COMPOSE[@]}" exec -T discuz sh /tmp/discuz-seed.sh
    seed_discuz_thread
}

seed_discuz_thread() {
    "${COMPOSE[@]}" exec -T discuz-db \
        mariadb -udiscuz -plocal-only discuz -e "
INSERT INTO pre_forum_thread (fid, author, authorid, subject, dateline, lastpost, lastposter, views)
SELECT 2, 'admin', 1, 'A thread on this machine', UNIX_TIMESTAMP(), UNIX_TIMESTAMP(), 'admin', 1
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM pre_forum_thread LIMIT 1);
SET @tid := (SELECT tid FROM pre_forum_thread ORDER BY tid DESC LIMIT 1);
INSERT INTO pre_forum_post (pid, fid, tid, first, author, authorid, subject, dateline, lastupdate, premsg, message, useip, position, bestanswer)
SELECT 1, 2, @tid, 1, 'admin', 1, 'A thread on this machine', UNIX_TIMESTAMP(), UNIX_TIMESTAMP(), '', 'A public thread on this machine.', '127.0.0.1', 1, 0
FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM pre_forum_post LIMIT 1);
"
}

need_docker
command -v openssl >/dev/null 2>&1 || die "openssl is not on PATH"
command -v curl >/dev/null 2>&1 || die "curl is not on PATH"

ensure_env
mkdir -p "$RUN_DIR"

echo "servers-up: pulling images (first run is the slow one)"
"${COMPOSE[@]}" pull

fill_vapid

echo "servers-up: starting databases"
"${COMPOSE[@]}" up -d mastodon-db mastodon-redis discourse-db discourse-redis discuz-db
wait_for "mastodon-db is healthy" 30 \
    "${COMPOSE[@]}" exec -T mastodon-db pg_isready -U mastodon -d mastodon
wait_for "discourse-db is healthy" 30 \
    "${COMPOSE[@]}" exec -T discourse-db pg_isready -U discourse -d discourse
wait_for "discuz-db is healthy" 40 \
    "${COMPOSE[@]}" exec -T discuz-db healthcheck.sh --connect --innodb_initialized

echo "servers-up: preparing the Mastodon schema"
"${COMPOSE[@]}" run --rm mastodon-web bundle exec rails db:prepare

echo "servers-up: starting application containers"
"${COMPOSE[@]}" up -d

wait_for "mastodon-web is healthy" 90 \
    "${COMPOSE[@]}" exec -T mastodon-web \
    curl -fsS --noproxy localhost http://127.0.0.1:3000/health

wait_for "discourse is healthy" 180 \
    "${COMPOSE[@]}" exec -T discourse \
    curl -fsS --noproxy localhost http://127.0.0.1:3000/srv/status

wait_for "discuz is serving" 90 \
    "${COMPOSE[@]}" exec -T discuz \
    curl -fsS --noproxy localhost --max-time 3 http://127.0.0.1/

export_ca
seed_mastodon
seed_discourse
seed_discuz

wait_for "caddy has a local CA" 30 test -s "$RUN_DIR/root.crt"
"$ROOT/scripts/servers-health.sh"

echo
echo "servers-up: ready on this machine"
echo "  https://mastodon.localhost"
echo "  https://discourse.localhost"
echo "  https://discuz.localhost"
echo
echo "  FEDIQO_SERVERS=1 make test"
echo "  make servers-down"
