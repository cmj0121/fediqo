-- Fediqo — the local store, migration 013. Appended after 001–012; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only, nothing backfilled.
--
-- ── post_cards — what a link says it is ──────────────────────────────────────
--
-- A post that is mostly an address should say what is at the other end of it. #77 asks for that,
-- and the whole of its design is where the answer comes from: **the server that handed the post
-- over, and never the link itself**.
--
-- Mastodon fetches the Open Graph tags on its own account and sends the result inside the status,
-- as `card`. Everything in this table came out of that payload, and the picture is served from
-- that instance's own media storage rather than from the site being linked to. So a card costs no
-- new host: every byte of it comes from a server the reader was already reading.
--
-- Fetching the tags ourselves would be the opposite, and it is the one thing this app must never
-- do. A request to the linked host tells that host — and whoever it sells to — that this device
-- read this post, from this address, at this time. `docs/privacy.md` says that never happens. A
-- server that sends no card gets no card drawn; there is no second way to get one.
--
-- ── one card, or none ────────────────────────────────────────────────────────
--
-- The primary key is the post, not a pair: a status carries at most one card, which is Mastodon's
-- own shape and the reason this is not `post_media`. A post with several links still has one card,
-- because the server picked one — and which one it picked is its business rather than ours to
-- second-guess.
--
-- Every column but the address and the times may be empty, and empty is what a server said
-- nothing about. A title nobody sent is not drawn as the URL, and a provider nobody sent is not
-- worked out from the host: a card that invents half of itself is a card a reader cannot trust
-- the other half of.

CREATE TABLE post_cards (
    merge_key  TEXT    NOT NULL PRIMARY KEY REFERENCES posts(merge_key) ON DELETE CASCADE,
    url        TEXT    NOT NULL,                    -- where it points, as the server gave it
    title      TEXT    NOT NULL DEFAULT '',
    summary    TEXT    NOT NULL DEFAULT '',         -- og:description, as far as the server read it
    provider   TEXT    NOT NULL DEFAULT '',         -- what the site calls itself
    image_url  TEXT,                                -- on the *server's* storage, not the site's
    image_alt  TEXT    NOT NULL DEFAULT '',         -- the server's own alt text, never ours
    created_at INTEGER NOT NULL,
    updated_at INTEGER
) STRICT;
