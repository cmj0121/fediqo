-- Fediqo — the local store, migration 010. Appended after 001–009; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only, nothing backfilled.
--
-- ── posts_fts — what counts as a word ────────────────────────────────────────
--
-- 001 left the tokenizer undecided, which meant FTS5's default, which is `unicode61`. That
-- splits on Unicode word boundaries, and 繁體中文 is written without them: a sentence of it
-- becomes one enormous token, and a reader searching this app in their own language finds
-- nothing at all. Measured, on two posts and every stock tokenizer:
--
--     unicode61   伺服器=0  公開=0  貼文=0  emoji=1  server=1
--     porter      伺服器=0  公開=0  貼文=0  emoji=1  server=1
--     trigram     伺服器=1  公開=0  貼文=0  emoji=1  server=1
--     words       伺服器=1  公開=1  貼文=1  emoji=1  server=1
--
-- `porter` is `unicode61` with English stemming and inherits the hole. `trigram` indexes every
-- three-character window, which reaches three-character Chinese and no shorter — and most
-- Chinese words are two characters, which is what that row is saying.
--
-- `words` is ours: everything that is not CJK goes to `unicode61`, and CJK is cut per
-- character. A query is cut by the same tokenizer, so `公開` is `公` `開` on both sides and
-- matches as the phrase it is. It lives in `Sources/FediqoCore/Store/Words.swift`, and what it
-- costs is written there — a connection that has not registered it cannot write a post, so it
-- is registered on every connection this app opens.
--
-- This is the rebuild the second line of schema.sql left room for: **only posts_fts may be
-- rebuilt**. Nothing else here is dropped. The triggers go and come back because they belong to
-- the table being rebuilt, and the index is repopulated from `posts` so that a store which has
-- been collecting since 001 is searchable without being emptied.

DROP TRIGGER posts_fts_insert;
DROP TRIGGER posts_fts_delete;
DROP TRIGGER posts_fts_update;
DROP TABLE posts_fts;

CREATE VIRTUAL TABLE posts_fts USING fts5(
    text,
    content='posts',
    content_rowid='id',
    tokenize = 'words'
);

CREATE TRIGGER posts_fts_insert AFTER INSERT ON posts BEGIN
    INSERT INTO posts_fts(rowid, text) VALUES (new.id, new.text);
END;

CREATE TRIGGER posts_fts_delete AFTER DELETE ON posts BEGIN
    INSERT INTO posts_fts(posts_fts, rowid, text) VALUES ('delete', old.id, old.text);
END;

CREATE TRIGGER posts_fts_update AFTER UPDATE OF text ON posts BEGIN
    INSERT INTO posts_fts(posts_fts, rowid, text) VALUES ('delete', old.id, old.text);
    INSERT INTO posts_fts(rowid, text) VALUES (new.id, new.text);
END;

-- Everything already here, indexed the new way. `rebuild` is FTS5's own word for it and reads
-- the content table, which is `posts` — so nothing is written twice and nothing is guessed.
INSERT INTO posts_fts(posts_fts) VALUES ('rebuild');
