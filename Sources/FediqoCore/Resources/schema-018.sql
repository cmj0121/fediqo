-- Fediqo — the local store, migration 018. Appended after 001–017; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only, nothing backfilled.
--
-- ── a timeline made of hashtags ───────────────────────────────────────────────
--
-- A timeline was one base source with the reader's rules over it, and a hashtag was one of those
-- rules: the public timeline, sieved. On a quiet server that looks like it works. On a busy one
-- the public timeline is thousands of posts a minute, the sieve catches almost nothing, and the
-- reader is left thinking the tag is quiet.
--
-- Filtering is not subscribing. `/api/v1/timelines/tag/:tag` is the question that was never
-- asked, and asking it makes a timeline a base *and* a set of tags, merged by timestamp the way
-- posts from different servers have always been merged.
--
-- ── `tag` is a feed, because a post can arrive by one ─────────────────────────
--
-- The row is what lets `post_origins` say a post came in by a hashtag, the way 014 added
-- `author`. Not ranked: a hashtag timeline is a stretch of time like any other. Not an owner's:
-- anybody may ask a server about a tag.
--
-- It is not a stretch that can be evidence a post has gone, and there is no column for that here
-- — `isThreadOfTime` says so in Swift, where the reason lives. A tag page leaves out every post
-- that never carried the tag, which is almost all of them.
INSERT INTO feeds (feed, label, ranked, needs_account, created_at) VALUES ('tag', 'Hashtag', 0, 0, 0);

-- ── the tags a timeline subscribes to ─────────────────────────────────────────
--
-- Rows rather than a column, for the reason `timeline_filters` is rows: there are none, one, or
-- several, and the reader adds and removes them afterwards. Ordered by rowid, so the order a
-- reader added them in is the order they read back in.
--
-- The tag is stored the one way this store keeps a tag — NFC, lowercased, no `#` — so `#Swift`,
-- `#swift` and `＃swift` are one subscription and one question. The primary key is what makes
-- that true rather than hoped for: the same tag twice on one timeline cannot be written down.
CREATE TABLE timeline_tags (
    timeline_id TEXT NOT NULL REFERENCES timelines(id) ON DELETE CASCADE,
    tag         TEXT NOT NULL,
    PRIMARY KEY (timeline_id, tag)
) STRICT;
