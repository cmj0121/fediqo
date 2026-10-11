import Foundation

/// A Mastodon asked, with no sign-in, for somebody by their name (#310) — the one ask this app
/// makes of the server a person lives on — **as a real server answered it**: the Mastodon
/// 4.6.6 image `servers/compose.yml` pins, the web process alone, as `servers/mastodon/seed.rb`
/// left it, and beside it the two forums of the same fixture asked at the same path. Fetched
/// with `curl` on 2026-10-11, no token sent. The servers were thrown away afterwards.
///
/// **Whole, not trimmed**, but for the forum's page, which is cut where its head begins to
/// list files. No token and nobody real is in here: the accounts are the seed's.
///
/// ## What was asked, and what was answered
///
/// | Asked, unsigned | Answered |
/// | --------------- | -------- |
/// | `/api/v1/accounts/lookup?acct=name`, somebody who lives there | 200, one account, `acct` the name alone. The same bytes for `name@thishost` and for the name in capitals: the answer spells the name as the account does, not as it was asked |
/// | somebody the server suspended | **200**, the account with `"suspended":true`, no name of their own, no words, no fields — and their counts still said |
/// | somebody the server limited | 200, whole, with `"limited":true` |
/// | somebody who moved | 200, with `moved`: the whole account they went to |
/// | somebody of another server it has heard of (`far@elsewhere.example`) | 200, `acct` with that server's name in it — so a server asked for its own person that answers with one of these is answering with somebody else |
/// | a name nobody has, a name of a server it never heard of, no name at all | **404** `{"error":"Record not found"}`, as JSON |
/// | the same server with `LIMITED_FEDERATION_MODE=true`, or `DISALLOW_UNAUTHENTICATED_API_ACCESS=true` | **401** `{"error":"This method requires an authenticated user"}`. **Not asked over the wire**: the fixture runs without either, so the 4.6.6 code was asked in its own container with the setting on, through its own routes. `AUTHORIZED_FETCH=true` changes nothing here: 200, the account |
/// | the path at a Discourse | **404**, `text/html`: its "Page Not Found" page, 11,715 bytes |
/// | the path at a Discuz! | **302** to the very address asked, with two cookies: a redirect that never ends |
/// | how often | `x-ratelimit-limit: 300`, `x-ratelimit-remaining: 299`, `x-ratelimit-reset` a moment within five minutes, written as a date; `cache-control: max-age=15, public`; `vary: Authorization, Origin` |
///
/// So a server that knows them answers 200 with their account whatever has become of it, a
/// Mastodon that does not answers 404 in JSON, one that keeps itself to its members answers
/// 401 — and a server that is no Mastodon answers 404 or sends the ask round in a ring, which
/// nothing but the body tells from a Mastodon's "nobody of that name".
enum MastodonPersonHomeCaptures {
    static let host = "mastodon.localhost"

    static let personName = "fediqo_person"
    static let goneName = "fediqo_gone"
    static let limitedName = "fediqo_limited"
    static let movedName = "fediqo_moved"
    /// Whom the one who moved went to.
    static let movedTo = "@fediqo_person@mastodon.localhost"
    static let farName = "far@elsewhere.example"

    static let person = #"{"id":"117419652340027827","username":"fediqo_person","acct":"fediqo_person","display_name":"Per :fediqo_mark: Son","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-11T00:00:00.000Z","note":"<p>Reads <a href=\"https://mastodon.localhost/tags/fediqo309\" class=\"mention hashtag\" rel=\"tag\">#<span>fediqo309</span></a> beside <span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo_other\" class=\"u-url mention\">@<span>fediqo_other</span></a></span> :fediqo_mark:<br /><a href=\"https://example.com/about\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/about</span><span class=\"invisible\"></span></a></p>","url":"https://mastodon.localhost/@fediqo_person","uri":"https://mastodon.localhost/ap/users/117419652340027827","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":8,"following_count":4,"statuses_count":9,"last_status_at":"2026-10-11","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"denied"},"emojis":[{"shortcode":"fediqo_mark","url":"https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/73f906052963e1d5.png","static_url":"https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/73f906052963e1d5.png","visible_in_picker":true}],"roles":[],"fields":[{"name":"Site","value":"<a href=\"https://example.com/per\" target=\"_blank\" rel=\"nofollow noopener me\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/per</span><span class=\"invisible\"></span></a>","verified_at":"2026-10-01T00:00:00.000+00:00"},{"name":"Pronouns :fediqo_mark:","value":"they/them","verified_at":null}]}"#

    static let gone = #"{"id":"117419652417870568","username":"fediqo_gone","acct":"fediqo_gone","display_name":"","locked":false,"bot":false,"discoverable":false,"indexable":false,"group":false,"created_at":"2026-10-11T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_gone","uri":"https://mastodon.localhost/ap/users/117419652417870568","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":1,"following_count":0,"statuses_count":1,"last_status_at":"2026-10-11","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"suspended":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]}"#

    static let limited = #"{"id":"117419652426967035","username":"fediqo_limited","acct":"fediqo_limited","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-11T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_limited","uri":"https://mastodon.localhost/ap/users/117419652426967035","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"limited":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]}"#

    static let moved = #"{"id":"117419652411103110","username":"fediqo_moved","acct":"fediqo_moved","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-11T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_moved","uri":"https://mastodon.localhost/ap/users/117419652411103110","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"moved":{"id":"117419652340027827","username":"fediqo_person","acct":"fediqo_person","display_name":"Per :fediqo_mark: Son","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-11T00:00:00.000Z","note":"<p>Reads <a href=\"https://mastodon.localhost/tags/fediqo309\" class=\"mention hashtag\" rel=\"tag\">#<span>fediqo309</span></a> beside <span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo_other\" class=\"u-url mention\">@<span>fediqo_other</span></a></span> :fediqo_mark:<br /><a href=\"https://example.com/about\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/about</span><span class=\"invisible\"></span></a></p>","url":"https://mastodon.localhost/@fediqo_person","uri":"https://mastodon.localhost/ap/users/117419652340027827","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":8,"following_count":4,"statuses_count":9,"last_status_at":"2026-10-11","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"denied"},"emojis":[{"shortcode":"fediqo_mark","url":"https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/73f906052963e1d5.png","static_url":"https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/73f906052963e1d5.png","visible_in_picker":true}],"roles":[],"fields":[{"name":"Site","value":"<a href=\"https://example.com/per\" target=\"_blank\" rel=\"nofollow noopener me\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/per</span><span class=\"invisible\"></span></a>","verified_at":"2026-10-01T00:00:00.000+00:00"},{"name":"Pronouns :fediqo_mark:","value":"they/them","verified_at":null}]},"emojis":[],"roles":[],"fields":[]}"#

    /// Somebody of another server, as this one answers for them by their whole handle.
    static let far = #"{"id":"117419652445135068","username":"far","acct":"far@elsewhere.example","display_name":"Far :far_mark: Away","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-11T00:00:00.000Z","note":"<p>Lives elsewhere :far_mark:</p>","url":"https://elsewhere.example/@far","uri":"https://elsewhere.example/users/far","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":2811,"following_count":310,"statuses_count":1204,"last_status_at":"2026-10-11","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[{"shortcode":"far_mark","url":"https://mastodon.localhost/system/cache/custom_emojis/images/000/000/002/original/21a5979a3ea6260c.png","static_url":"https://mastodon.localhost/system/cache/custom_emojis/images/000/000/002/static/21a5979a3ea6260c.png","visible_in_picker":true}],"fields":[{"name":"Home","value":"<a href=\"https://elsewhere.example/far\" rel=\"nofollow noopener\" target=\"_blank\">elsewhere.example/far</a>","verified_at":null}]}"#

    static let missing = #"{"error":"Record not found"}"#

    /// What a Mastodon that answers only its members says to an ask with no sign-in (401).
    static let membersOnly = #"{"error":"This method requires an authenticated user"}"#

    /// How a Discourse's answer at the path begins (404, `text/html; charset=utf-8`).
    static let forumPage = #"""
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Page Not Found - Discourse</title>
  <meta name="description" content="">
  <meta name="generator" content="Discourse 2026.8.0 - https://github.com/discourse/discourse version badad7b0456a628e578bc48b9f8c1259422b5d58">
"""#

    /// Where a Discuz! sends the ask (302): to itself.
    static let forumRedirect = "https://discuz.localhost/api/v1/accounts/lookup?acct=fediqo_person"

    /// What every answer of the Mastodon said of how often it may be asked.
    static let rate = ["x-ratelimit-limit": "300", "x-ratelimit-remaining": "299", "x-ratelimit-reset": "2026-10-11T01:25:00.818036Z"]
}
