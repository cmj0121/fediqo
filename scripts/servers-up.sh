#!/usr/bin/env bash
# Bring up a real Mastodon, Discourse, and Discuz! on this machine, behind
# loopback HTTPS. Idempotent: a second run waits for health and re-seeds.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ENV_FILE="$ROOT/servers/.env"
RUN_DIR="$ROOT/servers/.run"
COMPOSE=(docker compose -f servers/compose.yml --project-directory servers --env-file "$ENV_FILE")

# A fourth server no check of the product needs: a GoToSocial, asked as a Mastodon is to see
# what differs (servers/gotosocial/FINDINGS.md). Only where it is asked for, so that the three
# come up exactly as they did.
WITH_GOTOSOCIAL="${FEDIQO_SERVERS_GOTOSOCIAL:-}"
if [ "$WITH_GOTOSOCIAL" = "1" ]; then
    COMPOSE+=(--profile gotosocial)
fi

# Mastodon's streaming service (the `streaming` profile of compose.yml): the line a reader holds
# open to be told what is new as it happens (#325). Only where it is asked for. It changes nothing
# the server holds, so it needs no throwing away after; what it tells, the worker hands it, so a
# check of what arrives on it wants `FEDIQO_SERVERS_WORKER=1` beside it.
WITH_STREAMING="${FEDIQO_SERVERS_STREAMING:-}"
if [ "$WITH_STREAMING" = "1" ]; then
    COMPOSE+=(--profile streaming)
fi

# Mastodon's worker (the `worker` profile of compose.yml): what publishes a post at its time and
# fetches a link's preview. Only where it is asked for, and only after the seed, so that the seed
# runs the jobs it means to and the three come up exactly as they did without it.
WITH_WORKER="${FEDIQO_SERVERS_WORKER:-}"

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
    # A second person, and a sign-in of each that may do everything a person can (#298);
    # what the writer has been told of, and their sign-ins as this app makes them (#323).
    "${COMPOSE[@]}" cp mastodon-web:/tmp/fediqo-mastodon-tokens.json \
        "$RUN_DIR/mastodon-tokens.json"
    [ -s "$RUN_DIR/mastodon-tokens.json" ] || die "Mastodon seed did not write the other tokens"
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

# What a worker did stays in the database and in Redis after it is stopped: posts it published,
# previews it fetched, the people it ranked for suggesting (which the seed's own suggestions rest
# on nobody doing). A run without it is to be what it was, so on a fixture a worker has run
# against it refuses, and only a run that asks for the worker again goes on.
refuse_after_worker() {
    [ "$WITH_WORKER" = "1" ] && return 0
    if [ -e "$RUN_DIR/worker-ran" ] \
        || [ -n "$("${COMPOSE[@]}" --profile worker ps -a -q mastodon-sidekiq 2>/dev/null)" ]
    then
        die "Mastodon's worker has run against these servers, and what it did is still there.
Throw them away first: make servers-down, then make servers."
    fi
}

# Stopped before anything is waited on or seeded: a worker left up by an earlier run would run
# the seed's jobs beside it.
stop_worker() {
    "${COMPOSE[@]}" --profile worker stop mastodon-sidekiq >/dev/null 2>&1 || true
}

# A preview is fetched from Caddy's address on the compose network, which Mastodon refuses as
# private unless it is allowed; that one address is, and nothing else. It is read here, so a Caddy
# recreated outside this script may come back at another address, and the worker's preview
# fetches are then refused until this runs again.
start_worker() {
    local caddy address
    caddy="$("${COMPOSE[@]}" ps -q caddy)"
    [ -n "$caddy" ] || die "caddy is not running"
    address="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$caddy")"
    [ -n "$address" ] || die "caddy has no address on the compose network"
    set_env_key FEDIQO_CARD_ADDRESS "$address"
    touch "$RUN_DIR/worker-ran"
    "${COMPOSE[@]}" --profile worker up -d mastodon-sidekiq
    wait_for "mastodon-sidekiq is running" 60 worker_running
}

redis_mastodon() {
    "${COMPOSE[@]}" exec -T mastodon-redis redis-cli "$@"
}

# The container is running and one of the processes Sidekiq lists has beaten in the last thirty
# seconds: a worker that was killed leaves its name in the list, and its beat goes stale (and
# the record of it is gone a minute later).
worker_running() {
    [ -n "$("${COMPOSE[@]}" --profile worker ps --status running -q mastodon-sidekiq)" ] || return 1
    local now member beat
    now="$(redis_mastodon TIME | head -1)"
    [ -n "$now" ] || return 1
    for member in $(redis_mastodon SMEMBERS processes); do
        beat="$(redis_mastodon HGET "$member" beat)"
        beat="${beat%%.*}"
        if [ -n "$beat" ] && [ $((now - beat)) -lt 30 ]; then
            return 0
        fi
    done
    return 1
}

seed_gotosocial() {
    wait_for "gotosocial is ready" 60 \
        "${COMPOSE[@]}" exec -T gotosocial \
        wget -q --spider http://127.0.0.1:8080/readyz
    "$ROOT/servers/gotosocial/seed.sh"
}

need_docker
command -v openssl >/dev/null 2>&1 || die "openssl is not on PATH"
command -v curl >/dev/null 2>&1 || die "curl is not on PATH"

ensure_env
mkdir -p "$RUN_DIR"
refuse_after_worker

echo "servers-up: pulling images (first run is the slow one)"
"${COMPOSE[@]}" pull

fill_vapid

stop_worker

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

if [ "$WITH_STREAMING" = "1" ]; then
    wait_for "mastodon-streaming is healthy" 60 \
        "${COMPOSE[@]}" exec -T mastodon-streaming \
        curl -fsS --noproxy localhost http://127.0.0.1:4000/api/v1/streaming/health
fi

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
if [ "$WITH_GOTOSOCIAL" = "1" ]; then
    seed_gotosocial
fi
if [ "$WITH_WORKER" = "1" ]; then
    start_worker
fi

wait_for "caddy has a local CA" 30 test -s "$RUN_DIR/root.crt"
"$ROOT/scripts/servers-health.sh"

echo
echo "servers-up: ready on this machine"
echo "  https://mastodon.localhost"
echo "  https://discourse.localhost"
echo "  https://discuz.localhost"
if [ "$WITH_GOTOSOCIAL" = "1" ]; then
    echo "  https://gotosocial.localhost (asked, not joined: servers/gotosocial/ask.py)"
fi
if [ "$WITH_WORKER" = "1" ]; then
    echo "  mastodon-sidekiq: posts go at their time, links gain a preview; its checks run alone:"
    echo "    FEDIQO_SERVERS_WORKER=1 swift test --filter MastodonWorkerSaysTests"
fi
echo
echo "  FEDIQO_SERVERS=1 make test"
echo "  make servers-down"
