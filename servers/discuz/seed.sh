#!/bin/sh
# Discuz! X5's installer is a cookie-jar walk, then an EventSource that actually
# creates the tables. Talking HTTP to 127.0.0.1 here is not a Fediqo fetch.
set -eu

if [ -f /app/public/data/install.lock ]; then
    echo "discuz: already installed"
    exit 0
fi

base="http://127.0.0.1/install/index.php"
jar=/tmp/discuz-install.jar
curl_i() { curl -fsS --noproxy localhost -c "$jar" -b "$jar" "$@"; }

curl_i "$base?lang=SC_UTF8" >/tmp/dz-lang.html
curl_i "$base?step=0&start=yes" >/tmp/dz-start.html
curl_i "$base?step=1&agree=yes" >/tmp/dz-agree.html
curl_i -L -X POST "$base" --data "step=2&install_ucenter=standalone&submitname=next" \
    >/tmp/dz-uc.html

curl_i -L -X POST "$base" \
    --data-urlencode "step=3" \
    --data-urlencode "install_ucenter=standalone" \
    --data-urlencode "dbinfo[dbhost]=discuz-db" \
    --data-urlencode "dbinfo[dbname]=discuz" \
    --data-urlencode "dbinfo[dbuser]=discuz" \
    --data-urlencode "dbinfo[dbpw]=local-only" \
    --data-urlencode "dbinfo[tablepre]=pre_" \
    --data-urlencode "dbinfo[adminemail]=admin@example.com" \
    --data-urlencode "admininfo[username]=admin" \
    --data-urlencode "admininfo[password]=LocalOnlyPass1" \
    --data-urlencode "admininfo[password2]=LocalOnlyPass1" \
    --data-urlencode "admininfo[email]=admin@example.com" \
    --data-urlencode "submitname=next" \
    >/tmp/dz-db.html

allinfo=$(sed -n "s/.*do_db_init\&allinfo=\([^']*\).*/\1/p" /tmp/dz-db.html | head -1)
[ -n "$allinfo" ] || {
    echo >&2 "discuz: installer did not hand back do_db_init"
    tail -c 1500 /tmp/dz-db.html >&2 || true
    exit 1
}

# The page is JS; the tables are this EventSource.
curl_i --max-time 120 "$base?method=do_db_init&allinfo=$allinfo" >/tmp/dz-sse.html
curl_i --max-time 60 "http://127.0.0.1/misc.php?mod=initsys" >/tmp/dz-initsys.html
curl_i --max-time 30 "$base?method=ext_info" >/tmp/dz-ext.html

if [ ! -f /app/public/data/install.lock ]; then
    echo >&2 "discuz: installer did not write data/install.lock"
    tail -c 1500 /tmp/dz-sse.html >&2 || true
    exit 1
fi

echo "discuz: installed"
