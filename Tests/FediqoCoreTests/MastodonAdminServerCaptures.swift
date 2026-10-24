import Foundation

/// What a Mastodon tells those who answer for it of its rules, of what waits to rise on it and
/// of how it is doing (#384), **as a real server sent them** — the Mastodon 4.6.6 image
/// `servers/compose.yml` pins, seeded by `servers/mastodon/seed.rb`: two rules; a hashtag, a
/// link and a post rising, and one of each waiting to be reviewed. Fetched on 2026-10-22 as the
/// seed's Admin, each review taken back after by seeding again.
///
/// **Whole, not trimmed.** Each body is every byte the server sent.
///
/// | Asked                                    | Answered                                           |
/// | ---------------------------------------- | -------------------------------------------------- |
/// | `instance/rules`                         | 200, the rules in their order                      |
/// | `admin/trends/{tags,links,statuses}`     | 200, each with whether it waits for review         |
/// | `…/:id/approve`, `…/:id/reject`          | 200, the one reviewed                              |
/// | `admin/measures`                         | 200, each key's total and the span's before it     |
/// | `admin/measures`, by a role without it   | `403 {"error":"This action is not allowed"}`       |
/// | `…/tags/:id/approve`, of no such hashtag | `404 {"error":"Record not found"}`                 |
enum MastodonAdminServerCaptures {
    static let host = "mastodon.localhost"

    /// `GET /api/v1/instance/rules`, asked by nobody: the two seeded, in their order.
    static let rules = #"""
    [{"id":"1","text":"fediqo381seed rule","hint":"","translations":{}},{"id":"2","text":"fediqo384seed second rule","hint":"fediqo384seed hint","translations":{}}]
    """#

    /// `GET /api/v1/admin/trends/tags` as the Admin: the hashtag rising, and the one waiting.
    static let tags = #"""
    [{"id":"1","name":"FediqoRising","url":"https://mastodon.localhost/tags/fediqorising","history":[{"day":"1792627200","accounts":"12","uses":"12"},{"day":"1792540800","accounts":"3","uses":"3"},{"day":"1792454400","accounts":"0","uses":"0"},{"day":"1792368000","accounts":"0","uses":"0"},{"day":"1792281600","accounts":"0","uses":"0"},{"day":"1792195200","accounts":"0","uses":"0"},{"day":"1792108800","accounts":"0","uses":"0"}],"following":false,"featuring":false,"trendable":true,"usable":true,"requires_review":true,"listable":true},{"id":"23","name":"FediqoWaiting","url":"https://mastodon.localhost/tags/fediqowaiting","history":[{"day":"1792627200","accounts":"0","uses":"0"},{"day":"1792540800","accounts":"0","uses":"0"},{"day":"1792454400","accounts":"0","uses":"0"},{"day":"1792368000","accounts":"0","uses":"0"},{"day":"1792281600","accounts":"0","uses":"0"},{"day":"1792195200","accounts":"0","uses":"0"},{"day":"1792108800","accounts":"0","uses":"0"}],"following":false,"featuring":false,"trendable":false,"usable":true,"requires_review":true,"listable":true}]
    """#

    /// `GET /api/v1/admin/trends/links`: the link rising, and the one waiting. Ids are numbers.
    static let links = #"""
    [{"url":"https://elsewhere.example/stories/rising","title":"A story <b>rising</b> & more","description":"What the page says of itself.","language":"en","type":"link","author_name":"Somebody","author_url":"https://elsewhere.example/somebody","provider_name":"Elsewhere","provider_url":"https://elsewhere.example","html":"","width":0,"height":0,"image":null,"image_description":"","embed_url":"","blurhash":null,"published_at":null,"missing_attribution":false,"history":[{"day":"1792627200","accounts":"20","uses":"20"},{"day":"1792540800","accounts":"0","uses":"0"},{"day":"1792454400","accounts":"0","uses":"0"},{"day":"1792368000","accounts":"0","uses":"0"},{"day":"1792281600","accounts":"0","uses":"0"},{"day":"1792195200","accounts":"0","uses":"0"},{"day":"1792108800","accounts":"0","uses":"0"}],"id":1,"requires_review":false,"authors":[{"name":"Somebody","url":"https://elsewhere.example/somebody","account":null}]},{"url":"https://waiting.example/stories/waiting","title":"fediqo384seed a story waiting","description":"Waiting to be reviewed.","language":"en","type":"link","author_name":"","author_url":"","provider_name":"Waiting","provider_url":"https://waiting.example","html":"","width":0,"height":0,"image":null,"image_description":"","embed_url":"","blurhash":null,"published_at":null,"missing_attribution":false,"history":[{"day":"1792627200","accounts":"0","uses":"0"},{"day":"1792540800","accounts":"0","uses":"0"},{"day":"1792454400","accounts":"0","uses":"0"},{"day":"1792368000","accounts":"0","uses":"0"},{"day":"1792281600","accounts":"0","uses":"0"},{"day":"1792195200","accounts":"0","uses":"0"},{"day":"1792108800","accounts":"0","uses":"0"}],"id":2,"requires_review":true,"authors":[]}]
    """#

    /// `GET /api/v1/admin/trends/statuses`: the post rising, and the one waiting.
    static let posts = #"""
    [{"id":"117481809148068973","created_at":"2026-10-22T00:49:04.471Z","in_reply_to_id":null,"in_reply_to_account_id":null,"sensitive":false,"spoiler_text":"","visibility":"public","language":"en","uri":"https://mastodon.localhost/ap/users/117481809137177554/statuses/117481809148068973","url":"https://mastodon.localhost/@fediqo_other/117481809148068973","replies_count":0,"reblogs_count":0,"favourites_count":0,"quotes_count":0,"edited_at":"2026-10-22T00:49:04.499Z","favourited":false,"reblogged":false,"muted":false,"bookmarked":false,"content":"<p>fediqo298seed edited</p>","requires_review":true,"filtered":[],"reblog":null,"application":null,"account":{"id":"117481809137177554","username":"fediqo_other","acct":"fediqo_other","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_other","uri":"https://mastodon.localhost/ap/users/117481809137177554","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":2,"following_count":0,"statuses_count":75,"last_status_at":"2026-10-22","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"media_attachments":[],"mentions":[],"tags":[],"emojis":[],"tagged_collections":[],"quote":null,"card":null,"poll":null,"quote_approval":{"automatic":[],"manual":[],"current_user":"denied"}},{"id":"117483578385512583","created_at":"2026-10-22T08:19:00.899Z","in_reply_to_id":null,"in_reply_to_account_id":null,"sensitive":false,"spoiler_text":"","visibility":"unlisted","language":"en","uri":"https://mastodon.localhost/ap/users/117483578375135430/statuses/117483578385512583","url":"https://mastodon.localhost/@rising_384/117483578385512583","replies_count":0,"reblogs_count":0,"favourites_count":0,"quotes_count":0,"edited_at":null,"favourited":false,"reblogged":false,"muted":false,"bookmarked":false,"content":"<p>fediqo384seed a post waiting</p>","requires_review":true,"filtered":[],"reblog":null,"application":null,"account":{"id":"117483578375135430","username":"rising_384","acct":"rising_384","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@rising_384","uri":"https://mastodon.localhost/ap/users/117483578375135430","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":1,"last_status_at":"2026-10-22","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"media_attachments":[],"mentions":[],"tags":[],"emojis":[],"tagged_collections":[],"quote":null,"card":null,"poll":null,"quote_approval":{"automatic":[],"manual":[],"current_user":"denied"}}]
    """#

    /// `POST /api/v1/admin/measures`, three keys over seven days ending the day after the last.
    static let measures = #"""
    [{"key":"new_users","unit":null,"total":"51","previous_total":"0","data":[{"date":"2026-10-16","value":"0"},{"date":"2026-10-17","value":"0"},{"date":"2026-10-18","value":"0"},{"date":"2026-10-19","value":"0"},{"date":"2026-10-20","value":"0"},{"date":"2026-10-21","value":"0"},{"date":"2026-10-22","value":"51"},{"date":"2026-10-23","value":"0"}]},{"key":"active_users","unit":null,"total":"49","previous_total":"0","data":[{"date":"2026-10-16T00:00:00Z","value":"0"},{"date":"2026-10-17T00:00:00Z","value":"0"},{"date":"2026-10-18T00:00:00Z","value":"0"},{"date":"2026-10-19T00:00:00Z","value":"0"},{"date":"2026-10-20T00:00:00Z","value":"0"},{"date":"2026-10-21T00:00:00Z","value":"0"},{"date":"2026-10-22T00:00:00Z","value":"49"},{"date":"2026-10-23T00:00:00Z","value":"0"}]},{"key":"opened_reports","unit":null,"total":"2","previous_total":"0","data":[{"date":"2026-10-16","value":"0"},{"date":"2026-10-17","value":"0"},{"date":"2026-10-18","value":"0"},{"date":"2026-10-19","value":"0"},{"date":"2026-10-20","value":"0"},{"date":"2026-10-21","value":"0"},{"date":"2026-10-22","value":"2"},{"date":"2026-10-23","value":"0"}]}]
    """#

    /// The same, asked by somebody whose role does not answer for it: 403.
    static let writerMeasures = #"""
    {"error":"This action is not allowed"}
    """#

    /// `POST …/trends/tags/:id/reject`: the hashtag, reviewed and not to rise.
    static let tagRejected = #"""
    {"id":"23","name":"FediqoWaiting","url":"https://mastodon.localhost/tags/fediqowaiting","history":[{"day":"1792627200","accounts":"0","uses":"0"},{"day":"1792540800","accounts":"0","uses":"0"},{"day":"1792454400","accounts":"0","uses":"0"},{"day":"1792368000","accounts":"0","uses":"0"},{"day":"1792281600","accounts":"0","uses":"0"},{"day":"1792195200","accounts":"0","uses":"0"},{"day":"1792108800","accounts":"0","uses":"0"}],"following":false,"featuring":false,"trendable":false,"usable":true,"requires_review":false,"listable":true}
    """#

    /// `POST …/trends/tags/:id/approve`.
    static let tagApproved = #"""
    {"id":"23","name":"FediqoWaiting","url":"https://mastodon.localhost/tags/fediqowaiting","history":[{"day":"1792627200","accounts":"0","uses":"0"},{"day":"1792540800","accounts":"0","uses":"0"},{"day":"1792454400","accounts":"0","uses":"0"},{"day":"1792368000","accounts":"0","uses":"0"},{"day":"1792281600","accounts":"0","uses":"0"},{"day":"1792195200","accounts":"0","uses":"0"},{"day":"1792108800","accounts":"0","uses":"0"}],"following":false,"featuring":false,"trendable":true,"usable":true,"requires_review":false,"listable":true}
    """#

    /// `POST …/trends/links/:id/reject`: reviewed — and it says no more.
    static let linkRejected = #"""
    {"url":"https://waiting.example/stories/waiting","title":"fediqo384seed a story waiting","description":"Waiting to be reviewed.","language":"en","type":"link","author_name":"","author_url":"","provider_name":"Waiting","provider_url":"https://waiting.example","html":"","width":0,"height":0,"image":null,"image_description":"","embed_url":"","blurhash":null,"published_at":null,"missing_attribution":false,"history":[{"day":"1792627200","accounts":"0","uses":"0"},{"day":"1792540800","accounts":"0","uses":"0"},{"day":"1792454400","accounts":"0","uses":"0"},{"day":"1792368000","accounts":"0","uses":"0"},{"day":"1792281600","accounts":"0","uses":"0"},{"day":"1792195200","accounts":"0","uses":"0"},{"day":"1792108800","accounts":"0","uses":"0"}],"id":2,"requires_review":false,"authors":[]}
    """#

    /// `POST …/trends/links/:id/approve`.
    static let linkApproved = #"""
    {"url":"https://waiting.example/stories/waiting","title":"fediqo384seed a story waiting","description":"Waiting to be reviewed.","language":"en","type":"link","author_name":"","author_url":"","provider_name":"Waiting","provider_url":"https://waiting.example","html":"","width":0,"height":0,"image":null,"image_description":"","embed_url":"","blurhash":null,"published_at":null,"missing_attribution":false,"history":[{"day":"1792627200","accounts":"0","uses":"0"},{"day":"1792540800","accounts":"0","uses":"0"},{"day":"1792454400","accounts":"0","uses":"0"},{"day":"1792368000","accounts":"0","uses":"0"},{"day":"1792281600","accounts":"0","uses":"0"},{"day":"1792195200","accounts":"0","uses":"0"},{"day":"1792108800","accounts":"0","uses":"0"}],"id":2,"requires_review":false,"authors":[]}
    """#

    /// `POST …/trends/statuses/:id/reject`.
    static let postRejected = #"""
    {"id":"117483578385512583","created_at":"2026-10-22T08:19:00.899Z","in_reply_to_id":null,"in_reply_to_account_id":null,"sensitive":false,"spoiler_text":"","visibility":"unlisted","language":"en","uri":"https://mastodon.localhost/ap/users/117483578375135430/statuses/117483578385512583","url":"https://mastodon.localhost/@rising_384/117483578385512583","replies_count":0,"reblogs_count":0,"favourites_count":0,"quotes_count":0,"edited_at":null,"favourited":false,"reblogged":false,"muted":false,"bookmarked":false,"content":"<p>fediqo384seed a post waiting</p>","requires_review":false,"filtered":[],"reblog":null,"application":null,"account":{"id":"117483578375135430","username":"rising_384","acct":"rising_384","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@rising_384","uri":"https://mastodon.localhost/ap/users/117483578375135430","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":1,"last_status_at":"2026-10-22","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"media_attachments":[],"mentions":[],"tags":[],"emojis":[],"tagged_collections":[],"quote":null,"card":null,"poll":null,"quote_approval":{"automatic":[],"manual":[],"current_user":"denied"}}
    """#

    /// `POST …/trends/statuses/:id/approve`.
    static let postApproved = #"""
    {"id":"117483578385512583","created_at":"2026-10-22T08:19:00.899Z","in_reply_to_id":null,"in_reply_to_account_id":null,"sensitive":false,"spoiler_text":"","visibility":"unlisted","language":"en","uri":"https://mastodon.localhost/ap/users/117483578375135430/statuses/117483578385512583","url":"https://mastodon.localhost/@rising_384/117483578385512583","replies_count":0,"reblogs_count":0,"favourites_count":0,"quotes_count":0,"edited_at":null,"favourited":false,"reblogged":false,"muted":false,"bookmarked":false,"content":"<p>fediqo384seed a post waiting</p>","requires_review":false,"filtered":[],"reblog":null,"application":null,"account":{"id":"117483578375135430","username":"rising_384","acct":"rising_384","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@rising_384","uri":"https://mastodon.localhost/ap/users/117483578375135430","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":1,"last_status_at":"2026-10-22","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"media_attachments":[],"mentions":[],"tags":[],"emojis":[],"tagged_collections":[],"quote":null,"card":null,"poll":null,"quote_approval":{"automatic":[],"manual":[],"current_user":"denied"}}
    """#

    /// A hashtag the server has not: 404.
    static let noTag = #"""
    {"error":"Record not found"}
    """#
}
