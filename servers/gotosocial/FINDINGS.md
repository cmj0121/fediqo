# What a GoToSocial answers where a Mastodon was asked

Asked 2026-10-13 of the two servers this checkout brings up — Mastodon **4.6.6** and GoToSocial
**0.22.2** (`0.22.2+git-fb2bf13`, SQLite, its defaults but for the rate limit) — with the same
questions, one after the other, by `servers/gotosocial/ask.py`. The questions are the ones the
servers-unlocked checks put to Mastodon (`Mastodon…SaysTests`, `LocalServerTests`), plus the
asks the units still to build will make (the "API outline" of the plan).

This is a record of answers. It makes no such server a source (#283 leaves that out), and it
recommends nothing but the short list at its end.

## How it was asked, and what "the same" means

- `FEDIQO_SERVERS_GOTOSOCIAL=1 make servers`, then `python3 servers/gotosocial/ask.py`. Every
  answer is written whole to `servers/.run/asked/<host>.json`; this file was read off one run.
- **172 asks.** Two answers are counted the same when the status, the kind of body, the names in
  the `Link` header and the names of the fields (three levels down) are the same. Values are not
  compared. Where the app reads the *words* of an answer, the row says so and is counted as
  different even where the shape agrees.
- The existing Swift checks were **not** pointed at this host. They are written against what
  Mastodon's seed makes from inside the server (a suspended account, a moved one, a held-back
  notice, hashtags made to rise), none of which this server's own tool can make; pointed here
  they would fail on the seed, not on the server. What was put to the app's own code is in
  `Tests/FediqoCoreTests/GoToSocialSaysTests.swift` and in the first table below.
- The two seeds are not alike. GoToSocial's has two people, three posts (one changed), a boost,
  a list and two sign-ins; an empty answer here says the server answers, not what a full answer
  looks like.
- Mastodon in this fixture runs with no background worker and no streaming service. Where that
  may be why it answered as it did, the row says "this fixture".

| Group | Asks |
| ----- | ---: |
| Identical | 35 |
| Absent — the server has no such address | 20 |
| Different — answers, but not as Mastodon does | 106 |
| Could not be asked, or not comparable | 11 |

Of the 106, some sixty differ only in which fields a post or an account carries (the rows "a
post, wherever one is carried" and "an account, wherever one is carried" below); the rest differ
in status, in who may ask, or in words.

## What this app does with it today

Read off the code and run through it (`GoToSocialSaysTests`, three checks, passing; the first two
entries were turned by M0, 2026-10-13). The app was not launched.

- **`Detector.detect`**:
  - Mastodon 4.6.6: `.mastodon`
  - GoToSocial 0.22.2: **`.gotosocial`**, since M0 (2026-10-13). Until then `.mastodon`: its front page has no
    `generator` tag, and its own help text links `joinmastodon.org/servers`, which is the last marker
    `HTMLKind.classify` takes for a Mastodon; without that link the probe would say the same, since `version` is
    `0.22.2+git-fb2bf13` and never says "gotosocial". Both still say so. What names it is its node information, which
    a host taken for a Mastodon is now asked: `/.well-known/nodeinfo` lists `/nodeinfo/2.0` and `/nodeinfo/2.1` on
    this server (`/nodeinfo/2.0` alone on Mastodon), and the document says `"software":{"name":"gotosocial"}`
    (`"name":"mastodon"` on Mastodon). Only that word changes the answer; any other, or none, leaves it `.mastodon`
  - Where: `Detect.swift` (`HTMLKind.classify`, `Probe.kind`, `NodeInfo`)
- **A person adds the host**:
  - Mastodon 4.6.6: joined, public timeline and trends read
  - GoToSocial 0.22.2: **refused by name, nothing added** — "%@ is GoToSocial. Only Mastodon can be added this
    session." Until M0 it was joined as a Mastodon with nothing in it, and that is still what a join would meet were
    the host let through: `MastodonJoin.ingest` refuses only when *both* reads fail, the public timeline is 401 and
    what is rising is `200 []`
  - Where: `Join.swift` (`MastodonJoin.ingest`, `SourceJoin.reads`), `ShellSession.refuseMessage`
- **`MastodonClient.said()`**:
  - Mastodon 4.6.6: kind Mastodon, 500 characters, featured hashtags present (10), the rest unsaid
  - GoToSocial 0.22.2: kind **Mastodon**, **5000** characters, featured hashtags present (10), the rest unsaid
  - Where: `Mastodon.swift`, `MastodonHost.swift`
- **`MastodonOAuth.register` for reading and acting**:
  - Mastodon 4.6.6: a client id
  - GoToSocial 0.22.2: a client id
  - Where: `MastodonAuth.swift`
- **`MastodonWrite.post`, `.boost` on and off, with a sign-in the seed made**:
  - Mastodon 4.6.6: the post, boosted, not boosted
  - GoToSocial 0.22.2: the same: its post decodes as a Mastodon's does
  - Where: `MastodonWrite.swift`

## Identical — 35

- **Home with no sign-in, and with a token that is none**:
  - Both answered: 401, JSON naming an `error` (the words differ; `WWW-Authenticate` is Mastodon's alone — see
    Different)
  - What in the app rests on it: `MastodonAuthorized` (a confirmed 401 signs out), `MastodonEndings.isSourcesOwn`
- **A token ended, then used; ended by an app that did not make it**:
  - Both answered: 200 `{}`; then 401; and 403 `unauthorized_client` with the token still honoured
  - What in the app rests on it: `MastodonSignIn` (the one gate that revokes)
- **A code that is no code**:
  - Both answered: 400 with `error` and `error_description` (GoToSocial's `error` is `"sql: no rows in result set"`, not
    `invalid_grant`)
  - What in the app rests on it: `MastodonOAuth`
- **An account or a post nobody has, signed in; terms nobody wrote; a handle nobody has; a handle of a server never
  heard of**:
  - Both answered: 404, JSON `error` (words differ — see "a not-found, by record" under Different)
  - What in the app rests on it: `MastodonHostNotFound`, P1's "has not heard of them"
- **A translation of a post**:
  - Both answered: 404 `{"error":"Not Found"}`
  - What in the app rests on it: `MastodonHostNotFound.isOfTheAddress`
- **A look-up through the source with no sign-in; how the reader stands with no sign-in**:
  - Both answered: 401
  - What in the app rests on it: P15, P4
- **Lists: read, made, removed, a person put on one, the lists a person is on**:
  - Both answered: 200, same fields (`replies_policy` starts `list` on Mastodon, `followed` here)
  - What in the app rests on it: list timelines, #337
- **What belongs with a post (signed in); who favoured a post**:
  - Both answered: 200, same shape
  - What in the app rests on it: opening a post, #334
- **Hashtags a person features, and the reader's own**:
  - Both answered: 200 `[]` on both
  - What in the app rests on it: P11
- **Bookmarks, favourites, conversations, the server's filters, posts waiting to be sent, announcements, the server's
  rules**:
  - Both answered: 200 `[]` on both — nothing seeded in either
  - What in the app rests on it: P13, #326, #338, #333, P17
- **Where the reader stopped: read, and told**:
  - Both answered: 200, same fields (`version` starts at 1 on Mastodon, 0 here)
  - What in the app rests on it: P12
- **A follower removed, asked of nobody**:
  - Both answered: 404
  - What in the app rests on it: P5b
- **The front page, nodeinfo**:
  - Both answered: 200
  - What in the app rests on it: `Detect.swift`

## Absent — 20

The address answers 404 `{"error":"Not Found"}`, which `MastodonHostNotFound.isOfTheAddress`
takes for "no such address" — as it is meant to. Two of the twenty word it otherwise (marked).

- **`GET /health`**:
  - Mastodon 4.6.6: 200 `OK`
  - GoToSocial 0.22.2: 404
  - What in the app rests on it: the fixture's own health check only (`servers-health.sh`,
    `LocalServers.requireHealthy`); this server has `/readyz`
- **`GET /api/v1/streaming/health`**:
  - Mastodon 4.6.6: 301 to itself (this fixture)
  - GoToSocial 0.22.2: 404
  - What in the app rests on it: #325
- **`GET /.well-known/oauth-authorization-server`**:
  - Mastodon 4.6.6: 200, the endpoints and `scopes_supported`
  - GoToSocial 0.22.2: 404
  - What in the app rests on it: nothing today; F1's "a word a server does not know is found at registration" has no
    list to read here
- **`GET /oauth/token/info` (a whole sign-in, a narrower one)**:
  - Mastodon 4.6.6: 200: `scope` as a list, `expires_in`, the app's uid
  - GoToSocial 0.22.2: 404
  - What in the app rests on it: `MastodonAuth.swift` asks it
- **`GET /api/v2/notifications`**:
  - Mastodon 4.6.6: 200, gathered
  - GoToSocial 0.22.2: 404
  - What in the app rests on it: `MastodonNotices.gatheredPath`
- **`GET /api/v2/notifications/policy`**:
  - Mastodon 4.6.6: 200
  - GoToSocial 0.22.2: 404
  - What in the app rests on it: `MastodonNotices.policyPath`
- **`GET /api/v1/notifications/requests`**:
  - Mastodon 4.6.6: 200 list
  - GoToSocial 0.22.2: 404 `"Not Found: notification not found"` — the word after `notifications/` is read as an id, so
    **not** the address's sentence
  - What in the app rests on it: `MastodonNotices.requestsPath`; `isOfTheAddress` says "a record", not "no such thing"
- **`GET /api/v1/notifications/unread_count`**:
  - Mastodon 4.6.6: 200 `{"count":…}`
  - GoToSocial 0.22.2: 404, worded as the row above
  - What in the app rests on it: #324
- **`GET /api/v1/instance/extended_description`**:
  - Mastodon 4.6.6: 200
  - GoToSocial 0.22.2: 404
  - What in the app rests on it: P18, `MastodonHostMore`
- **`GET /api/v1/instance/activity`**:
  - Mastodon 4.6.6: 200, twelve weeks
  - GoToSocial 0.22.2: 404
  - What in the app rests on it: P18
- **`GET /api/v1/suggestions`**:
  - Mastodon 4.6.6: 200 list
  - GoToSocial 0.22.2: 404 (`/api/v2/suggestions` answers — see Different)
  - What in the app rests on it: not read; P10a reads v2
- **`GET /api/v1/endorsements`, `GET accounts/:id/endorsements`, `POST accounts/:id/endorse`, `/unendorse`**:
  - Mastodon 4.6.6: 200
  - GoToSocial 0.22.2: 404, all four
  - What in the app rests on it: P11
- **`GET /api/v1/domain_blocks`, `POST /api/v1/domain_blocks`**:
  - Mastodon 4.6.6: 200 `[]`; 422 with no server named
  - GoToSocial 0.22.2: 404, both
  - What in the app rests on it: P7
- **`GET /api/v1/annual_reports`**:
  - Mastodon 4.6.6: 200
  - GoToSocial 0.22.2: 404
  - What in the app rests on it: #340
- **`GET /api/v1/tags/<one nobody used>`**:
  - Mastodon 4.6.6: 200, a hashtag with an empty `id` and a history of noughts
  - GoToSocial 0.22.2: 404
  - What in the app rests on it: P14: a hashtag's page for a tag never used

## Different — 106

### Who may ask

- **With no sign-in: the public timeline, a hashtag's timeline, a post, what belongs with it, a person by id, their
  posts, who follows them, a hashtag, a search, the directory (both orders), the emoji, the servers it knows, the
  servers it blocks (14 asks)**:
  - Mastodon 4.6.6: 200 for each but the last (404, kept from strangers)
  - GoToSocial 0.22.2: **401** `{"error":"Unauthorized: token not supplied"}` for every one
  - What in the app rests on it: `MastodonJoin.ingest`, `MastodonClient.publicTimeline`, P1/P2 ("with no sign-in what
    anyone is given shows"), P10b, P15, P16, P18, `EmojiCatalogueStore` — every read this app makes before a sign-in
- **A post, with a token that is none**:
  - Mastodon 4.6.6: **200**, as nobody
  - GoToSocial 0.22.2: **401**
  - What in the app rests on it: P1: "a dead sign-in is not noticed on these reads" holds for Mastodon only
- **An account or a post nobody has, no sign-in**:
  - Mastodon 4.6.6: 404
  - GoToSocial 0.22.2: 401
  - What in the app rests on it: `MastodonHostNotFound`: a not-found cannot be told from "sign in" here
- **How the reader stands to someone, with a sign-in holding `read:statuses read:lists read:accounts read:search`**:
  - Mastodon 4.6.6: **403**, `WWW-Authenticate: … error="insufficient_scope" … requires scope read read:follows`
  - GoToSocial 0.22.2: **200**, the standing
  - What in the app rests on it: P4, `MastodonParts` (the follows part): here the reading words already give it
- **A token for the app alone, then `apps/verify_credentials` with it**:
  - Mastodon 4.6.6: 200, the app
  - GoToSocial 0.22.2: 401 `"user not supplied or not authorized"`; the token says `expires_in: 7200` (Mastodon's has
    none)
  - What in the app rests on it: `MastodonOAuth`; nothing reads an app's own token today

### Refusals, and the words the app reads

- **A post, and a follow, by a sign-in that only reads**:
  - Mastodon 4.6.6: 403 `{"error":"This action is outside the authorized scopes"}` and `WWW-Authenticate: Bearer …
    error="insufficient_scope", error_description="… requires scope …"`
  - GoToSocial 0.22.2: 403 `{"error":"Forbidden: token has insufficient scope permission"}`, **no `WWW-Authenticate`**,
    no word named
  - What in the app rests on it: `MastodonScopeRefusal.isOne` looks for the header's `insufficient_scope` or that exact
    sentence: **neither is here**, so this is read as "any other 403", not as a part to ask for
- **Any 401**:
  - Mastodon 4.6.6: `WWW-Authenticate: Bearer … error="invalid_token"`; the body tells a revoked token ("was revoked")
    from an unknown one ("is invalid")
  - GoToSocial 0.22.2: no header; one sentence for no token, a bad one and a revoked one: `"Unauthorized: token not
    supplied"`
  - What in the app rests on it: `MastodonEndings.isSourcesOwn` (JSON naming an `error`: passes); its note to "require
    `invalid_token` in the header" would not hold here
- **A not-found, by address: one it does not serve (`/api/v1/fediqo_no_such_thing`, `/api/v9/instance`,
  `/api/v1/instance/fediqo_no_such`), with and without a sign-in; the two `.well-known` names neither serves**:
  - Mastodon 4.6.6: 404, an HTML page of 500+ bytes
  - GoToSocial 0.22.2: 404 `{"error":"Not Found"}`
  - What in the app rests on it: `isOfTheAddress`: true for both, by different clauses
- **A not-found, by record**:
  - Mastodon 4.6.6: `{"error":"Record not found"}` (an account), `{"error":"Not Found"}` (a post)
  - GoToSocial 0.22.2: `{"error":"Not Found"}` (an account), `{"error":"Not Found: target status not found"}` (a post),
    `"Not Found: @name not found"` (a handle), `"Not Found: list not found"` (a list)
  - What in the app rests on it: `isOfTheAddress` tells the address from a record by the exact sentence `not found`:
    **an account nobody has reads as "no such address" here**, a post nobody wrote as a record — the reverse of Mastodon
    on both
- **A post with nothing in it**:
  - Mastodon 4.6.6: 422 `"Validation failed: Text can't be blank"`
  - GoToSocial 0.22.2: 400 `"Bad Request: status contains no text, media or poll"`
  - What in the app rests on it: `MastodonWrite`, #327: a refusal says what was refused
- **A follow of oneself**:
  - Mastodon 4.6.6: 403 `"Following your own account is not allowed"`
  - GoToSocial 0.22.2: 406 `"Not Acceptable"`
  - What in the app rests on it: P4
- **A post withdrawn twice**:
  - Mastodon 4.6.6: 404
  - GoToSocial 0.22.2: **200**, the post again, its `content` now `<p><em>ℹ️ deleted status ℹ️</em></p>`
  - What in the app rests on it: `MastodonWrite` (withdraw), #179 (a post deleted at its source)
- **The same post sent again under the same `Idempotency-Key`**:
  - Mastodon 4.6.6: **500**, an HTML page, in each of three runs (this fixture; why was not looked into)
  - GoToSocial 0.22.2: **200, a second post under another id** — the key is not honoured
  - What in the app rests on it: `MastodonWrite.post(key:)`, `Unsent`: "a send nobody confirmed can be sent again
    without posting twice" was seen on neither server as asked here; #329
- **The timeline of a list with nobody on it**:
  - Mastodon 4.6.6: 200 `[]`
  - GoToSocial 0.22.2: **the connection is dropped** (502 from the proxy, nothing in the server's log at `warn`); with
    somebody on it, 200
  - What in the app rests on it: list timelines: a new list's first read
- **A list nobody made (`timelines/list/1`)**:
  - Mastodon 4.6.6: — (id 1 is Mastodon's seeded list)
  - GoToSocial 0.22.2: 404 `"Not Found: list not found"`
  - What in the app rests on it: —
- **Too many asks from one address**:
  - Mastodon 4.6.6: `x-ratelimit-limit: 300` in five minutes; registrations of an app (5) and withdrawals (30) each have
    their own; 429 `{"error":"Too many requests"}`
  - GoToSocial 0.22.2: 300 in five minutes for everything together by default, `x-ratelimit-*` on every answer, 429
    `{"error":"rate limit reached"}` (lifted in this fixture)
  - What in the app rests on it: F6's "300 asks in five minutes"

### Signing in

- **An app registered**:
  - Mastodon 4.6.6: `id`, `name`, `website`, `scopes`, `redirect_uris`, `client_secret_expires_at`
  - GoToSocial 0.22.2: the same without `website` and `client_secret_expires_at`, with `created_at`
  - What in the app rests on it: `MastodonOAuth.registered(for:)` (`echoed`)
- **The sign-in page with no app named**:
  - Mastodon 4.6.6: 302 to `/auth/sign_in`
  - GoToSocial 0.22.2: 400, JSON naming each missing field
  - What in the app rests on it: `MastodonSignIn`
- **The sign-in page for an app**:
  - Mastodon 4.6.6: 302, an absolute address
  - GoToSocial 0.22.2: 303, `Location: /auth/sign_in` (relative)
  - What in the app rests on it: the page is the browser's; nothing here follows it
- **A page asking for less than the registration (`read:statuses read:lists read:accounts read:search` on an app
  registered `read write push`)**:
  - Mastodon 4.6.6: opens (F4a)
  - GoToSocial 0.22.2: opens; the token says exactly those words
  - What in the app rests on it: `MastodonParts.page`
- **`verify_credentials` (three asks)**:
  - Mastodon 4.6.6: `source` has `discoverable`, `indexable`, `hide_collections`, `quote_policy`, `attribution_domains`;
    the account has `roles`, `uri`
  - GoToSocial 0.22.2: `source` has `status_content_type`, `web_layout`, `web_visibility`, `web_include_boosts` instead;
    the account is **`locked: true`** as made
  - What in the app rests on it: P8 (`source` is what is changed), P19
- **`PATCH update_credentials` (the note)**:
  - Mastodon 4.6.6: 200, the account as above
  - GoToSocial 0.22.2: 200, the account as above
  - What in the app rests on it: P8

### People

- **An account, wherever one is carried (a person by id, in a list of people, on a post, in a notice)**:
  - Mastodon 4.6.6: has `uri`, `hide_collections`, `roles`, `feature_approval`, `show_featured`, `show_media`,
    `show_media_replies`
  - GoToSocial 0.22.2: **none of the seven**; ids are 26 letters and digits, not a number
  - What in the app rests on it: `MastodonPeople` (`hideCollections` → `hidesLists`): P3's "hidden because the account
    says so" has nothing to read — every list here reads as not hidden
- **Who follows a person, who they follow**:
  - Mastodon 4.6.6: `Link`: `max_id` next, **`since_id`** prev; the id is the follow's
  - GoToSocial 0.22.2: `Link`: `max_id` next, **`min_id`** prev, with `limit`; the id is not a person's either
  - What in the app rests on it: F5/F6: "the source's own next, never rebuilt from a row" holds on both
- **Who boosted a post; the muted; the blocked; requests to follow; hashtags followed**:
  - Mastodon 4.6.6: `Link` with `since_id` (prev only, the list being short)
  - GoToSocial 0.22.2: no `Link` for the first; `limit`, `max_id`, `min_id` for the others
  - What in the app rests on it: F6, P5b, P7, P14
- **How the reader stands to someone**:
  - Mastodon 4.6.6: has `languages`, `muting_expires_at`
  - GoToSocial 0.22.2: neither
  - What in the app rests on it: P4, P6a
- **A mute with `duration=300`**:
  - Mastodon 4.6.6: `muting: true`, `muting_notifications: true`, `muting_expires_at` set
  - GoToSocial 0.22.2: `muting: true`, `muting_notifications: false`, no expiry said
  - What in the app rests on it: P6a: a mute "for a time" comes back with no time
- **How the reader stands to an id nobody has**:
  - Mastodon 4.6.6: `[]`
  - GoToSocial 0.22.2: one entry, every word `false`
  - What in the app rests on it: P4: "none for an id nobody has"
- **A follow (and the same put back after a block)**:
  - Mastodon 4.6.6: `following: true` at once
  - GoToSocial 0.22.2: `requested: true` — an account here is made locked, and stays a request until the other agrees
  - What in the app rests on it: P4 ("a person who must agree shows as asked"), P5b
- **Unfollow, block, unblock, unmute**:
  - Mastodon 4.6.6: 200, the standing with the two fields above
  - GoToSocial 0.22.2: 200, the standing without them
  - What in the app rests on it: P4, P6a
- **A search for people; a look-up through the source (`resolve=true`)**:
  - Mastodon 4.6.6: has `collections` beside `accounts`, `statuses`, `hashtags`
  - GoToSocial 0.22.2: no `collections`; for the look-up the server went to ask `elsewhere.invalid` (its log shows the
    WebFinger) and answered empty
  - What in the app rests on it: P15
- **People suggested (`/api/v2/suggestions`)**:
  - Mastodon 4.6.6: 200, five
  - GoToSocial 0.22.2: 200 `[]`
  - What in the app rests on it: P10a

### Posts and timelines

- **A post, wherever one is carried (timelines, a person's posts, a search, every act's answer — some sixty asks)**:
  - Mastodon 4.6.6: has `quote`, `quote_approval`, `quotes_count`, `filtered`, `tagged_collections`
  - GoToSocial 0.22.2: none of the five; has `interaction_policy`, `text`, `content_type`, `pinned` instead
  - What in the app rests on it: `ProtocolKind.saysQuotes`, #330 (`quote_approval`), #338 (`filtered`); a post still
    decodes (`GoToSocialSaysTests`)
- **An id**:
  - Mastodon 4.6.6: a number, longer is later
  - GoToSocial 0.22.2: 26 letters and digits (`01M4SF3Z1VRS0NSGZA19AQ953T`)
  - What in the app rests on it: `StatusID.later` orders them rightly (same length, then by letter); **`StatusID.before`
    answers nothing for one**, so the read from "one before the anchor" — how a missing stretch is noticed — says
    nothing either way (`MastodonReadOn.swift`)
- **Public and Home timelines, signed in**:
  - Mastodon 4.6.6: `Link`: `limit`, `max_id`, `min_id`; Home answered **206** in one run (this fixture)
  - GoToSocial 0.22.2: `Link` also carries `local=false`; 200
  - What in the app rests on it: `MastodonReadOn`
- **A person's posts**:
  - Mastodon 4.6.6: `Link`: `limit`, `max_id`, `min_id`
  - GoToSocial 0.22.2: `Link` also carries `exclude_reblogs`, `exclude_replies`, `only_media`, `only_public`, `pinned`
  - What in the app rests on it: `PersonPosts`
- **A hashtag's timeline, signed in**:
  - Mastodon 4.6.6: 200 (nothing under this tag in its seed)
  - GoToSocial 0.22.2: 200, with `Link`
  - What in the app rests on it: #288
- **What is rising: posts, hashtags, links**:
  - Mastodon 4.6.6: 200, one of each seeded
  - GoToSocial 0.22.2: **200 `[]`** for all three — it answers, and has nothing
  - What in the app rests on it: `MastodonJoin.ingest` (this is why the join goes through), P16,
    `MastodonHostThing.risingTags` / `.risingLinks`: an empty answer is not "absent"
- **A post changed: its history**:
  - Mastodon 4.6.6: entries without `poll`
  - GoToSocial 0.22.2: entries with `poll`
  - What in the app rests on it: #286
- **A post's source**:
  - Mastodon 4.6.6: `id`, `text`, `spoiler_text`
  - GoToSocial 0.22.2: and `content_type`
  - What in the app rests on it: #332
- **A post withdrawn**:
  - Mastodon 4.6.6: the post with `text`, no `content`
  - GoToSocial 0.22.2: the post with `text` and `content`
  - What in the app rests on it: `MastodonWrite`
- **A picture sent (`/api/v2/media`)**:
  - Mastodon 4.6.6: 200
  - GoToSocial 0.22.2: 200, `meta` also has `focus`
  - What in the app rests on it: P9, #328
- **What the person set**:
  - Mastodon 4.6.6: `posting:default:visibility: public`, has `posting:default:quote_policy`
  - GoToSocial 0.22.2: `posting:default:visibility: unlisted`, no `quote_policy`
  - What in the app rests on it: P19, #327 (a new post starts from these)
- **The document (`/api/v2/instance`)**:
  - Mastodon 4.6.6: has `api_versions.mastodon` (11), `icon`, `configuration.timelines_access`,
    `configuration.accounts.max_pinned_statuses` and the length limits of a profile
  - GoToSocial 0.22.2: none of those; has `account_domain`, `configuration.emojis`,
    `configuration.statuses.supported_mime_types`; `max_characters` 5000, 6 attachments, 6 poll options; `version` a
    bare number
  - What in the app rests on it: `Probe.kind`, `MastodonHostSays`, `SourceProfile.statusLimit`, #328, #331
- **The older document**:
  - Mastodon 4.6.6: has `contact_account`
  - GoToSocial 0.22.2: has `max_toot_chars`, `account_domain`
  - What in the app rests on it: not read
- **A hashtag; followed; unfollowed; the followed ones; a search for hashtags**:
  - Mastodon 4.6.6: `id`, `featuring`, a `history` of days; in a search also `following`
  - GoToSocial 0.22.2: no `id`, no `featuring`, `history: []`; in a search no `following`
  - What in the app rests on it: P14 (the page shows which it is), P11 (`featuring`), P16 (a row's figures come from
    `history`)
- **Notices (`/api/v1/notifications`)**:
  - Mastodon 4.6.6: each has `group_key`
  - GoToSocial 0.22.2: no `group_key`
  - What in the app rests on it: `MastodonNotices` requires `groupKey` of the gathered read, which is absent here; the
    single read is the only one
- **Emoji, signed in**:
  - Mastodon 4.6.6: 200, one seeded
  - GoToSocial 0.22.2: 200 `[]`
  - What in the app rests on it: `EmojiCatalogueStore`

## Could not be asked, or not comparable — 11

- **An app registered with a word no server knows; with no words (2)**:
  - Why: Mastodon allows five registrations in a window and the suite had spent them: 429
  - What was answered: GoToSocial: **200**, and echoes the unknown word in `scopes` (`["read","fediqo:no_such_word"]`);
    with none, `["read"]`. Mastodon's answer is in `MastodonSignInCaptures`: 422, refused whole
- **The same words asked twice on one registration; what is said beside a token; one of the two ended, then each used
  (5)**:
  - Why: GoToSocial only — Mastodon's answer is F4a's, in `MastodonSignInSaysTests` (one token for every holder)
  - What was answered: **two tokens**, each said with `scope`, `token_type`, `created_at` and no expiry; ending one
    (200) leaves the other honoured (200) and the ended one 401
- **A person by handle, with and without a sign-in (2)**:
  - Why: the handle asked (`other`) is nobody in Mastodon's seed: 404
  - What was answered: GoToSocial: 200 signed in, 401 without
- **A request to follow agreed to, both ways (2)**:
  - Why: nobody is locked in Mastodon's seed: 404
  - What was answered: GoToSocial: 200, the standing; the answer still says `requested: true`, and the next read says
    `following: true`

Not asked of either, and so not known: the streaming service (a socket, #325); polls made and
voted on (#331); scheduled posts (#333); reports (#339); an account suspended, moved, limited
or of another server (this server's tool makes none); a blocked-by standing; anything federated
— the fixture is one server alone; announcements, conversations, filters and suggestions with
something in them; any setting of this server but its defaults (whether a stranger may read
its public timeline is one of them).

## What a unit still to build should not assume

Each names the unit of `PLAN-mastodon.md` it touches.

1. **That a host the detector calls Mastodon is one.** This one was called Mastodon and joined
   empty until M0 asked it what it calls itself; a server that does not say is still taken for
   one — P2, P10b, P16, P18 and every read "with no sign-in" would meet 401, not content.
2. **That a scope refusal is recognisable.** The 403 here has no `insufficient_scope` and not
   Mastodon's sentence, and names no missing word — P4, P5b, P6a, P7, P8, P11, P17 and the
   "signed in for less" line of each would read it as any other 403.
3. **That the reading words do not give the standing.** Here a reading sign-in is told how it
   stands — P4.
4. **That a follow is a follow.** An account made here is locked: a follow answers
   `requested: true` and stays so until agreed to — P4, P5b.
5. **That an account says whether it hides its lists.** `hide_collections` is never sent, nor
   `uri`, nor `roles` — P5b's lists, P7's lists, P8.
6. **That a mute for a time says when it ends**, or mutes notices too: no `muting_expires_at`,
   no `languages`, `muting_notifications: false` — P5a, P6a.
7. **That an absent thing answers 404.** What is rising, suggestions and announcements answer
   `200 []` here whether or not the server has them — P17, and what F3 calls present, absent
   and unsaid. And a 404 whose whole sentence is `"Not Found"` is said of an account here and
   of the address on Mastodon.
8. **That people featured, blocked servers, the gathered notices, the unread count, the longer
   account, the activity and a token's own account of itself exist** — P11, P7, #322 (#324).
9. **That an id is a number**, so that "one before it" can be asked — P12 (a marker's place),
   P13 (reading on to the oldest mark).
10. **That a post sent twice under one key lands once.** It landed twice here, and Mastodon in
    this fixture answered 500 to the second — #327 (#329).
11. **That the same words on one registration are one token.** Here they are two, each ended
    alone — P6a, P7, P8 as each adds a part through F2a's path, and Decision 9's account of
    another device.
12. **That an unknown word is refused at registration.** It is accepted and echoed here — the
    same units as 11.
13. **That a hashtag has an id, says whether it is featured, or carries a history** — P11.
14. **That a post says whether it quotes, how it may be quoted, or why it is hidden** — #327
    (#330), #336 (#338); and that a new post starts public — #327 (the default here is
    `unlisted`).
15. **That a list just made can be read.** Its timeline drops the connection until somebody is
    on it — #336 (#337).
16. **That a withdrawn post is gone on the next ask** — #327: here it answers 200 again.
