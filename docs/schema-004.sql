-- Fediqo — the local store, migration 004. Appended after 001–003; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only.
--
-- One idea, six tables: **a post is one row, and stays one row.** Everything this device learns
-- about a post that is not the post itself is written beside it — which base source handed it
-- over and to whom, whether a server still has it on the list it calls trending, and who it
-- names. A timeline is then a question asked of that one copy. Nothing here ever copies a post
-- into a timeline, and nothing here rewrites a post to say which timelines it is in.
--
-- ── what a base source is, and why it is a row ────────────────────────────────
--
-- `public`, `home` and `trend` are three different things to ask a server for, and the second
-- one cannot be asked at all without a credential. They are rows in `feeds` rather than cases
-- in an enum because the set will grow — a server's hashtag timeline and a server's lists are
-- both base sources waiting to happen — and 001's header already settled that argument: a set
-- that may grow is a lookup table, not a CHECK.
--
-- `feeds.ranked` is where the timeline's order lives, and it is here rather than on `timelines`
-- on purpose. #6 says every timeline is in timestamp order and nothing in the app can change
-- that; a server's trending list is the one thing handed over already ordered, and re-sorting
-- somebody else's ranking by time would throw the only thing it was carrying. So order is a
-- property of the base source — not of a rule, and not of the reader, neither of whom can
-- reach it.
--
-- ── post_origins — where a post came from, kept per account ───────────────────
--
-- Same shape as `server_trends`, because it is the same kind of fact: a server, a post, and
-- the two instants between which we kept being told. Seeing the same post arrive again from
-- somewhere else adds a row; it never replaces one.
--
-- `author_id` is whose home it arrived in. It is NULL for `public` and `trend`, and that is an
-- honest NULL — a public timeline belongs to nobody. It is recorded now rather than when a
-- second account appears, because 001's header is blunt about the cost of waiting: a column
-- added later is never backfilled, so every post already stored would be one that could not
-- say whose home it was in.
--
-- Uniqueness is two partial indexes rather than a PRIMARY KEY. SQLite does not enforce NOT NULL
-- on the columns of a rowid table's PRIMARY KEY, and NULLs are distinct to a unique index — so
-- a plain four-column key would have let every anonymous sighting insert a second row forever.
--
-- ── post_mentions — who a post names ─────────────────────────────────────────
--
-- No foreign key to `accounts`, for the reason `posts.in_reply_to_uri` has none: a post names
-- accounts we have never seen and may never see. The URI is the name; the handle is how the
-- post's own server spelled it, kept because it is what a reader would type.
--
-- ── server_trends.removed_at — falling off the list ──────────────────────────
--
-- 001 gave a trending row `last_seen_at` and let staleness stand in for leaving. It cannot:
-- `ServerBackoff` exists precisely to stop asking a server that is not answering, so "we have
-- not seen it for a day" covers a post that fell off the list and a server nobody has asked,
-- and those are not the same fact.
--
-- The mark says the narrower true thing, the way 003 made `deleted_at` say one: **the list this
-- server hands over no longer contains this post.** Not "it is not trending" — a list has a
-- length, and falling from 18th to 25th looks exactly like retiring. It is only ever written
-- from a list that actually arrived, so a server that was skipped, backed off or unreachable
-- marks nothing. A post that comes back rises again: the mark is cleared, not a second row.
--
-- ── timelines — the reader's own list ────────────────────────────────────────
--
-- A timeline is one base source and any number of filters. One base source: two would leave the
-- order undecided, since order comes from the base source.
--
-- `template` is provenance and never a live link. A template seeds a timeline when it is made
-- and has nothing to say to it afterwards, so that an app update cannot quietly rewrite a list
-- somebody named. The three that ship are seeded rows like any other — renameable, movable,
-- deletable, and makeable again from the same template.
--
-- ── relations — one arrow per FOREIGN KEY, pointing at the referenced table ───
--
--    ┌───────┐ feed  ┌──────────────┐ merge_key  ┌───────┐
--    │ feeds │◄──────┤ post_origins ├───────────►│ posts │◄──┐ merge_key
--    └───▲───┘       └──────┬───────┘            └───────┘   │
--        │ feed             │ source_url / author_id     ┌────┴──────────┐
--    ┌───┴───────┐          ▼                            │ post_mentions │
--    │ timelines │    servers / accounts                 └───────────────┘
--    └───▲───────┘
--        │ timeline_id   ┌──────────────┐  kind  ┌──────────────┐
--        └───────────────┤ timeline_    ├───────►│ filter_kinds │
--                        │ filters      │        └──────────────┘
--                        └──────────────┘
--
--    not a FK   post_mentions.mention_uri ──► accounts.author_id, matched at read time

-- ── the base sources ─────────────────────────────────────────────────────────

CREATE TABLE feeds (
    feed          TEXT    NOT NULL PRIMARY KEY,            -- 'public' | 'home' | 'trend'
    label         TEXT    NOT NULL,                        -- for a log; a screen says it in the reader's language
    ranked        INTEGER NOT NULL,                        -- 1 = the order the server handed over, 0 = timestamp
    needs_account INTEGER NOT NULL,                        -- 1 = unreadable without a signed-in account
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER
) STRICT;

-- created_at = 0 is the file's; the migration stamps it, the way 001 stamps protocols.
INSERT INTO feeds (feed, label, ranked, needs_account, created_at) VALUES
    ('public', 'Public',   0, 0, 0),
    ('home',   'Home',     0, 1, 0),
    ('trend',  'Trending', 1, 0, 0);

-- ── what a post remembers besides itself ─────────────────────────────────────

CREATE TABLE post_origins (
    source_url    TEXT    NOT NULL REFERENCES servers(url),
    feed          TEXT    NOT NULL REFERENCES feeds(feed),
    author_id     TEXT             REFERENCES accounts(author_id),   -- whose home; NULL for public and trend
    merge_key     TEXT    NOT NULL REFERENCES posts(merge_key) ON DELETE CASCADE,
    first_seen_at INTEGER NOT NULL,
    last_seen_at  INTEGER NOT NULL,
    created_at    INTEGER NOT NULL,
    updated_at    INTEGER
) STRICT;
CREATE UNIQUE INDEX post_origins_by_account ON post_origins(source_url, feed, author_id, merge_key)
    WHERE author_id IS NOT NULL;
CREATE UNIQUE INDEX post_origins_anonymous  ON post_origins(source_url, feed, merge_key)
    WHERE author_id IS NULL;
CREATE INDEX post_origins_by_post ON post_origins(merge_key);

CREATE TABLE post_mentions (
    merge_key   TEXT    NOT NULL REFERENCES posts(merge_key) ON DELETE CASCADE,
    mention_uri TEXT    NOT NULL,                          -- actor URI; not a FK, we may never see the account
    handle      TEXT    NOT NULL,                          -- @user@host, as the post's own server spelled it
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER,
    PRIMARY KEY (merge_key, mention_uri)
) STRICT;
CREATE INDEX post_mentions_by_uri ON post_mentions(mention_uri);

-- What is already here came in before there was anywhere to write this down, and 001's rule is
-- that a column added later is never backfilled — so these two statements are the exception,
-- and they are only defensible because the inference is exact rather than convenient. Until
-- now there was one timeline endpoint in the whole app, `/api/v1/timelines/public`, and one
-- other way for a post to arrive, a server's trending list. So every stored post came through
-- `public`, and `server_trends` already names, per server, every post that came through a
-- trending list.
--
-- A post that arrived only through a trending list still gets a `public` row here, knowingly.
-- Before this migration the store handed the whole of itself to the timeline, so that post was
-- on the reader's screen; leaving it out would take it off. The backfill's job is that nobody
-- opens this version to a shorter timeline than they closed the last one with.

INSERT INTO post_origins (source_url, feed, author_id, merge_key, first_seen_at, last_seen_at, created_at)
    SELECT source_url, 'public', NULL, merge_key, created_at, last_seen_at, created_at FROM posts;

INSERT INTO post_origins (source_url, feed, author_id, merge_key, first_seen_at, last_seen_at, created_at)
    SELECT source_url, 'trend', NULL, merge_key, first_seen_at, last_seen_at, created_at FROM server_trends;

ALTER TABLE server_trends ADD COLUMN removed_at INTEGER;    -- gone from the list this server hands over
CREATE INDEX server_trends_live ON server_trends(source_url, rank) WHERE removed_at IS NULL;

-- ── the reader's own timelines ───────────────────────────────────────────────

CREATE TABLE timelines (
    id          TEXT    NOT NULL PRIMARY KEY,              -- made up here; a rename never moves it
    name        TEXT    NOT NULL,
    summary     TEXT    NOT NULL,                          -- the line under the name; '' until written
    feed        TEXT    NOT NULL REFERENCES feeds(feed),
    author_id   TEXT             REFERENCES accounts(author_id),   -- whose home; NULL unless feed = 'home'
    template    TEXT    NOT NULL,                          -- what it was made from; provenance, not a link
    position    INTEGER NOT NULL,                          -- left to right
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER
) STRICT;
CREATE INDEX timelines_in_order ON timelines(position, id);

CREATE TABLE filter_kinds (
    kind       TEXT    NOT NULL PRIMARY KEY,
    label      TEXT    NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER
) STRICT;

INSERT INTO filter_kinds (kind, label, created_at) VALUES
    ('tag',     'Hashtag',   0),
    ('author',  'Author',    0),
    ('mention', 'Mentions',  0),
    ('server',  'Server',    0),
    ('media',   'Has media', 0);

CREATE TABLE timeline_filters (
    timeline_id TEXT    NOT NULL REFERENCES timelines(id) ON DELETE CASCADE,
    kind        TEXT    NOT NULL REFERENCES filter_kinds(kind),
    value       TEXT    NOT NULL,                          -- '' where the kind is the whole rule, as media is
    negate      INTEGER NOT NULL,                          -- 1 = remove what matches, 0 = keep only what matches
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER,
    PRIMARY KEY (timeline_id, kind, value)
) STRICT;
