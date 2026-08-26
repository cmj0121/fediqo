-- Fediqo — the local store, migration 006. Appended after 001–005; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only.
--
-- What the post was written with. Mastodon calls it `application` and sends a name and, where
-- the author registered one, a website: "Ivory for iOS", "Elk", "the web interface". It is the
-- one thing on a post that is about the writing rather than the writer or the words, which is
-- why it belongs at the foot of a row rather than beside the handle.
--
-- Two columns rather than a table: there is at most one per post, and a lookup table keyed by
-- name would be a table of strings other people's servers made up, joined once per row to save
-- nothing. `application_url` is a website and not a reference; nothing here dereferences it.
--
-- It is NULL far more often than not, and that is the server's doing rather than ours:
-- Mastodon sends it for statuses written on the server being asked and leaves it out for
-- everything that reached that server by federation. So a timeline of many servers will have
-- it on some rows and not on others, and a row without it says nothing at all — never "posted
-- from an unknown app", which would be inventing a fact about somebody's client.

ALTER TABLE posts ADD COLUMN application     TEXT;   -- what it was written with; NULL = not told
ALTER TABLE posts ADD COLUMN application_url TEXT;   -- that client's own website, where it has one
