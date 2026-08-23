-- Fediqo — the local store. Baseline schema; migration 001 must match it exactly.
-- Append-only after this: CREATE, ADD COLUMN, CREATE INDEX. Only posts_fts may be rebuilt.
--
-- The reasoning lives in data-store.md. In short:
--   * every *_at is INTEGER milliseconds; every table has created_at / updated_at and is STRICT
--   * a set that may grow is a lookup table, not a CHECK
--   * servers are keyed by normalised endpoint URL (https://…, wss://…), not hostname
--   * writes go protocols -> servers -> accounts -> posts -> tags -> post_tags
--   * PRAGMA foreign_keys = ON
--   * a column added later is never backfilled, so posts keeps every network field now;
--     a table added later costs nothing, so everything else waits until it is needed
--   * a post the remote deletes is marked with deleted_at, never rewritten; purging a marked
--     row is the one DELETE the store performs, and only by policy (routine or size)
--   * <undecided>: the FTS tokenizer
--
-- ── relations — one arrow per FOREIGN KEY, pointing at the referenced table ────
--
--    ┌───────────┐
--    │ protocols │
--    └─────▲─────┘
--          │ proto
--          ├───────────────────────┬───────────────────┐
--    ┌─────┴─────┐ server_url ┌────┴─────┐             │
--    │  servers  │◄───────────┤ accounts │             │ proto
--    └─────▲─────┘            └────▲─────┘             │
--          │ authority_url         │ author_id         │
--          │ source_url            │ boosted_by        │
--          │                  ┌────┴────┐              │
--          └──────────────────┤  posts  ├──────────────┘
--                             └────▲────┘
--                                  │ merge_key
--                            ┌─────┴─────┐  tag  ┌──────┐
--                            │ post_tags ├──────►│ tags │
--                            └───────────┘       └──────┘
--
--    not FKs    posts.in_reply_to_uri ──► posts.uri, matched at read time
--               posts_fts.rowid = posts.id, kept in step by the triggers
--
--    filters    tags → post_tags_by_tag   servers → posts_by_source
--               authors → posts_by_author_time   keywords → posts_fts
--
--    later      notifications, identities / account_aliases, merge hints and
--               resolutions, post_divergences: each a new table hung off the spine

-- ── network — what a server handed over ─────────────────────────────────────

CREATE TABLE protocols (
    proto      TEXT    NOT NULL PRIMARY KEY,
    label      TEXT    NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER
) STRICT;

CREATE TABLE servers (
    url         TEXT    NOT NULL PRIMARY KEY,               -- normalised endpoint
    host        TEXT    NOT NULL,                           -- bare hostname, for grouping
    proto       TEXT    NOT NULL REFERENCES protocols(proto),
    title       TEXT,
    selected_at INTEGER,                                    -- local; NULL = not chosen
    position    INTEGER,                                    -- local; rail order
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER
) STRICT;
CREATE INDEX servers_by_host  ON servers(host);
CREATE INDEX servers_selected ON servers(position) WHERE selected_at IS NOT NULL;

CREATE TABLE accounts (
    author_id    TEXT    NOT NULL PRIMARY KEY,              -- actor URI | did:… | npub…
    proto        TEXT    NOT NULL REFERENCES protocols(proto),
    server_url   TEXT             REFERENCES servers(url),  -- NULL for Nostr
    handle       TEXT,                                      -- NULL until a profile arrives
    display_name TEXT,
    avatar_url   TEXT,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER
) STRICT;
CREATE INDEX accounts_by_server ON accounts(server_url);

-- id is a rowid alias for posts_fts only; everything else keys on merge_key.
CREATE TABLE posts (
    id              INTEGER NOT NULL PRIMARY KEY,
    merge_key       TEXT    NOT NULL UNIQUE,                -- see "merge" below
    proto           TEXT    NOT NULL REFERENCES protocols(proto),
    origin_uri      TEXT,                                   -- canonical id; NULL if none
    uri             TEXT    NOT NULL,                       -- the address we were handed
    authority_url   TEXT             REFERENCES servers(url),   -- from origin_uri; NULL for Nostr
    source_url      TEXT    NOT NULL REFERENCES servers(url),   -- first to hand it over; never updated
    posted_at       INTEGER NOT NULL,
    author_id       TEXT    NOT NULL REFERENCES accounts(author_id),
    text            TEXT    NOT NULL DEFAULT '',
    media_urls      TEXT,                                   -- JSON array
    web_url         TEXT,
    in_reply_to_uri TEXT,                                   -- parent's uri; not a FK, replies arrive first
    boosted_by      TEXT             REFERENCES accounts(author_id),
    extras          TEXT,                                   -- JSON object; timeline never reads it
    deleted_at      INTEGER,                                -- remote deleted it; purge by policy
    last_seen_at    INTEGER NOT NULL,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER,                                -- an authority edited it
    CHECK (media_urls IS NULL OR json_type(media_urls) = 'array'),
    CHECK (extras     IS NULL OR json_type(extras)     = 'object')
) STRICT;
CREATE INDEX posts_by_time        ON posts(posted_at DESC, merge_key);
CREATE INDEX posts_by_origin      ON posts(origin_uri) WHERE origin_uri IS NOT NULL;
CREATE INDEX posts_by_uri         ON posts(uri);
CREATE INDEX posts_by_author_time ON posts(author_id, posted_at);
CREATE INDEX posts_by_web_url     ON posts(web_url) WHERE web_url IS NOT NULL;
CREATE INDEX posts_by_source      ON posts(source_url);
CREATE INDEX posts_by_reply       ON posts(in_reply_to_uri) WHERE in_reply_to_uri IS NOT NULL;
CREATE INDEX posts_deleted        ON posts(deleted_at) WHERE deleted_at IS NOT NULL;

CREATE TABLE tags (
    tag         TEXT    NOT NULL PRIMARY KEY,               -- NFC, lowercased, no '#'
    display     TEXT    NOT NULL,                           -- a representative casing
    followed_at INTEGER,                                    -- local
    muted_at    INTEGER,                                    -- local
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER
) STRICT;
CREATE INDEX tags_followed ON tags(followed_at) WHERE followed_at IS NOT NULL;
CREATE INDEX tags_muted    ON tags(muted_at)    WHERE muted_at    IS NOT NULL;

CREATE TABLE post_tags (
    merge_key  TEXT    NOT NULL REFERENCES posts(merge_key) ON DELETE CASCADE,
    tag        TEXT    NOT NULL REFERENCES tags(tag),
    created_at INTEGER NOT NULL,
    updated_at INTEGER,
    PRIMARY KEY (merge_key, tag)
) STRICT;
CREATE INDEX post_tags_by_tag ON post_tags(tag);

-- ── derived — droppable ─────────────────────────────────────────────────────

-- External content on posts.id, which VACUUM cannot renumber.
CREATE VIRTUAL TABLE posts_fts USING fts5(
    text,
    content='posts',
    content_rowid='id'
--  tokenize = '...'                                        -- <undecided>
);

CREATE TRIGGER posts_fts_insert AFTER INSERT ON posts BEGIN
    INSERT INTO posts_fts(rowid, text) VALUES (new.id, new.text);
END;

CREATE TRIGGER posts_fts_delete AFTER DELETE ON posts BEGIN
    INSERT INTO posts_fts(posts_fts, rowid, text) VALUES ('delete', old.id, old.text);
END;

CREATE TRIGGER posts_fts_update AFTER UPDATE OF text ON posts BEGIN
    INSERT INTO posts_fts(posts_fts, rowid, text) VALUES ('delete', old.id, old.text);
    INSERT INTO posts_fts(rowid, text) VALUES (new.id, new.text);
END;

-- ── seed — migration 001 writes these, with its own run time as created_at ──

INSERT INTO protocols (proto, label, created_at) VALUES
    ('mastodon', 'Mastodon / ActivityPub', 0),
    ('atproto',  'AT Protocol',            0),
    ('nostr',    'Nostr',                  0);

-- ── merge — what counts as the same post; first match wins ──────────────────
--   1. boost:<booster author_id>|<origin_uri>
--   2. <origin_uri>, or <uri> when origin_uri is NULL
--
-- Identity only. Nothing is guessed from content, web_url or timing; a later policy is a
-- new table read at query time, and never a change to merge_key.
