-- Fediqo — the local store, migration 009. Appended after 001–008; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only, nothing backfilled.
--
-- ── visibilities — who a post was written for ────────────────────────────────
--
-- A post is not simply published. Its author chose who it was for, and until now this app
-- carried that choice past the reader without ever showing it: a followers-only post and a
-- public one drew the same row, which is the app quietly flattening a decision somebody made
-- on purpose.
--
-- A lookup table and not a bare column, for the reason `media_kinds` and `filter_kinds` are
-- ones: the set is closed, the schema is the contract, and a foreign key is how a closed set
-- says so. A server inventing a fifth word is refused here rather than stored and puzzled over
-- later.
--
-- The four are ActivityPub's, and the keys are the words the wire uses so that nothing has to
-- be translated on the way in or out. What they mean to a reader is the label, which is the
-- only part a screen shows:
--
--     public    on the public timelines, and anybody may find it
--     unlisted  anybody may read it, and it is on no public timeline
--     private   the author's followers, and nobody else
--     direct    the accounts it names, and nobody else
--
-- NULL is never told, and it is not `public`. Most of what this app reads comes from servers
-- answering a stranger, a protocol that has no such idea at all may hand posts over tomorrow,
-- and every post stored before this migration has no answer here — so absence means nobody
-- said, exactly as `sensitive` has meant since 005. A screen may draw nothing for it; it may
-- not draw a globe, because "public" is a claim about somebody's post that nobody made.

CREATE TABLE visibilities (
    visibility TEXT    NOT NULL PRIMARY KEY,        -- the word the wire uses
    label      TEXT    NOT NULL,                    -- what it means, in the source language
    created_at INTEGER NOT NULL,
    updated_at INTEGER
) STRICT;

INSERT INTO visibilities (visibility, label, created_at) VALUES
    ('public',   'Public',          0),
    ('unlisted', 'Unlisted',        0),
    ('private',  'Followers only',  0),
    ('direct',   'Mentioned only',  0);

ALTER TABLE posts ADD COLUMN visibility TEXT REFERENCES visibilities(visibility);  -- NULL = never told
