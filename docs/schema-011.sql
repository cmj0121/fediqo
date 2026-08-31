-- Fediqo — the local store, migration 011. Appended after 001–010; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only, nothing backfilled.
--
-- ── publications — what one composed post became, and where ──────────────────
--
-- Everywhere else in this app, two servers' copies of one post are collapsed by inference: they
-- agree on a canonical address, and `merge_key` is that agreement. It is a good inference and it
-- is still an inference.
--
-- This is the one place there is knowledge instead. A post the reader wrote and sent to three
-- accounts is three posts on three servers with three addresses that agree about nothing — and
-- this app knows they are one, because it sent them. #8 says so in its own body: *"Publishing is
-- also the only moment anything here knows for certain that two posts are the same post. What
-- the composer writes down at that moment is what #5 later matches on; everything else is a
-- guess."* This table is that writing down.
--
-- `composition` is the composed post: one value, made when the reader presses send, shared by
-- every destination it went to. It is not a foreign key to anything, because the thing it names
-- has no existence outside this table — a draft is not a row until it has been somewhere.
--
-- **Only what happened is written.** A destination that refused has no post on it, no address to
-- record and nothing to collapse; it is reported to the reader at the time, which is when it can
-- be acted on, and it leaves no row here. A record of a thing that did not happen would be a
-- record of the reader's failures, which this app does not keep.
--
-- `merge_key` is `ON DELETE SET NULL` rather than CASCADE, and the difference matters. A post
-- purged from `posts` is gone from this device; that it was published, and where, is not a fact
-- about the row that was purged. The row here stays and stops pointing at anything.

CREATE TABLE publications (
    composition TEXT    NOT NULL,                                   -- one composed post
    author_id   TEXT    NOT NULL REFERENCES accounts(author_id),    -- which of yours sent it
    server_url  TEXT    NOT NULL REFERENCES servers(url),           -- and to where
    merge_key   TEXT             REFERENCES posts(merge_key) ON DELETE SET NULL,
    uri         TEXT    NOT NULL,                                   -- its address on that server
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (composition, author_id)
) STRICT;

-- The way #5 asks it: given a post, what else is the same post. And the way a row asks it:
-- given a post, everywhere it went.
CREATE INDEX publications_by_post ON publications(merge_key);
