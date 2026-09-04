-- Fediqo — the local store, migration 017. Appended after 001–016; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only, nothing backfilled.
--
-- ── which writers a public timeline is asked for ──────────────────────────────
--
-- `/api/v1/timelines/public` answers with everything a server sees: its own writers and
-- everything that reached it from elsewhere. Mastodon lets that be cut two ways, and both are
-- questions a person actually asks — the room itself, and everywhere but the room.
--
-- **Not a base source.** `feeds` gains no row and `post_origins` still records `public`, because
-- a post that arrived this way did arrive by the public timeline. What changes is which of them
-- the server was asked for, and that belongs to the timeline rather than to the post.
--
-- ── a lookup, like `feeds` and `filter_kinds` ─────────────────────────────────
--
-- The same arrangement those two have: the rows are the cases, a foreign key stops a timeline
-- naming one that does not exist, and a test holds the two lists identical so that adding a case
-- in Swift and forgetting the row here is caught here rather than by a reader.
CREATE TABLE writers (
    writers    TEXT NOT NULL PRIMARY KEY,
    label      TEXT NOT NULL,
    created_at INTEGER
) STRICT;

INSERT INTO writers (writers, label) VALUES
    ('everyone',  'everything the server sees'),
    ('here',      'only this server''s own writers'),
    ('elsewhere', 'everything except this server''s own writers');

-- Defaulted rather than backfilled, and they are the same thing here: every timeline written
-- down before this migration was asked for the whole public timeline, so `everyone` is what it
-- has always meant rather than a guess put in its place.
ALTER TABLE timelines ADD COLUMN writers TEXT NOT NULL DEFAULT 'everyone' REFERENCES writers(writers);
