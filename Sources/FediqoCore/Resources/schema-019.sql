-- Fediqo — the local store, migration 019. Appended after 001–018; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only, nothing backfilled.
--
-- ── finding what you already have ─────────────────────────────────────────────
--
-- `posts_fts` has been here since 010 and nothing opened it, so a reader who wanted the post
-- they remember reading had to scroll for it. A search is a reading like any other — the same
-- rows, the same ring, the same keys — and a reading is a base source, so `search` is one.
--
-- It is a feed because a post can arrive by one: a search put to a server writes what it answers
-- into the store, and those posts arrived by a search. Nothing arrives that way yet; the row is
-- what lets it, and what lets `post_origins` say so when it does.
--
-- Not ranked and not an owner's: the answer is newest first like everything here, and anybody
-- may search what their own device holds.
INSERT INTO feeds (feed, label, ranked, needs_account, created_at) VALUES ('search', 'Search', 0, 0, 0);

-- What a search is for, kept beside the timeline it belongs to. Empty for every reading that is
-- not one, which is every timeline written down before this migration.
ALTER TABLE timelines ADD COLUMN words TEXT NOT NULL DEFAULT '';
