#!/usr/bin/env bash
# Two people, one app, a sign-in of each, and a little to read on the local GoToSocial.
# Run by `servers-up.sh` on this machine, not in the container: the server's own tool can
# make an account and nothing else, so the app and the sign-ins are made the way a client
# makes them — its own sign-in page answered with curl, no browser. Dummy passwords only.
#
# Idempotent: a second run finds the accounts, registers one more app, and adds no post.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_DIR="$ROOT/servers/.run"
CA="${FEDIQO_SERVERS_CA:-$RUN_DIR/root.crt}"
HOST=gotosocial.localhost
OUT="$RUN_DIR/gotosocial-tokens.json"
COMPOSE=(docker compose -f "$ROOT/servers/compose.yml" --project-directory "$ROOT/servers"
    --env-file "$ROOT/servers/.env" --profile gotosocial)

# Long because this server measures a password's strength and refuses a short one.
PASSWORD="local-only-Fixture-Passphrase-1"
SCOPES="read write push"
# Never fetched: the server sends the browser here with the code, and curl stops there.
REDIRECT="https://$HOST/fediqo-seed-callback"

die() { echo >&2 "gotosocial-seed: $*"; exit 1; }

call() {
    curl -sS --max-time 20 --cacert "$CA" --resolve "$HOST:443:127.0.0.1" "$@"
}

# One field of a JSON object on stdin.
field() {
    python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$1"
}

admin() {
    "${COMPOSE[@]}" exec -T gotosocial /gotosocial/gotosocial admin account "$@"
}

ensure_account() {
    local name="$1"
    if admin list 2>/dev/null | grep -qw "$name"; then
        return
    fi
    admin create --username "$name" --email "$name@$HOST" --password "$PASSWORD" >/dev/null \
        || die "could not create $name"
}

# A sign-in of one account for the registered app, for the words given: the authorize page,
# the sign-in form, the page that asks to allow, and the code traded for a token.
sign_in() {
    local name="$1" scope="$2" jar code location
    jar="$(mktemp)"
    call -o /dev/null -c "$jar" -b "$jar" -G "https://$HOST/oauth/authorize" \
        --data-urlencode "client_id=$CLIENT_ID" \
        --data-urlencode "redirect_uri=$REDIRECT" \
        --data-urlencode "response_type=code" \
        --data-urlencode "scope=$scope"
    call -o /dev/null -c "$jar" -b "$jar" "https://$HOST/auth/sign_in" \
        --data-urlencode "username=$name@$HOST" \
        --data-urlencode "password=$PASSWORD"
    call -o /dev/null -c "$jar" -b "$jar" "https://$HOST/oauth/authorize"
    location="$(call -o /dev/null -c "$jar" -b "$jar" -w '%{redirect_url}' \
        -X POST "https://$HOST/oauth/authorize")"
    rm -f "$jar"
    code="$(printf '%s' "$location" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')"
    [ -n "$code" ] || die "no code for $name (the server sent: ${location:-nothing})"
    # What the server says of the sign-in beside the token itself — its words, whether it
    # ends — is kept for `ask.py`; the token goes to the caller.
    call "https://$HOST/oauth/token" \
        --data-urlencode "client_id=$CLIENT_ID" \
        --data-urlencode "client_secret=$CLIENT_SECRET" \
        --data-urlencode "redirect_uri=$REDIRECT" \
        --data-urlencode "grant_type=authorization_code" \
        --data-urlencode "code=$code" | python3 -c '
import json, sys
said = json.load(sys.stdin)
print(said.pop("access_token", ""))
said.pop("refresh_token", None)
json.dump(said, open(sys.argv[1], "w"))' "$RUN_DIR/gotosocial-token-said.json"
}

as() {
    local token="$1"
    shift
    call -H "Authorization: Bearer $token" "$@"
}

post() {
    local token="$1" text="$2"
    as "$token" "https://$HOST/api/v1/statuses" \
        --data-urlencode "status=$text" --data-urlencode "visibility=public" | field id
}

[ -s "$CA" ] || die "no local CA at $CA"
mkdir -p "$RUN_DIR"

ensure_account writer
ensure_account other

registered="$(call "https://$HOST/api/v1/apps" \
    --data-urlencode "client_name=Fediqo checks" \
    --data-urlencode "redirect_uris=$REDIRECT" \
    --data-urlencode "scopes=$SCOPES")"
CLIENT_ID="$(printf '%s' "$registered" | field client_id)"
CLIENT_SECRET="$(printf '%s' "$registered" | field client_secret)"
[ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] || die "the app was not registered: $registered"

WRITER="$(sign_in writer "$SCOPES")"
OTHER="$(sign_in other "$SCOPES")"
# Asked for less than the app was registered for — the words this app asks a Mastodon for
# when a person chooses to read and not act — and asked the same twice: whether such a page
# opens, and whether the same words on one registration are one sign-in or two, are both
# things `ask.py` reads off these.
READING_SCOPES="read:statuses read:lists read:accounts read:search"
READING="$(sign_in writer "$READING_SCOPES")"
READING_AGAIN="$(sign_in writer "$READING_SCOPES")"
[ -n "$WRITER" ] && [ -n "$OTHER" ] && [ -n "$READING" ] && [ -n "$READING_AGAIN" ] \
    || die "a sign-in was not made"

writer_id="$(as "$WRITER" "https://$HOST/api/v1/accounts/verify_credentials" | field id)"
other_id="$(as "$OTHER" "https://$HOST/api/v1/accounts/verify_credentials" | field id)"
[ -n "$writer_id" ] && [ -n "$other_id" ] || die "a sign-in does not say whose it is"

# An account here is made locked, so a follow is a request until it is agreed to.
as "$WRITER" -o /dev/null -X POST "https://$HOST/api/v1/accounts/$other_id/follow"
as "$OTHER" -o /dev/null -X POST "https://$HOST/api/v1/accounts/$writer_id/follow"
as "$OTHER" -o /dev/null -X POST "https://$HOST/api/v1/follow_requests/$writer_id/authorize"
as "$WRITER" -o /dev/null -X POST "https://$HOST/api/v1/follow_requests/$other_id/authorize"

# What there is to read, made once: the ids are kept in the server's own volume's lifetime
# by the file below, which `servers-down` removes with the volume.
if [ -s "$OUT" ] && [ "$(field writer_id <"$OUT")" = "$writer_id" ]; then
    note="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["seeded"]["note"])' "$OUT")"
    plain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["seeded"]["plain"])' "$OUT")"
    edited="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["seeded"]["edited"])' "$OUT")"
    reblog="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["seeded"]["reblog"])' "$OUT")"
    list="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["seeded"]["list"])' "$OUT")"
else
    note="$(post "$WRITER" "A public note on this machine. #fediqo")"
    plain="$(post "$OTHER" "Another person's post, never changed. #fediqo")"
    edited="$(post "$OTHER" "Another person's post, before it was changed.")"
    as "$OTHER" -o /dev/null -X PUT "https://$HOST/api/v1/statuses/$edited" \
        --data-urlencode "status=Another person's post, after it was changed."
    reblog="$(as "$OTHER" -X POST "https://$HOST/api/v1/statuses/$note/reblog" | field id)"
    list="$(as "$WRITER" "https://$HOST/api/v1/lists" --data-urlencode "title=Seeded" | field id)"
    as "$WRITER" -o /dev/null "https://$HOST/api/v1/lists/$list/accounts" \
        --data-urlencode "account_ids[]=$other_id"
    [ -n "$note" ] && [ -n "$plain" ] && [ -n "$edited" ] && [ -n "$reblog" ] && [ -n "$list" ] \
        || die "the seed's posts were not all made"
fi

umask 077
python3 - "$OUT" "$RUN_DIR/gotosocial-token-said.json" <<EOF
import json, sys
json.dump({
    "token_said": json.load(open(sys.argv[2])),
    "host": "$HOST",
    "writer": "$WRITER", "writer_id": "$writer_id",
    "other": "$OTHER", "other_id": "$other_id",
    "reading": "$READING", "reading_again": "$READING_AGAIN",
    "client": {"id": "$CLIENT_ID", "secret": "$CLIENT_SECRET", "scopes": "$SCOPES", "redirect": "$REDIRECT"},
    "seeded": {"note": "$note", "plain": "$plain", "edited": "$edited", "reblog": "$reblog", "list": "$list"},
}, open(sys.argv[1], "w"), indent=2)
EOF
printf '%s\n' "$WRITER" >"$RUN_DIR/gotosocial-token"
echo "gotosocial-seed: writer and other signed in ($OUT)"
