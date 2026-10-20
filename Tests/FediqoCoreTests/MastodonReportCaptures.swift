import Foundation

/// What a Mastodon says of a report, and of the rules it is made against (#339), **as a real
/// server sent it**: the Mastodon 4.6.6 image `servers/compose.yml` pins, the web process alone, as
/// `servers/mastodon/seed.rb` left it with two rules written beside it — brought up under a
/// compose project of its own and thrown away afterwards (`down -v`). Fetched with `curl`,
/// asking in English, on 2026-10-20, as the seed's writer with one sign-in for everything, and
/// as its sign-in that holds following and nothing of reports. No token and nobody real is in
/// here; the people reported are the seed's.
///
/// **Every constant here is every byte the server sent**: each body whole.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | the server's rules, with no sign-in | 200, each its `id`, its `text` and its `hint` as the server words them, and `translations` |
/// | a report of each category — `spam`, `legal`, `violation`, `other` | 200, the report: its `id`, `category`, `comment`, `forwarded`, `status_ids`, `rule_ids` and the account reported whole |
/// | `violation` with no rule, or a rule that is not the server's | 422 `Validation failed: Rule ids does not reference valid rules` |
/// | **`spam` with a rule** | 200, and **the report is filed as `violation`**: rules are sent only with that category |
/// | a category the server has not | 500, and no body |
/// | a post of somebody else's | 404 `Record not found`, nothing reported |
/// | words past 1,000 letters | 422 `Validation failed: Comment is too long (maximum is 1000 characters)` |
/// | `forward=true` of somebody of another server | 200, `forwarded` true |
/// | `forward=true` of somebody of this server | 200, `forwarded` false: there is nobody to tell |
/// | any of it by a sign-in without `write:reports` | 403, `WWW-Authenticate` naming `write write:reports` |
enum MastodonReportCaptures {
    static let host = "mastodon.localhost"
    /// The person reported, two posts of theirs, and somebody of another server with a post of theirs.
    static let person = "117472892050089377"
    static let posts = ["117472892052190312", "117472892052994253"]
    static let far = "117472892183483310"
    static let farPost = "117472892185542966"

    /// `GET /api/v1/instance/rules`, asked with no sign-in, of a server whose two rules the check wrote: one with a hint, one without.
    static let rules = #"[{"id":"1","text":"No spam, please.","hint":"Posts made only to sell or to be seen.","translations":{}},{"id":"2","text":"Be kind to one another","hint":"","translations":{}}]"#

    /// `POST /api/v1/reports` naming the person, two posts of theirs, a few words, `forward=false`, `category=violation` and the rule `1`.
    static let violation = #"{"id":"4","action_taken":false,"action_taken_at":null,"category":"violation","comment":"Selling things","forwarded":false,"created_at":"2026-10-20T12:08:52.258Z","status_ids":["117472892052994253","117472892052190312"],"rule_ids":["1"],"collection_ids":[],"target_account":{"id":"117472892050089377","username":"fediqo_person","acct":"fediqo_person","display_name":"Per :fediqo_mark: Son","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-20T00:00:00.000Z","note":"<p>Reads <a href=\"https://mastodon.localhost/tags/fediqo309\" class=\"mention hashtag\" rel=\"tag\">#<span>fediqo309</span></a> beside <span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo_other\" class=\"u-url mention\">@<span>fediqo_other</span></a></span> :fediqo_mark:<br /><a href=\"https://example.com/about\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/about</span><span class=\"invisible\"></span></a></p>","url":"https://mastodon.localhost/@fediqo_person","uri":"https://mastodon.localhost/ap/users/117472892050089377","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":8,"following_count":4,"statuses_count":9,"last_status_at":"2026-10-20","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[{"shortcode":"fediqo_mark","url":"https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/77ac74977a311a36.png","static_url":"https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/77ac74977a311a36.png","visible_in_picker":true}],"roles":[],"fields":[{"name":"Site","value":"<a href=\"https://example.com/per\" target=\"_blank\" rel=\"nofollow noopener me\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/per</span><span class=\"invisible\"></span></a>","verified_at":"2026-10-01T00:00:00.000+00:00"},{"name":"Pronouns :fediqo_mark:","value":"they/them","verified_at":null}]}}"#

    /// `POST /api/v1/reports` naming the person and `category=spam` alone: no posts, no words, `rule_ids` null.
    static let spam = #"{"id":"5","action_taken":false,"action_taken_at":null,"category":"spam","comment":"","forwarded":false,"created_at":"2026-10-20T12:08:52.404Z","status_ids":[],"rule_ids":null,"collection_ids":[],"target_account":{"id":"117472892050089377","username":"fediqo_person","acct":"fediqo_person","display_name":"Per :fediqo_mark: Son","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-20T00:00:00.000Z","note":"<p>Reads <a href=\"https://mastodon.localhost/tags/fediqo309\" class=\"mention hashtag\" rel=\"tag\">#<span>fediqo309</span></a> beside <span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo_other\" class=\"u-url mention\">@<span>fediqo_other</span></a></span> :fediqo_mark:<br /><a href=\"https://example.com/about\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/about</span><span class=\"invisible\"></span></a></p>","url":"https://mastodon.localhost/@fediqo_person","uri":"https://mastodon.localhost/ap/users/117472892050089377","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":8,"following_count":4,"statuses_count":9,"last_status_at":"2026-10-20","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[{"shortcode":"fediqo_mark","url":"https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/77ac74977a311a36.png","static_url":"https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/77ac74977a311a36.png","visible_in_picker":true}],"roles":[],"fields":[{"name":"Site","value":"<a href=\"https://example.com/per\" target=\"_blank\" rel=\"nofollow noopener me\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/per</span><span class=\"invisible\"></span></a>","verified_at":"2026-10-01T00:00:00.000+00:00"},{"name":"Pronouns :fediqo_mark:","value":"they/them","verified_at":null}]}}"#

    /// `POST /api/v1/reports` naming somebody of another server, one post of theirs, `forward=true` and `category=other`: `forwarded` true.
    static let forwarded = #"{"id":"6","action_taken":false,"action_taken_at":null,"category":"other","comment":"x","forwarded":true,"created_at":"2026-10-20T12:08:52.507Z","status_ids":["117472892185542966"],"rule_ids":null,"collection_ids":[],"target_account":{"id":"117472892183483310","username":"far","acct":"far@elsewhere.example","display_name":"Far :far_mark: Away","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-20T00:00:00.000Z","note":"<p>Lives elsewhere :far_mark:</p>","url":"https://elsewhere.example/@far","uri":"https://elsewhere.example/users/far","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":2811,"following_count":310,"statuses_count":1204,"last_status_at":"2026-10-20","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"feature_approval":{"automatic":[],"manual":[],"current_user":"missing"},"emojis":[{"shortcode":"far_mark","url":"https://mastodon.localhost/system/cache/custom_emojis/images/000/000/002/original/18f489a6e3c1f279.png","static_url":"https://mastodon.localhost/system/cache/custom_emojis/images/000/000/002/static/18f489a6e3c1f279.png","visible_in_picker":true}],"fields":[{"name":"Home","value":"<a href=\"https://elsewhere.example/far\" rel=\"nofollow noopener\" target=\"_blank\">elsewhere.example/far</a>","verified_at":null}]}}"#

    /// `POST /api/v1/reports` with `category=violation` and no rule: 422.
    static let noRule = #"{"error":"Validation failed: Rule ids does not reference valid rules"}"#

    /// `POST /api/v1/reports` naming a post of somebody else: 404, and nothing reported.
    static let notTheirs = #"{"error":"Record not found"}"#

    /// `POST /api/v1/reports` with 1,001 letters of words: 422.
    static let tooLong = #"{"error":"Validation failed: Comment is too long (maximum is 1000 characters)"}"#

    /// `POST /api/v1/reports` by a sign-in without `write:reports`: 403, and `WWW-Authenticate` naming what it needs.
    static let reportRefused = #"{"error":"This action is outside the authorized scopes"}"#
    static let reportRefusedAuthenticate = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _write write:reports_.""#
}
