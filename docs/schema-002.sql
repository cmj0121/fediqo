-- Fediqo — the local store, migration 002. Appended after schema.sql, which 001 ran verbatim;
-- the rules there still hold: STRICT, every *_at in INTEGER milliseconds, append-only.
--
-- The fact that you signed in, and only the fact. Layer: local — a decision you made and can
-- withdraw. The credential never comes here: the token lives in the Keychain, keyed by
-- author_id. Signing out deletes the row; the account and every post it handed over stay.
--
-- No UNIQUE(server_url): one account per server is policy, enforced by SignInCoordinator, not schema.

CREATE TABLE owned_accounts (
    author_id  TEXT    NOT NULL PRIMARY KEY REFERENCES accounts(author_id),
    server_url TEXT    NOT NULL REFERENCES servers(url),
    created_at INTEGER NOT NULL,
    updated_at INTEGER
) STRICT;
CREATE INDEX owned_accounts_by_server ON owned_accounts(server_url);
