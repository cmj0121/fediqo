-- Fediqo — the local store, migration 007. Appended after 001–006; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only, nothing backfilled.
--
-- What the reader has done about a post, which until now was nothing anybody could do. Three
-- kinds of fact arrive together and are kept apart, because they belong to three different
-- things.
--
-- ── post_marks — what one account did to one post ────────────────────────────
--
-- Keyed by (merge_key, author_id) and not by merge_key alone, for the reason `post_origins`
-- is: `posts` holds the merged row, one per post however many servers carried it, and
-- "favourited" is not a fact about the post. It is a fact about an account's relationship to
-- it, and a reader signed in to two servers can have favourited a post as one of them and not
-- as the other. A column on `posts` would have the second account overwrite the first's answer
-- every time either of them was read.
--
-- NULL is never-told, and is not `false`. Most of this app's reading is done as a stranger,
-- and a server answering a stranger says nothing about whether some account of yours
-- favourited the status — so the absence of a row, and a NULL inside one, both mean "nobody
-- has told us", exactly as `sensitive` does since 005. A screen may draw an unfilled star for
-- it; it may not say "not favourited", because it does not know that.
--
-- The instants are kept rather than booleans so that undoing is a fact with a time on it too:
-- a mark set and then cleared is the column going back to NULL, which is the same shape as
-- never having been told, and that is deliberate — once it is undone there is nothing more to
-- remember, and remembering that somebody unfavourited something is a reading record.

CREATE TABLE post_marks (
    merge_key      TEXT    NOT NULL REFERENCES posts(merge_key)   ON DELETE CASCADE,
    author_id      TEXT    NOT NULL REFERENCES accounts(author_id),  -- which of yours acted
    favourited_at  INTEGER,                                  -- NULL = never told, not "no"
    reblogged_at   INTEGER,
    bookmarked_at  INTEGER,
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER,
    PRIMARY KEY (merge_key, author_id)
) STRICT;
CREATE INDEX post_marks_favourited ON post_marks(author_id, favourited_at) WHERE favourited_at IS NOT NULL;
CREATE INDEX post_marks_reblogged  ON post_marks(author_id, reblogged_at)  WHERE reblogged_at  IS NOT NULL;
CREATE INDEX post_marks_bookmarked ON post_marks(author_id, bookmarked_at) WHERE bookmarked_at IS NOT NULL;

-- ── posts.kept_at — what this device keeps ───────────────────────────────────
--
-- A column and not a table, and not keyed by account, because it is neither an account's fact
-- nor a server's: it is this device's. Keeping a post is the reader telling their own machine
-- not to let go of it, and no server is told, which is the whole of what separates it from
-- `bookmarked_at` above.
--
-- What it is for is #7: a post with this set is exempt from rotation. Nothing here implements
-- rotation or a retention period — this migration only gives the answer somewhere to live.

ALTER TABLE posts ADD COLUMN kept_at INTEGER;               -- local; NULL = not kept
CREATE INDEX posts_kept ON posts(kept_at) WHERE kept_at IS NOT NULL;

-- ── mutes — the reader's own rules about who and where ───────────────────────
--
-- `tags.muted_at` has been the shape of a local rule since 001, but an author and a host have
-- no table of their own to grow a column on: `accounts` is everyone we have ever seen, most of
-- whom are nobody's decision, and `servers` is where posts came from rather than a list the
-- reader made. So one table, two kinds, and `value` says which thing is named.
--
-- `server_url` is what makes a server mute a separate row from a local one rather than a flag
-- on the same one. NULL is this device's own rule, told to nobody. A row with a server named
-- is a mute that server is carrying out on the reader's behalf, and the two are kept apart on
-- purpose: this app promises it can always say whether a rule of yours hid something or a
-- server did, and a single row with a flag on it cannot say that twice over.

CREATE TABLE mutes (
    kind       TEXT    NOT NULL CHECK (kind IN ('author', 'host')),
    value      TEXT    NOT NULL,                             -- actor URI, or a bare hostname
    server_url TEXT             REFERENCES servers(url),     -- NULL = this device's own rule
    muted_at   INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER
) STRICT;
CREATE UNIQUE INDEX mutes_locally ON mutes(kind, value) WHERE server_url IS NULL;
CREATE UNIQUE INDEX mutes_remotely ON mutes(kind, value, server_url) WHERE server_url IS NOT NULL;
CREATE INDEX mutes_by_kind ON mutes(kind, value);
