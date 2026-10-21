import Foundation

/// #334: what a real Mastodon answers when a post is pinned, its conversation quieted, it is
/// asked to be translated, and who boosted and favourited it is asked — written down from the
/// one this checkout brings up (`make servers`, Mastodon 4.6.6, API 11), 2026-10-21, and held
/// against it on every run that has the servers (`MastodonPostActsSaysTests`).
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | the document's `configuration` | `accounts.max_pinned_statuses: 5`; `translation: {"enabled": false}`; `instance/translation_languages` is `200 {}` |
/// | a post read by its author, signed in | `"pinned": false` and `"muted": false` beside the other marks |
/// | the same post read by somebody else, signed in | **no `pinned` at all**; `"muted": false` |
/// | the same post read unsigned | neither word |
/// | `POST …/pin` on an own post | `200`, the status with `"pinned": true` |
/// | `POST …/pin` again | **`422 {"error":"Duplicate record"}`** — a pin already there is a refusal, not the post |
/// | `POST …/pin` with five pinned already | **`422 {"error":"Validation failed: You have already pinned the maximum number of posts"}`**, and the post stays unpinned — the same status as a pin already there |
/// | any of these refusals, asked naming no language — as this app's door asks | **in the signed-in account's own language**: `ownFan`, set to `zh-TW`, is told `校驗失敗：釘選嘟文的數量已達上限`. Only `Duplicate record` is never translated — so a refusal is told by the post read again, never by its words |
/// | `POST …/unpin`, twice | `200` both times, `"pinned": false` |
/// | `POST …/pin` on somebody else's post | `422 {"error":"Validation failed: Someone else's post cannot be pinned"}` |
/// | `POST …/pin` on an own post only the people it mentions may read | `422 {"error":"Validation failed: Posts that are only visible to mentioned users cannot be pinned"}`; one for followers alone is pinned |
/// | `POST …/pin` on a boost | `422 … A boost cannot be pinned` (`MastodonPinnedSaysTests`) |
/// | `POST …/mute`, twice; `…/unmute`, twice | `200` each time, `"muted"` as asked — **on anybody's post**, and on a boost (answered with the boost) |
/// | `pin` or `mute` signed in without `write:accounts` / `write:mutes` | `403 {"error":"This action is outside the authorized scopes"}` — the account part and the blocks part, as they are |
/// | `pin`, `mute`, `translate` unsigned | `401 {"error":"The access token is invalid"}` |
/// | `POST …/translate`, translation off | **`404 {"error":"Not Found"}`** whoever asks — a sign-in that reads only included |
/// | `pin`, `mute`, `translate` of an id nobody has | `404 {"error":"Not Found"}` — **the same words as an address it does not serve** |
/// | `GET …/reblogged_by`, `…/favourited_by` | `200`, the accounts, to anyone and alike to a sign-in that reads only; a `Link` with only `rel="prev"` when it is all |
/// | the same with `limit=1` | one account, and `rel="next"` naming `max_id` — **the boost's id for boosts, the favourite's own number for favourites**, never the person's |
/// | either of an id nobody has | `404 {"error":"Not Found"}` |
enum MastodonPostActsCaptures {
    static let duplicate = #"{"error":"Duplicate record"}"#
    static let full = #"{"error":"Validation failed: You have already pinned the maximum number of posts"}"#
    /// The same, to a sign-in whose account is set to Chinese and an ask that names no language,
    /// as this app's door makes every ask.
    static let fullInChinese = #"{"error":"校驗失敗：釘選嘟文的數量已達上限"}"#
    static let notTheirs = #"{"error":"Validation failed: Someone else's post cannot be pinned"}"#
    static let mentionedOnly = #"{"error":"Validation failed: Posts that are only visible to mentioned users cannot be pinned"}"#
    static let outsideScopes = #"{"error":"This action is outside the authorized scopes"}"#
    static let notFound = #"{"error":"Not Found"}"#

    /// A translation as Mastodon's API documents it (4.6, `Translation`): no translator runs in the
    /// fixture (D7), so this one is the documentation's, not the server's.
    static let translation = #"""
    {"content":"<p>Hallo, Welt</p>","spoiler_text":"","language":"de","media_attachments":[],"poll":null,
     "detected_source_language":"en","provider":"DeepL.com"}
    """#

    /// The same, with a cover line spelled as a translator hands back markup: entities, a tag and
    /// a line break.
    static let coveredTranslation = #"""
    {"content":"<p>Hallo &amp; tschüss</p>","spoiler_text":"Spoiler: Tom &amp; Jerry &lt;3\n<b>&quot;Ende&quot;</b>",
     "detected_source_language":"en","provider":"DeepL.com"}
    """#
}
