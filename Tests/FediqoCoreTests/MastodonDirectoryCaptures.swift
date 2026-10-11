import Foundation

/// A Mastodon's directory of people (#315), **as a real server sent it**: the Mastodon 4.6.6
/// image `servers/compose.yml` pins, the web process alone, as `servers/mastodon/seed.rb` left
/// it then — nobody listed — and, in the same window, once eighteen of the seeded accounts had
/// been marked from inside the server as choosing to be listed. Fetched with `curl` on
/// 2026-10-11 with no sign-in, with a sign-in that may do everything, with this app's reading
/// sign-in and with a token that is none; the directory was then switched off from inside the
/// server, asked again, and switched back. The server was thrown away afterwards. (The seed has
/// since been taught to list a few people itself, so the server it leaves no longer answers
/// with nobody.)
///
/// **Whole, not trimmed.** Each body is every byte the server sent. No token and nobody real
/// is in here: the accounts are the seed's.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | the directory (`/api/v1/directory`), nobody having chosen to be listed | `200 []`, to anyone |
/// | the same, people listed | 200, a list of accounts in the shape every account has — thirteen of the eighteen marked. Not given: one suspended, one limited, one that moved, and two for whom the server counts nothing at all (no post, no follow). People of another server it has heard of are in it beside its own |
/// | how it goes on | **no `Link` header, and nothing in the body**: only `offset` — how many people to pass over — and `limit`. `?limit=2`, then `&offset=2`, then `&offset=4` are three stretches of two, nobody twice. `max_id` is ignored. An offset past the end: `200 []`. An offset of less than none: **500** |
/// | how long a stretch is | forty unasked; `limit=80` and `limit=200` both give what there is (eighty at most, as its other lists). `limit=0` and a limit that is no number: `200 []` — **nobody, which is not the end**. So a length of at least one is always asked |
/// | `order` | `active` — whoever posted most lately first, people who never posted after them — is also what it gives unasked; `new` — whoever it met most lately first. **Any other word, and an empty one: 500**, a page of the server's own |
/// | `local` | `true` (and `1`, and any word but a plain no): only the people who live there. `false`, or not sent: everybody |
/// | signed in | the same list **without the people the reader blocks or mutes, and without whoever blocks them** — ten of the thirteen for the seed's writer. This app's reading sign-in is given the same; a token that is none is answered as nobody is, with all thirteen |
/// | how often | `cache-control: max-age=15, public`; it counts against the 300 asks in five minutes an address is given |
/// | switched off by whoever runs the server | **404 `{"error":"Not Found"}`** to anyone, whatever is asked of it — the not-found of a thing the server has no means for (`MastodonHostCaptures`), which is a word about the address |
///
/// So the directory is read with no sign-in, in one of two orders named by the server's own
/// words, a stretch of eighty at most at a time, on by how many were passed over — and an
/// empty stretch is its end, since a short one may be only as long as the server chose.
enum MastodonDirectoryCaptures {
    static let host = "mastodon.localhost"

    /// `GET /api/v1/directory?order=new&limit=2`: the two the server met last, who live on
    /// another server — one hiding its lists, one with a name partly a picture and a field.
    static let newestTwo = #"""
    [{"id":"117418762800029218","username":"far_hidden","acct":"far_hidden@elsewhere.example","display_name":"Far Hidden","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-10T00:00:00.000Z","note":"","url":"https://elsewhere.example/@far_hidden","uri":"https://elsewhere.example/users/far_hidden","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":77,"following_count":55,"statuses_count":33,"last_status_at":null,"hide_collections":true,"show_media":true,"show_media_replies":true,"show_featured":true,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"fields":[]},{"id":"117418762795393951","username":"far","acct":"far@elsewhere.example","display_name":"Far :far_mark: Away","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-10T00:00:00.000Z","note":"<p>Lives elsewhere :far_mark:</p>","url":"https://elsewhere.example/@far","uri":"https://elsewhere.example/users/far","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":2811,"following_count":310,"statuses_count":1204,"last_status_at":"2026-10-10","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[{"shortcode":"far_mark","url":"https://mastodon.localhost/system/cache/custom_emojis/images/000/000/002/original/dfd0504a3c1c4b03.png","static_url":"https://mastodon.localhost/system/cache/custom_emojis/images/000/000/002/static/dfd0504a3c1c4b03.png","visible_in_picker":true}],"fields":[{"name":"Home","value":"<a href=\"https://elsewhere.example/far\" rel=\"nofollow noopener\" target=\"_blank\">elsewhere.example/far</a>","verified_at":null}]}]
    """#

    /// `GET /api/v1/directory?order=new&limit=2&offset=2`: the two after them, who live there.
    static let afterTwo = #"""
    [{"id":"117418762791734813","username":"fediqo_blocker","acct":"fediqo_blocker","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-10T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_blocker","uri":"https://mastodon.localhost/ap/users/117418762791734813","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":1,"following_count":0,"statuses_count":1,"last_status_at":"2026-10-10","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},{"id":"117418762753246286","username":"fediqo_hidden","acct":"fediqo_hidden","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-10T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_hidden","uri":"https://mastodon.localhost/ap/users/117418762753246286","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":2,"following_count":1,"statuses_count":1,"last_status_at":"2026-10-10","hide_collections":true,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]}]
    """#

    /// `GET /api/v1/directory`, with nobody listed — and at an offset past the end.
    static let nobody = "[]"

    /// `GET /api/v1/directory`, switched off: 404 and this.
    static let switchedOff = #"{"error":"Not Found"}"#
}
