-- Fediqo — the local store, migration 008. Appended after 001–007; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only, nothing backfilled.
--
-- ── post_emojis — the pictures a post is partly written in ───────────────────
--
-- A server hands over its custom emoji as a list beside the status: `:blobcat:` in the words,
-- and somewhere else the address of the picture that `:blobcat:` means. Without the second
-- half the reader is left reading the shortcode, which is the machine's spelling of a picture.
--
-- A table and not a column, for the reason `post_tags` is one: it is a list, and a list in a
-- column is a list nothing can join on. Ordered by rowid like the tags and the mentions, so
-- the order the source gave them is the order they come back in.
--
-- The status's own emoji and the author's are written into one list here, because a shortcode
-- means one picture on one server: `:blobcat:` in a display name and `:blobcat:` in the words
-- below it are the same picture, and two rows saying so would be the same fact twice. Where a
-- server contradicts itself, the first spelling wins and the second is ignored, which is what
-- the primary key does.
--
-- `static_url` is the still of an animated one, and it is what a reader who has asked for less
-- movement is given. Everybody else is given the moving one, frame by frame. Both are kept
-- because both are drawn, and which of the two a reader sees is never written down here.
--
-- Nothing is backfilled. A post stored before this migration has no rows here and draws its
-- shortcodes as the text they are, which is exactly what it did yesterday.

CREATE TABLE post_emojis (
    merge_key  TEXT    NOT NULL REFERENCES posts(merge_key) ON DELETE CASCADE,
    shortcode  TEXT    NOT NULL,                    -- without the colons, as the server spelt it
    url        TEXT    NOT NULL,                    -- the picture
    static_url TEXT,                                -- the still of it, where the server gave one
    created_at INTEGER NOT NULL,
    PRIMARY KEY (merge_key, shortcode)
) STRICT;
CREATE INDEX post_emojis_shortcode ON post_emojis(shortcode);
