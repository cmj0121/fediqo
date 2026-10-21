import Foundation

/// #330: what a real Mastodon answers when a post is written quoting another, when who may quote a
/// post is changed, when the quotes of one's own post are read and one is revoked — written down
/// from the one this checkout brings up (`make servers`, Mastodon 4.6.6, `api_versions.mastodon:
/// 11`), 2026-10-21, and held against it on every run that has the servers
/// (`MastodonQuoteWriteSaysTests`).
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | a post read, as its author or anybody signed in | `quote_approval: {"automatic":["public"],"manual":[],"current_user":"automatic"}`, `quotes_count` |
/// | the same, unsigned | `current_user: "denied"` — an unsigned reader may quote nothing |
/// | a post written with `quote_approval_policy` `public` / `followers` / `nobody` | `automatic` `["public"]` / `["followers"]` / `[]`; **`manual` is always `[]`**: this server asks nobody first |
/// | a policy of another word (`everyone`) | `422 {"error":"Record invalid"}` |
/// | a post written with `quoted_status_id` the reader may quote | the post, `quote: {"state":"accepted","quoted_status":{…}}`; the quoted post's `quotes_count` one more |
/// | the same where the reader may not (`current_user: "denied"`: a policy of nobody, of followers to somebody else, a post they cannot see) | **`404 {"error":"The post you are trying to quote does not appear to exist."}`** |
/// | a quote with a poll | **`500`**, a page of the server's own — refused here before it is sent |
/// | `PUT …/interaction_policy` `quote_approval_policy` | `200`, the post with its new `quote_approval`; quotes made already stay |
/// | a post only its followers may read | its policy is `[]` whatever it is set to: **nobody but its author may quote it**, and the author's quote of it is made `private` whatever was asked |
/// | a direct post written with a policy | `current_user: "denied"`, `automatic: []` |
/// | `GET …/quotes`, as its author, and as somebody signed in | the quoting posts, newest first, a stretch at a time by `rel="next"`'s `max_id` — **the quote's own id, not the post's**; unsigned `401` |
/// | `POST …/quotes/:quoting/revoke`, as the quoted post's author | `200`, the quoting post, `quote: {"state":"revoked","quoted_status":null}`; asked again, the same; the quoted post's `quotes_count` one less |
/// | the same, asked by anybody else | `403 {"error":"This action is not allowed"}` |
/// | any way to approve a waiting quote (`…/quotes/:q/approve`, `…/accept`, `…/quote/approve`) | **`404`, a page**: there is none — a quote that waits waits for the server, not for the reader |
enum MastodonQuoteWriteCaptures {
    static let notAllowed = #"{"error":"The post you are trying to quote does not appear to exist."}"#
    static let revoked = #"{"state":"revoked","quoted_status":null}"#
    static let notTheirs = #"{"error":"This action is not allowed"}"#
}
