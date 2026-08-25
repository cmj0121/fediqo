# The store

[English](data-store.md) | [繁體中文](data-store.zh-TW.md)

> Everything Fediqo reads or writes lands in one local database and never leaves it.

SQLite through GRDB, and GRDB is the only external dependency. This describes what is stored, how a post
gets in, and what "the same post" means. The tables themselves live in [`schema.sql`](schema.sql), which is
the baseline migration 001 has to match.

The scope is posts first: a public timeline, and a timeline filtered by tags, servers, authors or keywords.
Everything else waits, for a reason given under [What waits](#what-waits).

## The rule

> **What a network handed over is written once and never rewritten. What you decide is a separate,
> revisable layer on top of it.**

Choosing a server, following a tag, muting one: each is a column a refresh never writes, and withdrawing
the decision sets it back to `NULL`. The original is still there.

Migrations obey the same rule: append only. `CREATE`, `ADD COLUMN`, `CREATE INDEX`, and nothing else, since
a migration that destroys is still a rewrite. `posts_fts` is the single exception, because it is derived.

## The shape

The store is on the read path, not beside it.

```text
       network refresh                       screen
             │                                  ▲
             ▼                                  │
   ┌──────────────────┐  writes   ┌─────────────┴─────────────┐
   │  source clients  │──────────▶│          SQLite           │
   └────────┬─────────┘           │  every row on screen      │
            │ failures only,      │  comes from here          │
            │ never posts         └───────────────────────────┘
            ▼
      a banner: which server, and why

   a server is down  ──▶  every existing row still shows, there is just nothing new
   an empty screen   ──▶  only when the store really is empty, which is a fresh install
```

A refresh returns failures, not posts. A server declining is a line above a full timeline, never an empty
one.

## What lives where

| state                                     | where          | why                                                 |
| ----------------------------------------- | -------------- | --------------------------------------------------- |
| theme, text size, language, rail          | `UserDefaults` | the first frame needs them before the store opens   |
| posts, accounts, servers, and their links | SQLite         | social data                                         |
| the two standing filters (boosts, media)  | `UserDefaults` | stored there, but applied as bind parameters in SQL |
| the timelines you made, and their rules   | SQLite         | rows: ordered, pointing at a base source and an account |
| the fact of being signed in               | SQLite         | the credential lives in the Keychain, never here    |

A filter applied in Swift after a page is read gives every page a different length, so filtering belongs in
the query whatever holds the value.

Reading preferences synchronously also means the app survives a database that will not open: **that is a
screen, not a crash**, and the screen has to be readable in the right language.

## Four layers

```text
network   what a server handed over. A refresh writes; only an authority edits.
          protocols, feeds, filter_kinds, servers, accounts, posts, tags, post_tags,
          post_origins, post_mentions, server_trends

local     what you decided, and can withdraw. Only you.
          servers.selected_at, servers.position, tags.followed_at, tags.muted_at, owned_accounts,
          timelines, timeline_filters

record    what was counted here, and kept after the rows it counted are purged.
          tag_buckets

derived   a droppable index.
          posts_fts
```

One arrow per foreign key, pointing at the table it references:

```text
   ┌───────────┐
   │ protocols │
   └─────▲─────┘
         │ proto
         ├───────────────────────┬───────────────────┐
   ┌─────┴─────┐ server_url ┌────┴─────┐             │
   │  servers  │◄───────────┤ accounts │             │ proto
   └──▲──▲─────┘            └────▲─────┘             │
      │  │ authority_url         │ author_id         │
      │  │ source_url            │ boosted_by        │
      │  │                  ┌────┴────┐              │
      │  └──────────────────┤  posts  ├──────────────┘
      │                     └─▲──▲──▲─┘
      │ source_url   merge_key │  │  │ merge_key
   ┌──┴───────────────┐        │  │  │        ┌───────────┐  tag  ┌──────┐
   │  server_trends   ├────────┘  │  └────────┤ post_tags ├──────►│ tags │
   └──────────────────┘           │           └───────────┘       └──▲───┘
                                  │ id                               │ tag
                            ┌─────┴─────┐                    ┌───────┴─────┐
                            │ posts_fts │  (not a FK)        │ tag_buckets │
                            └───────────┘                    └─────────────┘

   not FKs    posts.in_reply_to_uri ──► posts.uri, matched at read time
              posts_fts.rowid = posts.id, kept in step by the triggers
              tag_buckets counts post_tags × posts, and keeps the count after a purge
```

Migration 004 hangs four more off that spine, and one lookup table each side of them:

```text
   ┌───────┐ feed  ┌──────────────┐ merge_key  ┌───────┐
   │ feeds │◄──────┤ post_origins ├───────────►│ posts │◄──┐ merge_key
   └───▲───┘       └──────┬───────┘            └───────┘   │
       │ feed             │ source_url / author_id     ┌────┴──────────┐
   ┌───┴───────┐          ▼                            │ post_mentions │
   │ timelines │    servers / accounts                 └───────────────┘
   └───▲───────┘
       │ timeline_id   ┌───────────────────┐  kind  ┌──────────────┐
       └───────────────┤ timeline_filters  ├───────►│ filter_kinds │
                       └───────────────────┘        └──────────────┘

   not a FK   post_mentions.mention_uri ──► accounts.author_id, matched at read time
```

A local decision is never a column a refresh writes. It does sit on a network table — `servers` carries
`selected_at` and `position`, `tags` carries `followed_at` and `muted_at` — and the rule that keeps it
honest is written into the SQL rather than into a habit:

```sql
INSERT INTO servers (url, host, proto, title, created_at)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(url) DO UPDATE SET
    proto = excluded.proto,
    title = excluded.title;
    -- selected_at and position do not appear here. That is the rule.
```

`servers` is a catalogue of every host we have met, not a list of the ones you chose; choosing is
`selected_at`, and removing a server sets it back to `NULL`. **The row is never deleted**, so a server you
drop takes nothing with it and every post it ever handed you still shows.

Signing in is the same kind of decision, big enough for a table of its own: migration 002 adds
`owned_accounts`, one row per account that is yours. The token lives in the Keychain, keyed by
`author_id`; the row records only the fact. Signing out deletes the row — the account and every post it
handed over stay.

Making a timeline is the largest decision of that kind, and migration 004 gives it two tables: `timelines`
and `timeline_filters`. They sit in the local layer for the same reason `selected_at` does — no refresh
writes them, and deleting one takes nothing but itself.

## What a post remembers besides itself

**A post is one row and stays one row**, whichever timelines show it. Everything this device learns about a
post that is not the post itself is written beside it, by migration 004:

| table           | a row says                                                                      |
| --------------- | ------------------------------------------------------------------------------- |
| `post_origins`  | `source_url` handed `merge_key` over through base source `feed`, to `author_id` where it has an owner |
| `post_mentions` | post `merge_key` names the account at `mention_uri`, spelled `handle` by the post's own server |

A base source is what a server can be asked for: `public`, `home` or `trend` today, rows in `feeds` rather
than cases in an enum, because a server's hashtag timeline and a server's lists are both base sources
waiting to happen. Seeing the same post arrive again through another one **adds a row**; being told again
through the same one moves `last_seen_at` and nothing else.

`author_id` is whose home it arrived in, and NULL for `public` and `trend` — an honest NULL, since a public
timeline belongs to nobody. It is written now rather than when a second account appears, because a column
added later is never backfilled: every post already stored would be one that could not say whose home it
was in. Uniqueness is two partial indexes rather than a primary key, because SQLite does not enforce NOT
NULL on a rowid table's primary key columns and NULLs are distinct to a unique index — a four-column key
would have let every anonymous sighting insert another row for ever.

`post_mentions` has no foreign key to `accounts`, for the reason `posts.in_reply_to_uri` has none: a post
routinely names people this device has never been handed. No half-empty account row is invented for them.

**Migration 004 backfills, which is the one exception to the rule above**, and it is defensible only because
the inference is exact: until then there was one timeline endpoint in the app, `/api/v1/timelines/public`,
and `server_trends` already names every post that came through a trending list. A post that arrived only
through a trending list gets a `public` row anyway — before 004 the store handed the whole of itself to the
timeline, so that post was on the reader's screen, and the backfill's job is that nobody opens this version
to a shorter timeline than they closed the last one with.

## A timeline is a filter, not a list

A timeline the reader makes is **one base source and any number of rules**. One base source, because two
would leave the order undecided; the rules only ever add or remove.

```sql
SELECT … FROM posts p JOIN accounts a ON a.author_id = p.author_id
WHERE p.deleted_at IS NULL
  AND EXISTS (SELECT 1 FROM post_origins o
              WHERE o.merge_key = p.merge_key AND o.feed = ? AND o.author_id = ?)
  AND EXISTS (SELECT 1 FROM post_tags pt WHERE pt.merge_key = p.merge_key AND pt.tag = ?)
ORDER BY p.posted_at DESC, p.merge_key
LIMIT ?
```

Nothing is copied into a timeline and no post row says which timelines it is in. A post the timeline being
read filters out is still saved, and the next timeline the reader makes finds it already here.

**A timeline that ships with the app keeps no words of its own.** `name` and `summary` are
empty for the rows seeded on a first run, and the screen takes both from the template each time
it draws them — which is how Public and Trending are said in the reader's language rather than
in whichever one was on the day the row was written. Typing a name makes the row carry theirs,
and nothing translates a name a reader chose.

`clearSeededWording` is the one-time repair for stores an older build wrote words into: every row
whose `id` is its template's name is cleared, once per install, and the install remembers that it
has been. It does not try to work out from the row whether the words in it are the app's, because
nothing in the row can answer that — `updated_at` is stamped by reordering as much as by renaming,
and comparing against the app's own words breaks the moment a release rewrites one.

**Order belongs to the base source.** `feeds.ranked` is where it lives — `public` and `home` in timestamp
order, `trend` in the order the server handed over — so no rule reaches it and the reader has no switch for
it. `timelines.template` is where a timeline came from and never a live link: a template seeds one and has
nothing to say to it afterwards, so shipping a new version of a template cannot rewrite a list somebody
named.

## Time

Timestamps are `INTEGER` milliseconds since epoch, everywhere, no exceptions. Nostr hands out seconds and is
multiplied on the way in — which means its milliseconds are always `000` and its posts collide far more
often than the other two, so the tie-break in `ORDER BY` is a requirement, not insurance.

Every table carries the same pair:

| column       | means                                              | null? |
| ------------ | -------------------------------------------------- | ----- |
| `created_at` | when this row appeared **here**, not when it happened | never |
| `updated_at` | when one of its values last changed                 | NULL means never |

`updated_at` moves only on a real change. A refresh that hands over identical data leaves it alone, which is
what separates it from `posts.last_seen_at` — a post offered a hundred times and never edited has a hundred
sightings, one `created_at`, and a `NULL` `updated_at`.

Anything else a table needs about time is named for what it is: `posted_at`, `last_seen_at`, `selected_at`,
`deleted_at`. In particular `posts.posted_at` is when the **author** wrote it and `posts.created_at` is when
**we** first stored it; a policy that counts age counts from the second, because a post that arrived today
has not been here since it was written.

## Servers are endpoints, not hostnames

One hostname can speak more than one protocol — a domain may serve ActivityPub on `https` and a Nostr relay
on `wss` — and a Nostr relay is a URL in the first place, with a scheme, sometimes a port, sometimes a path.
A bare hostname cannot express any of that, so `servers` is keyed by a normalised endpoint URL:

```text
https://mastodon.social        AP / Mastodon; port and path are implied
https://bsky.social            an atproto PDS
wss://relay.damus.io           a Nostr relay
wss://relay.example.com/v1     a Nostr relay with a path
wss://localhost:7777           a Nostr relay with a port
```

Normalising means: lowercase the scheme and host, drop a default port, drop a trailing slash, drop query and
fragment, keep the rest. **Two rows sharing a hostname are two servers**, and that is correct rather than a
duplicate. `servers.host` keeps the bare hostname alongside, indexed, for grouping and for display.

## Sets that may grow are tables, not CHECKs

`proto` is a foreign key into `protocols`.

Append-only migration is the reason. SQLite cannot alter a `CHECK`, so a schema that spelled the legal values
into one would need the table rebuilt to add a fourth protocol — and rebuilding is exactly what the rule
forbids. As a foreign key, adding one is an `INSERT`. The constraint is real either way: the database rejects
an unknown value, rather than trusting Swift to have remembered.

The line is whether the set can grow. A value that can never gain a third member stays plain `TEXT`; a
lookup table of two permanent rows buys nothing.

The same now-or-never logic makes every table `STRICT`. SQLite otherwise treats declared types as
suggestions — `created_at INTEGER` accepts the string `"yesterday"` without complaint — and `STRICT`
cannot be added later, because adding it is a rebuild. With it, a wrong type fails at write time
instead of being stored silently, whatever path the write came in by.

## Two URIs

A post has an id, and it has an address you happened to reach it at. In ActivityPub they are not close:

```text
origin_uri   https://mastodon.social/users/alice/statuses/109…   the same everywhere
uri          https://a.example/api/v1/statuses/44215             a.example's local number
```

`origin_uri` is identity and drives everything — the key, the authority check, `authority_url`. `uri` is
provenance, and it is also the fallback identity for the rare source that gives no canonical id at all.

`origin_uri` is **this post's own canonical id, never the post it was copied from**. A bridged copy's
`origin_uri` is the bridge's, because a bridged copy is another post by another actor. The relationship to
what it copies is a claim, and the store records no claims today — see [What waits](#what-waits).

### Replies point at a third URI

All three protocols hand over the post a reply answers — Mastodon's `in_reply_to_id`, atproto's
`reply.parent`, Nostr's `e` tag — so `posts.in_reply_to_uri` keeps it. Without it a timeline cannot indent a
reply or hide replies to people you do not follow, which is what every other client does by default.

It holds an address, **not a foreign key**. A reply routinely arrives before the post it answers, and a
foreign key would reject it; a thread is a join at read time on `posts.uri`, and a parent that has not
arrived is simply absent. Both sides are indexed — `posts_by_reply` and `posts_by_uri`.

It is stored from the first write rather than added later, because a column added later is never backfilled:
what a network handed over is written once, so every post already stored would keep an empty value forever.
That is the trap append-only sets for itself, and the way out of it is to decide before the freeze.

## Hashtags

A post carries many tags and a tag is carried by many posts, so they are two tables: `tags` and `post_tags`.

They come from the protocol — Mastodon's `tags[]`, atproto's facets, Nostr's `t` — and are parsed out of
`text` only when a source supplies no list of its own. A tag matches case-insensitively and displays
case-preserved, which is two columns rather than one:

| column         | holds                             | example              |
| -------------- | --------------------------------- | -------------------- |
| `tags.tag`     | NFC, lowercased, no leading `#`   | `blacklivesmatter`   |
| `tags.display` | a representative casing           | `BlackLivesMatter`   |

**Searching by tag never touches `posts_fts`.** `WHERE tag = ?` is one index hit on `post_tags_by_tag`, it is
exact rather than tokenized, and it already works for a Chinese tag today — whatever the tokenizer question
at the end of this file settles on. The timeline can therefore filter by tag without reading `extras`, and
that rule stays intact.

### Search has a key of its own

`posts` carries an `id INTEGER PRIMARY KEY` that nothing else uses. It exists because `posts_fts` is an
external-content index and has to name its rows by rowid. With `merge_key` (a `TEXT` key) as the only key,
that rowid would be implicit — and **SQLite may renumber an implicit rowid during `VACUUM`**. Every row in
the index would then point at a different post, and nothing would raise an error: search would just return
the wrong post, quietly. An `INTEGER PRIMARY KEY` is an alias for the rowid, and `VACUUM` leaves it alone.

`merge_key` loses nothing by this. It is `UNIQUE NOT NULL`, every foreign key still points at it, and it is
still what breaks ties in the ordering. `id` is plumbing for one index, and never leaves the store.

There is no count column on `tags`. A counter drifts; `count(*)` over the index does not.

Following and muting a tag are `followed_at` and `muted_at` on `tags`, on the `servers.selected_at`
precedent: local columns on a network table, which a refresh writes `display` into and never touches.

An authoritative edit replaces the post's whole tag set, the same way it replaces the text. A
non-authoritative source that disagrees changes nothing — the same rule as every other field.

## Trends are two things

A server can say a post is trending, and the store can count for itself. They are different facts, in
different layers, and they are kept apart:

| table           | layer   | what a row says                                                        |
| --------------- | ------- | ---------------------------------------------------------------------- |
| `server_trends` | network | server `source_url` listed post `merge_key` at `rank`, between `first_seen_at` and `last_seen_at` |
| `tag_buckets`   | record  | in the hour starting `bucket_at`, `tag` was carried by `posts` posts from `authors` authors |

`server_trends` is what a server handed over, so it obeys the network rules: keyed `(source_url, merge_key)`,
`first_seen_at` written once, `last_seen_at` touched on every sighting, and `ON DELETE CASCADE` from `posts`
because a trend for a post that is gone says nothing. The Trending screen is `posts ⋈ server_trends` on
`server_trends_recent` — `WHERE last_seen_at` is recent, `ORDER BY rank` — and it reads the store, not the
network, so it works offline and a stale row simply drops off the screen.

Migration 004 adds `removed_at`, because staleness could not stand in for leaving the list. `ServerBackoff`
exists to stop asking a server that is not answering, so "not seen for a day" covers a post that fell off
the list and a server nobody asked — two different facts. The mark says the narrower true thing, the way
003 taught `deleted_at` to say one: **the list this server hands over no longer contains this post.** Not
that it stopped rising, which a list with a length cannot tell anybody. It is only ever written from a list
that arrived and is never written from an empty one, so a server that was skipped, backed off or has turned
trending off marks nothing; a post back on the list has the mark lifted rather than a second row.

`tag_buckets` is the third layer, **record**, and the reason it exists is that it outlives what it counted.
A bucket is an hour of `posted_at`. After each refresh, every hour a post of that refresh falls into is
recounted from `post_tags` × `posts`, and a bucket only ever goes up — `posts` and `authors` take the `max`
on conflict, and there is no `DELETE`. A purge deletes the posts; the bucket keeps the count, and a post
that arrives late for an hour already purged cannot pull it back down. A trend
is then one window summed against the one before it, over `tag_buckets_by_tag`, and `authors` is there
because one voice posting two hundred times is not a trend.

## What counts as the same post

Two tiers, first match wins:

```text
1.  boost:<booster author_id>|<origin_uri>
2.  <origin_uri>, or <uri> when origin_uri is NULL
```

Identity only. Nothing is guessed from `web_url`, from content or from timing — no content hashing, no
similarity, no same-author-same-minute. A later policy that wants to collapse more is a new table read at
query time, and never a change to `merge_key`: the key is written once, like everything else a network
handed over.

**Two different `origin_uri` values are two different posts** and stay two rows. `proto` is never part of
the key — one post read through two protocols carries one `origin_uri` and has to collapse. Every URI is
stored scheme-qualified, `https://…`, `at://…`, `nostr:…`, so the key says what it is.

Never merged: a boost with its original, one person's boost with another's, a quote with what it quotes.
Tier 1 separates the first two on purpose.

### Arriving

```text
   a post arrives from host H
             │
             ▼
   is there an origin_uri?
   ┌─────────┴──────────┐
  yes                   no
   │                     │
   ▼                     ▼
 fast path            fall through the tiers
 merge_key = origin_uri   boost → uri
 the primary key         │
 hits or it inserts      │
   └──────────┬──────────┘
              ▼
   is H the authority? (posts.authority_url = H, or a signature that verified)
```

### Which copy wins

Two servers carrying one post can disagree about its text. Taking whichever arrived first makes the result
depend on network timing, and lets a fast server claim someone else's id.

**The copy from the authority for that `origin_uri` wins; every other source changes nothing.**
`posts.authority_url` stores who that is, so the check is a column comparison rather than a re-parse on every write:

| protocol      | `posts.authority_url`      | who is actually the authority         |
| ------------- | -------------------------- | ------------------------------------- |
| Mastodon / AP | the origin in the URI      | that server                           |
| AT Protocol   | the PDS the DID points at  | the signature; the PDS carries it     |
| Nostr         | `NULL`                     | the event signature, verified locally |

`NULL` means something exact here: **this post's truth does not rest on any server**. A non-authoritative
source that disagrees is simply ignored; recording what it said is one of the tables that waits.

## Deletion

A post a server stops handing over is marked, not removed: `posts.deleted_at` is set once and never
rewritten, the same as every other network field. The timeline reads past it with `WHERE deleted_at IS
NULL`, and the partial index `posts_deleted` finds the marked rows without scanning the rest.

### What the mark actually says

Not "the author deleted it". **It says the server whose word on the post is final will not hand it over
any more**, which is a deliberately narrower claim.

Measured against mastodon.social on 2026-08-25: a status it will not give answers **404**, not 410 — so a
store listening only for a tombstone would never hear one. And a 404 to a request nobody is signed in for
covers three different things at once: a post taken down, a post whose visibility has since narrowed, and
an account that has blocked us. Nothing in the answer separates them, so the mark does not pretend to.
What is true of all three, and what the reader experiences either way, is that the post cannot be had from
there any more. So 404 and 410 are read as one answer.

### How it comes to be written

Absence is never enough. When a server hands over a page, the posts this store holds **from that server**
that fall inside the stretch the page covers and are not in it become *suspects* — a question, never a
verdict. A server takes blocked accounts and filtered posts out of a range it has already chosen, so a
page routinely leaves out posts that are perfectly well there, and a filter turned on can leave out a
whole page of them at once.

Every timeline page counts, a refresh's as much as a reach-down's: which of them asked says nothing about
what a page is evidence of, and the newest page is the one stretch reading downward never revisits —
which is exactly where a post pulled down moments after it went up sits. A trending list is not a page of
this kind and raises nothing: it is a snapshot a server curated, so a post's absence from it means the
server does not think it is rising, which is not a claim about whether the post is there.

The stretch is what the page arrived with — its own newest and oldest — not what was asked for. A page of
forty that comes back with three speaks for those three and nothing beyond them. An **empty page covers
no stretch at all**, and so leaves nothing out: it is the server saying it has nothing older, and reading
it as a page that omitted everything would suspect the whole timeline every time a reader reached the
bottom.

A suspect is settled only by asking for that one post by name, and only an answer settles it:

| the answer     | what happens                                           |
| -------------- | ------------------------------------------------------ |
| 404 or 410     | `deleted_at` is set                                     |
| 200            | the suspicion is dropped — the post is there            |
| 401 or 403     | nothing is decided, and no wait is started — it replied |
| anything else  | nothing is decided; it is asked again another time      |

A refusal is not silence, and the difference matters twice over. A server that declines to show a stranger
one post has answered at once, so it has earned no backoff — and because that wait is keyed by endpoint and
shared with the chosen servers, counting it as silence would skip that server's own signed-in timeline for
having turned down an anonymous question. But a standing refusal is still a standing answer: after three of
them the question is **set aside** — not marked, not forgotten, simply no longer holding one of the eight
places a pass has to spend. A relaunch raises it again, since none of this outlives the app.

Who is asked is `posts.authority_url`, the server the post's own canonical address names — and never
`posts.source_url`, whoever happened to hand it over. A relay that has stopped carrying somebody else's
post has said nothing about whether that post still exists, so its silence is not evidence. A post with no
`authority_url`, or whose canonical address is not one this build knows how to ask about, has nobody who
could answer and is therefore never marked at all.

A boost inherits the authority of the post it carries, so asking about one asks whether the original is
still there. If the original goes, the boost goes with it, which is right — a boost of a post nobody can
read shows nothing. If the booster takes their boost back while the original stands, the answer is still
yes and the row stays. Noticing that is a different question and this does not ask it.

Confirmation is bounded: a pass asks about at most eight, and an authority inside its backoff wait is not
asked at all, so a server already struggling is not then hammered with single-post requests. What is left
over waits for the next pass. It is never dropped, and never counted as checked.

Purging a marked row is **the one `DELETE` the store performs**, and it runs only by policy — a routine sweep,
or the database growing past a size — never as part of a refresh. `post_tags` and `server_trends` go with it
by `ON DELETE CASCADE`; the trigger takes the row out of `posts_fts`. `tag_buckets` is left alone: the count
was taken while the post was here, a purge does not unsay it, and a bucket never goes down — not even when a
late post recounts an hour that has already been purged.

After a purge, a server that hands the post over again gets a new row. That is accepted: the store never
promised to remember what it chose to forget, and a tombstone kept for ever would be the rotation problem in
a different shape.

## Protocols that differ

| thing                        | Mastodon / AP      | AT Protocol           | Nostr                  |
| ---------------------------- | ------------------ | --------------------- | ---------------------- |
| public timeline without auth | yes                | mostly                | yes, via relays        |
| trending                     | an endpoint        | feed generators       | none                   |
| author deletion              | definite           | definite              | a request, may be lost |
| editing                      | in place           | none                  | replaceable events     |
| its own fields               | CW, language, poll | labels, langs, facets | tags, relay, signature |

The last row goes in `extras` as JSON, under one rule that can be enforced and tested:

> **The timeline never reads `extras`.** Only the client that wrote it and the post detail renderer do.

Both JSON columns are checked at write time: `extras` must be an object, `media_urls` must be an array, and
either may be `NULL`. `STRICT` only promises the column holds text — it would store `'[broken'` without
complaint, and `json_extract()` would then fail at read time, on the path that draws the timeline. A `CHECK`
cannot be added to an existing table, so the shape those columns were always documented to have is written
into the schema now rather than trusted to whoever writes next.

The rows above it are capabilities, not fields, and belong on the source client as a value a screen can ask
about. Screens ask what a source can do; they never ask what it is called. Where a protocol cannot tell us
something — a deletion that may never reach us — the answer is to say so, not to pretend.

## What waits

The append-only rule treats columns and tables differently, and the schema is shaped by that asymmetry:

> **A column added to `posts` later is never backfilled. A table added later costs nothing.**

A network field left out of `posts` today would be `NULL` on every post already stored, for ever, because
what a network handed over is written once. So `posts` keeps every network field now — `in_reply_to_uri`,
`boosted_by`, `web_url`, `media_urls`, `extras`, `deleted_at` — whether or not a screen reads it yet.

A table, on the other hand, starts empty whenever it arrives and hangs off the spine by foreign key. Nothing
is lost by waiting, so these wait until a screen needs them:

| waits                                     | for                                                        |
| ----------------------------------------- | ---------------------------------------------------------- |
| notifications, and their kinds            | an account of your own; a public timeline needs none       |
| identities and account aliases            | people who move servers; a claim, never a rewrite          |
| composition posts                         | a published post recognised as one of several              |
| merge hints, reasons and resolutions      | pairs no id can decide, and what you said about them       |
| post divergences                          | what a non-authoritative source said and was ignored       |

Each is a new `CREATE`, read at query time as a join on `merge_key` or `author_id`. None changes a row that
is already there.

## Writing

```text
   a post arrives ── from host H, protocol P
             │
             ▼
   the client emits origin_uri (or nothing), the uri it answered on, and a stable author_id
             │
             ▼
   UPSERT servers ── H, and the endpoint origin_uri names, if either is new;
             │       the author's and the booster's host too, title unknown
             │       proto and title only, and a title once known is never
             │       blanked; selected_at is yours
             ▼
   UPSERT accounts ── names change, ids do not
             │
             ▼
   UPSERT tags ── the protocol's list, or parsed from text only if it gave none
             │
             ▼
   merge_key ── boost, else origin_uri, else uri
             │
             ▼
     BEGIN ──▶ SELECT posts WHERE merge_key = ?
             │
   ┌─────────┴──────────┐
 no such row        it is there
   │                    │
   ▼                    ▼
 INSERT posts     touch last_seen_at
   │                    │
   │                    ▼
   │             is H authoritative? (authority_url = H, or the signature verified)
   │               ┌────┴────────────┐
   │             yes                no
   │               │                 │
   │               ▼                 ▼
   │          update the        change nothing
   │          content, or set
   │          deleted_at if the
   │          remote says so
   │               │                 │
   └──────────┬────┴─────────────────┘
              ▼
     replace post_tags for this post if an authority edited it
              │
              ▼
     UPSERT server_trends ── if H listed it as trending: rank and last_seen_at
              │               move, first_seen_at does not
              ▼
     trigger keeps posts_fts in step  ──▶  COMMIT
              │
              ▼
     recount tag_buckets for every hour ── once, after every post of the
     a post of the refresh was posted in    refresh is in; a count only goes up
```

One transaction per refresh, not per post. Nothing on the way scans a table: `merge_key` is `UNIQUE`,
`servers.url`, `accounts.author_id` and `tags.tag` are primary keys, and the reply lookup is
`posts_by_uri`. The order is fixed by the foreign keys — `protocols` → `servers` → `accounts` → `posts` →
`tags` → `post_tags` → `server_trends` — and `tag_buckets` comes last because it counts what the refresh
just wrote. A bucket is keyed by the hour a post was posted in, not the hour it arrived, and it is monotone:
`posts` and `authors` take the `max` of the old count and the new one, and nothing deletes a row.

## Reading

```text
   posts   the spine — what arrived, never rewritten
     │
     ├── WHERE deleted_at IS NULL
     │
     ├── JOIN accounts ──▶ who wrote it; author filter is posts_by_author_time
     │
     ├── JOIN post_tags ──▶ only when a tag was asked for. An index hit on post_tags_by_tag, not a search
     │
     ├── JOIN posts_fts ──▶ only when there is free text to search for
     │
     ├── WHERE ── filters add and remove rows; they never move one
     │            servers filter is posts_by_source
     │
     ├── ORDER BY posted_at DESC, merge_key
     │        the only ordering there is. merge_key breaks ties because it is
     │        UNIQUE and never NULL, so the order is total and a page
     │        boundary lands in the same place on every refresh
     │
     └── LIMIT ── paging happens here, after filtering
           │
           ▼
        the screen
```

Four filters, four indexes: tags on `post_tags_by_tag`, servers on `posts_by_source`, authors on
`posts_by_author_time`, keywords on `posts_fts`. The spine is in the middle, and nothing joined to it today
is anything but what a network handed over.

Trending is two more reads, neither of which touches the network:

```text
   server said    posts ⋈ server_trends  WHERE last_seen_at > ?  ORDER BY rank
                  server_trends_recent; a row that stops being seen drops off

   counted here   tag_buckets  WHERE tag = ? AND bucket_at >= ?
                  tag_buckets_by_tag; this window's posts and authors summed against the last
```

## Still open

One thing in `schema.sql` is marked `<undecided>` and is not settled:

| open                  | the question                                                      |
| --------------------- | ------------------------------------------------------------------ |
| `posts_fts` tokenizer | `unicode61` makes an unbroken run of Han characters one token, so `台北` finds nothing in `今天在台北喝咖啡` |
