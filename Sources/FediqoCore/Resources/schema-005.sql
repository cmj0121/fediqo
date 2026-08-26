-- Fediqo — the local store, migration 005. Appended after 001–004; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only.
--
-- What a post is, rather than what it says. 001 kept a post's words and threw away nearly
-- everything a status carries around them: an attachment came in as one URL with no idea what
-- kind of thing it was, a content warning was dropped on the floor, and so were the three
-- numbers under every post. This is the correction, and it is only a correction going forward.
--
-- ── the price, said out loud ─────────────────────────────────────────────────
--
-- 001's header: **a column added later is never backfilled.** Every post already in the store
-- came in before any of this existed, so it has no attachment kinds, no warning, and no counts,
-- and nothing here invents them. Two things soften it and neither is a fix. A post handed over
-- again by the server that is its authority is rewritten, so the top of the timeline fills in on
-- its own within a refresh or two; everything older stays as it is until something asks for it
-- by name. And the screens are written to say the narrower true thing — a still we can draw is
-- drawn, without claiming to know whether a film sits behind it.
--
-- ── post_media — what came attached ──────────────────────────────────────────
--
-- A table rather than columns, because there are several per post and they are ordered: the
-- order a source gave them is the order they are shown in, and `position` is that order rather
-- than an id, so a post re-read writes the same rows again instead of growing new ones.
--
-- `url` is the file itself and `preview_url` is a still to draw in its place. Both are nullable
-- and at least one must be there: a photo often has only the file, an audio clip often has no
-- still at all, and what 001 stored was `preview_url ?? url` with no way to tell which it had.
-- So a row that came from the old column arrives here as kind `unknown` with `preview_url` set
-- and `url` empty — which is exactly what is true of it.
--
-- `alt` is what the author wrote for somebody who cannot see it. It is kept because a screen
-- that stacks several attachments has to be able to say which is which out loud.
--
-- ── the warning, and the numbers ─────────────────────────────────────────────
--
-- `sensitive` and `spoiler_text` are two different things and are kept apart: the first says
-- the media should arrive covered, the second is a line of text standing in front of the words.
-- Both are NULL for a post nobody ever told us about, which is not the same as `0` and `''` —
-- "not told" and "told, and it is nothing" are different facts, and a screen may only hide what
-- it was actually told to hide.
--
-- The three counts are NULL for the same reason. **A count we do not have is never drawn as a
-- zero**: zero means nobody replied, and what we have is no idea.
--
-- ── thread — a fourth way a post arrives ────────────────────────────────────
--
-- Opening a post asks its authority for the conversation around it, and what comes back is
-- posts. They arrived through a read, so they are written down like any other arrival — which
-- means naming the source they came through, and none of the three existing ones is honest
-- about it. `thread` is that name. It is a row in `feeds` because 004 made a base source a row
-- for this exact reason; no template offers it, so nothing builds a timeline on it.

CREATE TABLE media_kinds (
    kind       TEXT    NOT NULL PRIMARY KEY,
    label      TEXT    NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER
) STRICT;

INSERT INTO media_kinds (kind, label, created_at) VALUES
    ('image',   'Image',   0),
    ('video',   'Video',   0),
    ('audio',   'Audio',   0),
    ('unknown', 'Unknown', 0);

CREATE TABLE post_media (
    merge_key   TEXT    NOT NULL REFERENCES posts(merge_key) ON DELETE CASCADE,
    position    INTEGER NOT NULL,                          -- the order the source gave them
    kind        TEXT    NOT NULL REFERENCES media_kinds(kind),
    url         TEXT,                                      -- the file itself
    preview_url TEXT,                                      -- a still to draw in its place
    alt         TEXT    NOT NULL DEFAULT '',               -- what the author wrote for it
    created_at  INTEGER NOT NULL,
    updated_at  INTEGER,
    PRIMARY KEY (merge_key, position),
    CHECK (url IS NOT NULL OR preview_url IS NOT NULL)
) STRICT;

ALTER TABLE posts ADD COLUMN sensitive        INTEGER;     -- 1/0; NULL = never told
ALTER TABLE posts ADD COLUMN spoiler_text     TEXT;        -- NULL = never told; '' = told, and empty
ALTER TABLE posts ADD COLUMN replies_count    INTEGER;     -- NULL = never told; never drawn as 0
ALTER TABLE posts ADD COLUMN reblogs_count    INTEGER;
ALTER TABLE posts ADD COLUMN favourites_count INTEGER;

-- created_at = 0 is the file's; the migration stamps it, the way 001 and 004 stamp theirs.
INSERT INTO feeds (feed, label, ranked, needs_account, created_at) VALUES ('thread', 'Thread', 0, 0, 0);
