#!/usr/bin/env python3
"""The questions the servers-unlocked checks put to Mastodon, put to both local servers.

    python3 servers/gotosocial/ask.py            # ask both, then say where they differ
    python3 servers/gotosocial/ask.py --compare  # only compare what was last answered
    python3 servers/gotosocial/ask.py --only=gotosocial.localhost  # ask one, compare nothing

Needs `FEDIQO_SERVERS_GOTOSOCIAL=1 make servers` to have finished. Every ask goes to
loopback through Caddy's local CA, as `scripts/servers-health.sh` asks. What each server
answered is written whole to `servers/.run/asked/<host>.json` (thrown away by
`make servers-down`); `FINDINGS.md` beside this file is what was read off one run.

Two answers are called the same here when the status, the kind of body, the names in the
`Link` header and the names of the fields (three levels down) are the same. Values are not
compared: ids, times and counts differ between any two servers.

It writes: a post, a favourite, a bookmark, a boost, a follow, a mute, a block and a marker
are each made and taken back, and one app is registered on each server per run.
"""

import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUN = os.path.join(ROOT, "servers", ".run")
CA = os.environ.get("FEDIQO_SERVERS_CA", os.path.join(RUN, "root.crt"))
OUT = os.path.join(RUN, "asked")
MASTODON = "mastodon.localhost"
GOTOSOCIAL = "gotosocial.localhost"


def png():
    """A 1x1 PNG, for the one ask that sends a file."""
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))
    header = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00")) + chunk(b"IEND", b""))



def roles(host):
    """Who the seed made on this host, under the same names for both."""
    if host == MASTODON:
        seeded = json.load(open(os.path.join(RUN, "mastodon-tokens.json")))
        notices = seeded.get("notices") or {}
        return {
            "writer": seeded["writer"],
            "other": seeded["other"],
            "reading": (notices.get("reading") or {}).get("token"),
            "note": seeded["seeded"]["reblogged"],
            "plain": seeded["seeded"]["plain"],
            "edited": seeded["seeded"]["edited"],
            "reblog": seeded["seeded"]["reblog"],
            "list": seeded["seeded"]["list"],
        }
    seeded = json.load(open(os.path.join(RUN, "gotosocial-tokens.json")))
    return {
        "writer": seeded["writer"],
        "other": seeded["other"],
        "reading": seeded["reading"],
        "reading_again": seeded["reading_again"],
        "seed_client": seeded["client"],
        "token_said": seeded.get("token_said"),
        **seeded["seeded"],
    }


def shape(value, depth=3, prefix=""):
    """The names of the fields, three levels down; a list is its first entry's."""
    names = set()
    if isinstance(value, list):
        value = value[0] if value else None
        prefix += "[]"
    if isinstance(value, dict) and depth > 0:
        for key, inner in value.items():
            path = f"{prefix}.{key}" if prefix else key
            names.add(path)
            names |= shape(inner, depth - 1, path)
    return names


class Asker:
    def __init__(self, host):
        self.host = host
        self.who = roles(host)
        self.answers = []
        self.last = {}

    def ask(self, label, method, path, who=None, form=None, files=None, headers=None, token=None):
        path = path.format(**{k: v for k, v in self.who.items() if isinstance(v, str)})
        command = [
            "curl", "-sS", "--max-time", "30", "--cacert", CA,
            "--resolve", f"{self.host}:443:127.0.0.1",
            "-X", method, "-H", "Accept-Language: en", "-D", "-", "-o", "-",
        ]
        bearer = token or (self.who.get(who) if who else None)
        if who and not bearer:
            answer = {"label": label, "method": method, "path": path, "who": who,
                      "status": None, "note": "the seed made no such sign-in"}
            self.answers.append(answer)
            return answer
        if bearer:
            command += ["-H", f"Authorization: Bearer {bearer}"]
        for name, value in (headers or {}).items():
            command += ["-H", f"{name}: {value}"]
        for name, value in (form or {}).items():
            command += ["--data-urlencode", f"{name}={value}"]
        for name, value in (files or {}).items():
            command += ["-F", f"{name}=@{value}"]
        raw = subprocess.run(command + [f"https://{self.host}{path}"], capture_output=True).stdout
        head, _, body = raw.partition(b"\r\n\r\n")
        while body.startswith(b"HTTP/"):
            head, _, body = body.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        status = int(lines[0].split()[1]) if lines and len(lines[0].split()) > 1 else None
        got = {}
        for line in lines[1:]:
            name, _, value = line.partition(":")
            got[name.strip().lower()] = value.strip()
        try:
            parsed = json.loads(body)
        except ValueError:
            parsed = None
        text = body.decode("utf-8", "replace")
        answer = {
            "label": label, "method": method, "path": path, "who": who or ("a given token" if token else None),
            "status": status,
            "type": got.get("content-type", "").split(";")[0],
            "link": sorted(set(re.findall(r"[?&]([a-z_]+)=", got.get("link", "")))),
            "link_raw": got.get("link", ""),
            "location": got.get("location", ""),
            "authenticate": got.get("www-authenticate", ""),
            "ratelimit": {k: v for k, v in got.items() if k.startswith("x-ratelimit")},
            "kind": "list" if isinstance(parsed, list) else "object" if isinstance(parsed, dict)
                    else "empty" if not body else "text",
            "count": len(parsed) if isinstance(parsed, list) else None,
            "shape": sorted(shape(parsed)),
            "body": parsed if parsed is not None else text[:600],
        }
        self.answers.append(answer)
        self.last = answer
        return answer

    def field(self, name):
        body = self.last.get("body")
        return body.get(name) if isinstance(body, dict) else None

    def run(self):
        ask = self.ask
        me = ask("who a sign-in is", "GET", "/api/v1/accounts/verify_credentials", "writer")
        self.who["writer_id"] = (me["body"] or {}).get("id") if isinstance(me["body"], dict) else None
        them = ask("who the other sign-in is", "GET", "/api/v1/accounts/verify_credentials", "other")
        self.who["other_id"] = (them["body"] or {}).get("id") if isinstance(them["body"], dict) else None

        # What the server is, and what detection reads.
        ask("the front page", "GET", "/")
        ask("the document", "GET", "/api/v2/instance")
        ask("the older document", "GET", "/api/v1/instance")
        ask("Mastodon's own health address", "GET", "/health")
        ask("the streaming service's health", "GET", "/api/v1/streaming/health")
        ask("who may sign in, as a browser's standard asks", "GET", "/.well-known/oauth-authorization-server")
        ask("the same, by the other name", "GET", "/.well-known/openid-configuration")
        ask("what guards the API", "GET", "/.well-known/oauth-protected-resource")
        ask("nodeinfo", "GET", "/.well-known/nodeinfo")

        # A not-found, spelled each way the checks know.
        ask("an address it does not serve", "GET", "/api/v1/fediqo_no_such_thing")
        ask("a version it does not serve", "GET", "/api/v9/instance")
        ask("a thing under the document it does not serve", "GET", "/api/v1/instance/fediqo_no_such")
        ask("an account nobody has", "GET", "/api/v1/accounts/1")
        ask("a post nobody wrote", "GET", "/api/v1/statuses/1")
        ask("an account nobody has, signed in", "GET", "/api/v1/accounts/1", "writer")
        ask("a post nobody wrote, signed in", "GET", "/api/v1/statuses/1", "writer")
        ask("an address it does not serve, signed in", "GET", "/api/v1/fediqo_no_such_thing", "writer")
        ask("terms nobody wrote", "GET", "/api/v1/instance/terms_of_service")
        ask("servers blocked, asked by a stranger", "GET", "/api/v1/instance/domain_blocks")
        ask("a translation", "POST", "/api/v1/statuses/{plain}/translate", "writer")

        # The server's account of itself.
        ask("its longer account of itself", "GET", "/api/v1/instance/extended_description")
        ask("the servers it knows", "GET", "/api/v1/instance/peers")
        ask("how busy it has been", "GET", "/api/v1/instance/activity")
        ask("its rules", "GET", "/api/v1/instance/rules")
        ask("its emoji", "GET", "/api/v1/custom_emojis")
        ask("its emoji, signed in", "GET", "/api/v1/custom_emojis", "writer")
        ask("its directory, newest", "GET", "/api/v1/directory?order=new&local=true")
        ask("its directory, most active", "GET", "/api/v1/directory?order=active")
        ask("hashtags rising", "GET", "/api/v1/trends/tags")
        ask("links rising", "GET", "/api/v1/trends/links")
        ask("posts rising", "GET", "/api/v1/trends/statuses")
        ask("announcements", "GET", "/api/v1/announcements", "writer")
        ask("people suggested", "GET", "/api/v2/suggestions", "writer")
        ask("people suggested, the older way", "GET", "/api/v1/suggestions", "writer")
        ask("what the person set", "GET", "/api/v1/preferences", "writer")

        # Timelines.
        ask("the public timeline, no sign-in", "GET", "/api/v1/timelines/public?limit=5")
        ask("the public timeline, signed in", "GET", "/api/v1/timelines/public?limit=5", "writer")
        ask("the local timeline, signed in", "GET", "/api/v1/timelines/public?local=true&limit=5", "writer")
        ask("Home, no sign-in", "GET", "/api/v1/timelines/home")
        ask("Home, a token that is no token", "GET", "/api/v1/timelines/home", token="fediqo-no-such-token")
        ask("Home", "GET", "/api/v1/timelines/home?limit=1", "writer")
        ask("Home, one stretch on", "GET", "/api/v1/timelines/home?limit=1&max_id={reblog}", "writer")
        ask("the lists", "GET", "/api/v1/lists", "writer")
        ask("a list's timeline", "GET", "/api/v1/timelines/list/{list}?limit=5", "writer")
        ask("a list nobody made", "GET", "/api/v1/timelines/list/1", "writer")
        made = ask("a list made", "POST", "/api/v1/lists", "writer", form={"title": "fediqo-n3d-empty"})
        self.who["empty"] = (made["body"].get("id") if isinstance(made["body"], dict) else None) or "1"
        ask("the timeline of a list with nobody on it", "GET", "/api/v1/timelines/list/{empty}", "writer")
        ask("a list removed", "DELETE", "/api/v1/lists/{empty}", "writer")
        ask("a hashtag's timeline, no sign-in", "GET", "/api/v1/timelines/tag/fediqo?limit=5")
        ask("a hashtag's timeline, signed in", "GET", "/api/v1/timelines/tag/fediqo?limit=5", "writer")

        # A post.
        ask("a post, no sign-in", "GET", "/api/v1/statuses/{plain}")
        ask("a post, a token that is no token", "GET", "/api/v1/statuses/{plain}", token="fediqo-no-such-token")
        ask("a post", "GET", "/api/v1/statuses/{plain}", "writer")
        ask("a post that was changed", "GET", "/api/v1/statuses/{edited}", "writer")
        ask("its earlier wording", "GET", "/api/v1/statuses/{edited}/history", "writer")
        ask("its source", "GET", "/api/v1/statuses/{edited}/source", "other")
        ask("a boost", "GET", "/api/v1/statuses/{reblog}", "writer")
        ask("what belongs with a post", "GET", "/api/v1/statuses/{plain}/context", "writer")
        ask("what belongs with a post, no sign-in", "GET", "/api/v1/statuses/{plain}/context")
        ask("who boosted a post", "GET", "/api/v1/statuses/{note}/reblogged_by", "writer")
        ask("who favoured a post", "GET", "/api/v1/statuses/{note}/favourited_by", "writer")

        # People.
        ask("a person by handle, no sign-in", "GET", "/api/v1/accounts/lookup?acct=other")
        ask("a person by handle", "GET", "/api/v1/accounts/lookup?acct=other", "writer")
        ask("a handle nobody has", "GET", "/api/v1/accounts/lookup?acct=fediqo_nobody", "writer")
        ask("a handle of a server never heard of", "GET",
            "/api/v1/accounts/lookup?acct=somebody@elsewhere.invalid", "writer")
        ask("a person by id, no sign-in", "GET", "/api/v1/accounts/{other_id}")
        ask("a person by id", "GET", "/api/v1/accounts/{other_id}", "writer")
        ask("a person's posts, no sign-in", "GET", "/api/v1/accounts/{other_id}/statuses?limit=2")
        ask("a person's posts", "GET", "/api/v1/accounts/{other_id}/statuses?limit=2", "writer")
        ask("a person's posts, one stretch on", "GET",
            "/api/v1/accounts/{other_id}/statuses?limit=1&max_id={reblog}", "writer")
        ask("who follows a person, no sign-in", "GET", "/api/v1/accounts/{other_id}/followers")
        ask("who follows a person", "GET", "/api/v1/accounts/{other_id}/followers?limit=1", "writer")
        ask("who a person follows", "GET", "/api/v1/accounts/{other_id}/following?limit=1", "writer")
        ask("how the reader stands to a person", "GET", "/api/v1/accounts/relationships?id[]={other_id}", "writer")
        ask("how the reader stands, no sign-in", "GET", "/api/v1/accounts/relationships?id[]={other_id}")
        ask("how the reader stands, a sign-in that only reads", "GET",
            "/api/v1/accounts/relationships?id[]={other_id}", "reading")
        ask("how the reader stands to nobody", "GET", "/api/v1/accounts/relationships?id[]=1", "writer")
        ask("hashtags a person features", "GET", "/api/v1/accounts/{other_id}/featured_tags", "writer")
        ask("people a person features", "GET", "/api/v1/accounts/{other_id}/endorsements", "writer")
        ask("hashtags the reader features", "GET", "/api/v1/featured_tags", "writer")
        ask("people the reader features", "GET", "/api/v1/endorsements", "writer")
        ask("the lists a person is on", "GET", "/api/v1/accounts/{other_id}/lists", "writer")
        ask("requests to follow", "GET", "/api/v1/follow_requests", "writer")
        ask("the muted", "GET", "/api/v1/mutes", "writer")
        ask("the blocked", "GET", "/api/v1/blocks", "writer")
        ask("servers the reader blocked", "GET", "/api/v1/domain_blocks", "writer")

        # Hashtags and search.
        ask("a hashtag, no sign-in", "GET", "/api/v1/tags/fediqo")
        ask("a hashtag", "GET", "/api/v1/tags/fediqo", "writer")
        ask("a hashtag nobody used", "GET", "/api/v1/tags/fediqonobodyused", "writer")
        ask("a hashtag followed", "POST", "/api/v1/tags/fediqo/follow", "writer")
        ask("the hashtags followed", "GET", "/api/v1/followed_tags", "writer")
        ask("a hashtag unfollowed", "POST", "/api/v1/tags/fediqo/unfollow", "writer")
        ask("a search, no sign-in", "GET", "/api/v2/search?q=fediqo")
        ask("a search", "GET", "/api/v2/search?q=fediqo", "writer")
        ask("a search for people", "GET", "/api/v2/search?q=other&type=accounts", "writer")
        ask("a search for hashtags", "GET", "/api/v2/search?q=fediqo&type=hashtags", "writer")
        ask("a search for posts", "GET", "/api/v2/search?q=changed&type=statuses", "writer")
        ask("a look-up through the source, no sign-in", "GET",
            "/api/v2/search?q=somebody@elsewhere.invalid&resolve=true")
        ask("a look-up through the source", "GET",
            "/api/v2/search?q=somebody@elsewhere.invalid&resolve=true&type=accounts", "writer")

        # Marks and notices.
        ask("bookmarks", "GET", "/api/v1/bookmarks", "writer")
        ask("favourites", "GET", "/api/v1/favourites", "writer")
        ask("where the reader stopped", "GET", "/api/v1/markers?timeline[]=home&timeline[]=notifications", "writer")
        ask("where the reader stopped, told", "POST", "/api/v1/markers", "writer",
            form={"home[last_read_id]": self.who["plain"]})
        ask("notices", "GET", "/api/v1/notifications?limit=5", "writer")
        ask("notices, gathered", "GET", "/api/v2/notifications?limit=5", "writer")
        ask("how many notices are unread", "GET", "/api/v1/notifications/unread_count", "writer")
        ask("what is held back from notices", "GET", "/api/v2/notifications/policy", "writer")
        ask("notices held back", "GET", "/api/v1/notifications/requests", "writer")
        ask("conversations", "GET", "/api/v1/conversations", "writer")
        ask("the server's filters", "GET", "/api/v2/filters", "writer")
        ask("posts waiting to be sent", "GET", "/api/v1/scheduled_statuses", "writer")
        ask("the year's report", "GET", "/api/v1/annual_reports", "writer")

        # Acts, each taken back.
        key = str(uuid.uuid4())
        text = f"fediqo-n3d-{key[:8]} #fediqo"
        first = ask("a post sent", "POST", "/api/v1/statuses", "writer",
                    form={"status": text, "visibility": "public"}, headers={"Idempotency-Key": key})
        mine = (first["body"] or {}).get("id") if isinstance(first["body"], dict) else None
        again = ask("the same post sent again under the same key", "POST", "/api/v1/statuses", "writer",
                    form={"status": text, "visibility": "public"}, headers={"Idempotency-Key": key})
        again["same_id_as_first"] = isinstance(again["body"], dict) and again["body"].get("id") == mine
        ask("a post sent by a sign-in that only reads", "POST", "/api/v1/statuses", "reading",
            form={"status": "fediqo-n3d-refused", "visibility": "public"})
        ask("a post with nothing in it", "POST", "/api/v1/statuses", "writer", form={"status": ""})
        self.who["mine"] = mine or "1"
        ask("a favourite", "POST", "/api/v1/statuses/{plain}/favourite", "writer")
        ask("a favourite taken back", "POST", "/api/v1/statuses/{plain}/unfavourite", "writer")
        ask("a bookmark", "POST", "/api/v1/statuses/{plain}/bookmark", "writer")
        ask("a bookmark taken back", "POST", "/api/v1/statuses/{plain}/unbookmark", "writer")
        ask("a boost made", "POST", "/api/v1/statuses/{plain}/reblog", "writer")
        ask("a boost taken back", "POST", "/api/v1/statuses/{plain}/unreblog", "writer")
        ask("a post pinned", "POST", "/api/v1/statuses/{mine}/pin", "writer")
        ask("a post unpinned", "POST", "/api/v1/statuses/{mine}/unpin", "writer")
        ask("a post changed", "PUT", "/api/v1/statuses/{mine}", "writer", form={"status": text + " changed"})
        ask("a post withdrawn", "DELETE", "/api/v1/statuses/{mine}", "writer")
        ask("a post withdrawn twice", "DELETE", "/api/v1/statuses/{mine}", "writer")
        ask("an unfollow", "POST", "/api/v1/accounts/{other_id}/unfollow", "writer")
        ask("a follow by a sign-in that only reads", "POST", "/api/v1/accounts/{other_id}/follow", "reading")
        ask("a follow", "POST", "/api/v1/accounts/{other_id}/follow", "writer",
            form={"reblogs": "false", "notify": "true"})
        ask("a follow, as it was", "POST", "/api/v1/accounts/{other_id}/follow", "writer",
            form={"reblogs": "true", "notify": "false"})
        ask("a follow of oneself", "POST", "/api/v1/accounts/{writer_id}/follow", "writer")
        ask("a mute for a time", "POST", "/api/v1/accounts/{other_id}/mute", "writer", form={"duration": "300"})
        ask("a mute taken back", "POST", "/api/v1/accounts/{other_id}/unmute", "writer")
        ask("a block", "POST", "/api/v1/accounts/{other_id}/block", "writer")
        ask("a block taken back", "POST", "/api/v1/accounts/{other_id}/unblock", "writer")
        ask("the follow put back", "POST", "/api/v1/accounts/{other_id}/follow", "writer")
        ask("the other's follow put back", "POST", "/api/v1/accounts/{writer_id}/follow", "other")
        ask("a request to follow agreed to", "POST", "/api/v1/follow_requests/{writer_id}/authorize", "other")
        ask("the other's request agreed to", "POST", "/api/v1/follow_requests/{other_id}/authorize", "writer")
        ask("the other put back on the list", "POST", "/api/v1/lists/{list}/accounts", "writer",
            form={"account_ids[]": self.who["other_id"] or ""})
        ask("how the reader stands after all of it", "GET", "/api/v1/accounts/relationships?id[]={other_id}", "writer")
        ask("who follows a person, after all of it", "GET", "/api/v1/accounts/{other_id}/followers?limit=1", "writer")
        ask("a follower removed, asked of nobody", "POST", "/api/v1/accounts/1/remove_from_followers", "writer")
        ask("a person featured", "POST", "/api/v1/accounts/{other_id}/endorse", "writer")
        ask("a person no longer featured", "POST", "/api/v1/accounts/{other_id}/unendorse", "writer")
        ask("a server blocked, asked with no server named", "POST", "/api/v1/domain_blocks", "writer")
        ask("the account's words changed to what they were", "PATCH", "/api/v1/accounts/update_credentials",
            "writer", form={"note": ""})
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as picture:
            picture.write(png())
        ask("a picture sent", "POST", "/api/v2/media", "writer", files={"file": picture.name})
        os.unlink(picture.name)

        # Signing in.
        ask("the sign-in page, no app named", "GET", "/oauth/authorize")
        redirect = f"https://{self.host}/fediqo-ask-callback"
        app = ask("an app registered for a part", "POST", "/api/v1/apps", form={
            "client_name": "Fediqo asks", "redirect_uris": redirect,
            "scopes": "read write:follows read:follows write:bookmarks profile"})
        ask("an app registered with a word no server knows", "POST", "/api/v1/apps", form={
            "client_name": "Fediqo asks", "redirect_uris": redirect, "scopes": "read fediqo:no_such_word"})
        ask("an app registered with no words", "POST", "/api/v1/apps", form={
            "client_name": "Fediqo asks", "redirect_uris": redirect})
        client = app["body"] if isinstance(app["body"], dict) else {}
        ask("the sign-in page for that app", "GET",
            "/oauth/authorize?response_type=code&client_id={}&redirect_uri={}&scope=read".format(
                client.get("client_id", ""), redirect))
        token = ask("a token for the app alone", "POST", "/oauth/token", form={
            "grant_type": "client_credentials", "client_id": client.get("client_id", ""),
            "client_secret": client.get("client_secret", ""), "redirect_uri": redirect, "scope": "read"})
        bare = token["body"].get("access_token") if isinstance(token["body"], dict) else None
        ask("what the app's token says the app is", "GET", "/api/v1/apps/verify_credentials", token=bare or "x")
        ask("what a token says it holds", "GET", "/oauth/token/info", "writer")
        ask("what a narrower token says it holds", "GET", "/oauth/token/info", "reading")
        ask("who a sign-in that only reads is", "GET", "/api/v1/accounts/verify_credentials", "reading")
        ask("a code that is no code", "POST", "/oauth/token", form={
            "grant_type": "authorization_code", "client_id": client.get("client_id", ""),
            "client_secret": client.get("client_secret", ""), "redirect_uri": redirect, "code": "fediqo-no-code"})
        ask("the app's token ended", "POST", "/oauth/revoke", form={
            "client_id": client.get("client_id", ""), "client_secret": client.get("client_secret", ""),
            "token": bare or "x"})
        ask("the ended token used", "GET", "/api/v1/apps/verify_credentials", token=bare or "x")
        ask("a token ended by an app that did not make it", "POST", "/oauth/revoke", form={
            "client_id": client.get("client_id", ""), "client_secret": client.get("client_secret", ""),
            "token": self.who["writer"]})
        ask("the writer's sign-in after that", "GET", "/api/v1/accounts/verify_credentials", "writer")
        if self.who.get("reading_again"):
            twice = {"label": "the same words asked twice on one registration", "method": "-", "path": "-",
                     "who": "writer", "status": None,
                     "note": "one token" if self.who["reading"] == self.who["reading_again"] else "two tokens"}
            self.answers.append(twice)
            self.answers.append({"label": "what the server says beside a token it hands over", "method": "-",
                                 "path": "-", "who": "writer", "status": None, "note": self.who.get("token_said")})
            seed = self.who["seed_client"]
            ask("one of the two ended", "POST", "/oauth/revoke", form={
                "client_id": seed["id"], "client_secret": seed["secret"], "token": self.who["reading_again"]})
            ask("the one ended, used", "GET", "/api/v1/accounts/verify_credentials", "reading_again")
            ask("the other of the two, used", "GET", "/api/v1/accounts/verify_credentials", "reading")

        ask("what is left of the allowance", "GET", "/api/v1/instance")
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, f"{self.host}.json"), "w") as out:
            json.dump(self.answers, out, indent=1, ensure_ascii=False)
        refused = [a["label"] for a in self.answers if a.get("status") == 429]
        if refused:
            print(f"{self.host}: {len(refused)} asks were refused as too many — these answers are not answers: {refused[:3]}")
        print(f"{self.host}: {len(self.answers)} asked")


def compare():
    ours = {a["label"]: a for a in json.load(open(os.path.join(OUT, f"{MASTODON}.json")))}
    theirs = {a["label"]: a for a in json.load(open(os.path.join(OUT, f"{GOTOSOCIAL}.json")))}
    same = 0
    for label, m in ours.items():
        g = theirs.get(label)
        if g is None:
            continue
        seen = lambda a: (a.get("status"), a.get("type"), a.get("kind"), tuple(a.get("link") or ()))
        only_m = sorted(set(m.get("shape") or ()) - set(g.get("shape") or ()))
        only_g = sorted(set(g.get("shape") or ()) - set(m.get("shape") or ()))
        empty = m.get("count") == 0 or g.get("count") == 0
        if seen(m) == seen(g) and ((not only_m and not only_g) or (empty and m.get("count") == g.get("count"))):
            same += 1
            continue
        print(f"\n## {label} — {m['method']} {m['path']}" + (f" (as {m['who']})" if m.get("who") else ""))
        for name, a in (("mastodon", m), ("gotosocial", g)):
            extra = "".join(
                f" {k}={a[k]}" for k in ("count", "link", "location", "note", "same_id_as_first") if a.get(k) not in (None, "", []))
            body = a.get("body")
            said = ""
            if a.get("kind") in ("text", "empty") or (isinstance(body, dict) and len(json.dumps(body)) < 240):
                said = " " + json.dumps(body, ensure_ascii=False)[:240]
            print(f"  {name}: {a.get('status')} {a.get('type')} {a.get('kind')}{extra}{said}")
        if only_m:
            print(f"  only mastodon names: {', '.join(only_m)}")
        if only_g:
            print(f"  only gotosocial names: {', '.join(only_g)}")
    print(f"\n{same} of {len(ours)} answered the same")


if __name__ == "__main__":
    if "--compare" not in sys.argv:
        if not os.path.exists(CA):
            sys.exit(f"ask: no local CA at {CA} — has make servers finished?")
        for host in (MASTODON, GOTOSOCIAL):
            if f"--only={host}" in sys.argv or not any(a.startswith("--only=") for a in sys.argv):
                Asker(host).run()
    if not any(a.startswith("--only=") for a in sys.argv):
        compare()
