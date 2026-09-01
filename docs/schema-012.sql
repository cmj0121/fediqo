-- Fediqo — the local store, migration 012. Appended after 001–011; the rules there still hold:
-- STRICT, every *_at in INTEGER milliseconds, append-only, nothing backfilled.
--
-- ── notices — what somebody aimed at you ─────────────────────────────────────
--
-- #9 asks for notifications that reach a reader without a Fediqo server in the middle, and the
-- first thing that needs is somewhere to put them. They are kept rather than held in memory for
-- the same reason posts are: what you keep stays here, and a notification a relaunch forgets is
-- one the reader has to go and find on somebody else's website.
--
-- `notice` is not `notification`. Half of Apple's frameworks own that word, and a table named
-- for it would read as the operating system's rather than as the server's. What is written down
-- here is what a server told us somebody did.
--
-- ── the kinds ────────────────────────────────────────────────────────────────
--
-- A lookup table, like `protocols`, `visibilities`, `media_kinds` and `filter_kinds` before it,
-- for the same reason: a kind this build has never heard of must fail at the write rather than
-- reach a screen that cannot draw it. Mastodon sends more kinds than these — `admin.sign_up`,
-- `admin.report`, `follow_request`, `severed_relationships` — and a client that is not a
-- moderator has nothing to say about any of them, so they are dropped where they are decoded
-- and never written. Adding one is a row here and a case in `NoticeKind`, never a column.
--
-- `mention` covers a reply as well, and that is Mastodon's doing rather than a simplification:
-- a reply to you *is* a mention of you, and the API sends one kind for both. #9's "replies and
-- mentions arrive" is therefore one row here, not two.

CREATE TABLE notice_kinds (
    kind       TEXT    NOT NULL PRIMARY KEY,
    label      TEXT    NOT NULL,                        -- for a log; a screen says it in the reader's language
    created_at INTEGER NOT NULL
) STRICT;

INSERT INTO notice_kinds (kind, label, created_at) VALUES
    ('mention',   'Mention',   0),
    ('favourite', 'Favourite', 0),
    ('boost',     'Boost',     0),
    ('follow',    'Follow',    0),
    ('poll',      'Poll',      0),
    ('update',    'Update',    0);

-- ── the notices themselves ───────────────────────────────────────────────────
--
-- One row per thing one server said happened. Not merged, and that is the difference between
-- this table and `posts`: two servers carrying one post is one row there because it is one
-- post, but two servers telling you about it is two events — each is a separate thing that
-- happened on a separate machine, and collapsing them would lose which account was mentioned.
--
-- `owner_id` is the account it happened to; a reader signed in to three servers has three
-- inboxes and they are not one. `actor_id` is who did it. Both are accounts, and neither is
-- ever the same column.
--
-- `post_key` is nullable because a follow is not about a post. It is a real foreign key and not
-- a loose address — unlike `posts.in_reply_to_uri`, which cannot be one because replies arrive
-- before their parents — because the status rides along inside the notification payload, so the
-- post is written in the same transaction, an instant before the row that points at it.
--
-- Three times, and they are three different questions:
--
--   noticed_at   when the server says it happened. What the list is ordered by.
--   arrived_at   when this device learned of it. Live and polled arrivals differ here and
--                nowhere else, which is what lets a screen say how late it was.
--   seen_at      when the reader looked. Local, ours, and never sent anywhere.

CREATE TABLE notices (
    id         INTEGER NOT NULL PRIMARY KEY,
    server_url TEXT    NOT NULL REFERENCES servers(url),
    remote_id  TEXT    NOT NULL,                        -- the server's own id for this event
    kind       TEXT    NOT NULL REFERENCES notice_kinds(kind),
    owner_id   TEXT    NOT NULL REFERENCES owned_accounts(author_id),  -- whose inbox
    actor_id   TEXT    NOT NULL REFERENCES accounts(author_id),        -- who did it
    post_key   TEXT             REFERENCES posts(merge_key),           -- NULL for a follow
    noticed_at INTEGER NOT NULL,
    arrived_at INTEGER NOT NULL,
    seen_at    INTEGER,                                 -- local; NULL = not looked at yet
    created_at INTEGER NOT NULL
) STRICT;

-- One event, once. A live arrival and the catch-up read that follows a relaunch will both
-- carry it, and the second one must be a no-op rather than a second row: `remote_id` is only
-- unique on the server that issued it, so the pair is what identifies the event.
CREATE UNIQUE INDEX notices_once ON notices(server_url, remote_id);

-- The list, newest first.
CREATE INDEX notices_by_time ON notices(noticed_at DESC);

-- What the bell counts. Partial, because the question is only ever asked of the unseen ones
-- and they are the few: a store that has been collecting for a year answers this by reading
-- the handful that are still unread rather than the year.
CREATE INDEX notices_unseen ON notices(owner_id) WHERE seen_at IS NULL;

-- Where the last catch-up got to, per inbox. A reconnect asks for what happened after this
-- rather than for the newest page, so a phone that was in a pocket for an hour comes back with
-- the hour rather than with the last twenty and a hole where the rest was.
CREATE TABLE notice_marks (
    server_url TEXT    NOT NULL,
    owner_id   TEXT    NOT NULL REFERENCES owned_accounts(author_id),
    remote_id  TEXT    NOT NULL,                        -- the newest event this device has seen arrive
    read_at    INTEGER NOT NULL,                        -- when that catch-up ran
    created_at INTEGER NOT NULL,
    updated_at INTEGER,
    PRIMARY KEY (server_url, owner_id)
) STRICT;

-- ── the feed ─────────────────────────────────────────────────────────────────
--
-- A mention's status is a post like any other and goes through the one path every post goes
-- through, so it needs a feed to have arrived through — `post_origins` keeps a source for every
-- one of them and there is no such thing as a post that arrived from nowhere.
--
-- It is not a thread of time: a notification list is the events aimed at you, and a stretch of
-- it missing a post is not evidence that the post has gone. It needs an account, because an
-- inbox belongs to somebody. It is not ranked, because it is in time order like everything else
-- this app draws.
INSERT INTO feeds (feed, label, ranked, needs_account, created_at) VALUES ('notice', 'Notices', 0, 1, 0);
