import Foundation

/// The accounts of a Mastodon the reader answers for (#382), **as a real server sent them** — the
/// Mastodon 4.6.6 image `servers/compose.yml` pins, seeded by `servers/mastodon/seed.rb`: three
/// sign-ups waiting to be let in, each with what they wrote, and an account to act on. Fetched
/// on 2026-10-22 as the seed's Admin.
///
/// **Whole, not trimmed.** Each body is every byte the server sent, and each `Link` header as it
/// came. No real person is in here; the accounts, their addresses and their words are the seed's,
/// and the addresses they signed in from the server's own on this machine.
///
/// | Asked                                            | Answered                                         |
/// | ------------------------------------------------ | ------------------------------------------------ |
/// | `v2/admin/accounts?status=pending`               | 200, newest first, each with `invite_request`    |
/// | the same, `limit=1`                              | the newest, a next                               |
/// | `?status=active&username=…`                      | the one of that name                             |
/// | `v1/admin/accounts/:id/action`, `type=silence`   | `200 {}`; read again, `silenced` true            |
/// | `…/unsilence`                                    | 200, the account as it now stands                |
/// | an act of an unknown type                        | 422, the server's own sentence                   |
/// | `…/approve` of a sign-up                         | 200, `approved` true                             |
/// | `…/reject` of a sign-up                          | `200 {}`; the account is deleted                 |
/// | the list as an account without the standing      | `403 {"error":"This action is not allowed"}`     |
enum MastodonAdminAccountsCaptures {
    static let host = "mastodon.localhost"

    /// `GET /api/v2/admin/accounts?status=pending` as the Admin: the three seeded sign-ups, newest first.
    static let pending = #"""
    [{"id":"117482969876489169","username":"asks_382_away","domain":null,"created_at":"2026-10-22T05:44:15.753Z","email":"asks_382_away@example.com","ip":null,"confirmed":true,"suspended":false,"silenced":false,"sensitized":false,"disabled":false,"approved":false,"locale":null,"invite_request":"Buy cheap watches.","ips":[],"account":{"id":"117482969876489169","username":"asks_382_away","acct":"asks_382_away","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@asks_382_away","uri":"https://mastodon.localhost/ap/users/117482969876489169","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"role":{"id":"-99","name":"","permissions":"65536","color":"","highlighted":false,"collection_limit":10}},{"id":"117482969869627831","username":"asks_382_in","domain":null,"created_at":"2026-10-22T05:44:15.583Z","email":"asks_382_in@example.com","ip":null,"confirmed":true,"suspended":false,"silenced":false,"sensitized":false,"disabled":false,"approved":false,"locale":null,"invite_request":"Let me in, please.","ips":[],"account":{"id":"117482969869627831","username":"asks_382_in","acct":"asks_382_in","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@asks_382_in","uri":"https://mastodon.localhost/ap/users/117482969869627831","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"role":{"id":"-99","name":"","permissions":"65536","color":"","highlighted":false,"collection_limit":10}},{"id":"117482969852808890","username":"asks_382","domain":null,"created_at":"2026-10-22T05:44:15.384Z","email":"asks_382@example.com","ip":null,"confirmed":true,"suspended":false,"silenced":false,"sensitized":false,"disabled":false,"approved":false,"locale":null,"invite_request":"I read the rules and would like to write here.","ips":[],"account":{"id":"117482969852808890","username":"asks_382","acct":"asks_382","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@asks_382","uri":"https://mastodon.localhost/ap/users/117482969852808890","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"role":{"id":"-99","name":"","permissions":"65536","color":"","highlighted":false,"collection_limit":10}}]
    """#

    /// Its `Link` header.
    static let pendingLink = #"""
    <https://mastodon.localhost/api/v2/admin/accounts?min_id=117482969876489169&status=pending>; rel="prev"
    """#

    /// The same with `limit=1`: the newest, and a next.
    static let pendingOne = #"""
    [{"id":"117482969876489169","username":"asks_382_away","domain":null,"created_at":"2026-10-22T05:44:15.753Z","email":"asks_382_away@example.com","ip":null,"confirmed":true,"suspended":false,"silenced":false,"sensitized":false,"disabled":false,"approved":false,"locale":null,"invite_request":"Buy cheap watches.","ips":[],"account":{"id":"117482969876489169","username":"asks_382_away","acct":"asks_382_away","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@asks_382_away","uri":"https://mastodon.localhost/ap/users/117482969876489169","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"role":{"id":"-99","name":"","permissions":"65536","color":"","highlighted":false,"collection_limit":10}}]
    """#

    /// Its `Link` header.
    static let pendingOneLink = #"""
    <https://mastodon.localhost/api/v2/admin/accounts?limit=1&max_id=117482969876489169&status=pending>; rel="next", <https://mastodon.localhost/api/v2/admin/accounts?limit=1&min_id=117482969876489169&status=pending>; rel="prev"
    """#

    /// `?status=active&username=acted_382`: the one acted on, found by name.
    static let byName = #"""
    [{"id":"117482969882048354","username":"acted_382","domain":null,"created_at":"2026-10-22T05:44:15.852Z","email":"acted_382@example.com","ip":null,"confirmed":true,"suspended":false,"silenced":false,"sensitized":false,"disabled":false,"approved":true,"locale":null,"invite_request":null,"ips":[],"account":{"id":"117482969882048354","username":"acted_382","acct":"acted_382","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@acted_382","uri":"https://mastodon.localhost/ap/users/117482969882048354","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"role":{"id":"-99","name":"","permissions":"65536","color":"","highlighted":false,"collection_limit":10}}]
    """#

    /// Its `Link` header.
    static let byNameLink = #"""
    <https://mastodon.localhost/api/v2/admin/accounts?min_id=117482969882048354&status=active&username=acted_382>; rel="prev"
    """#

    /// `GET /api/v1/admin/accounts/:id` of the one acted on.
    static let actedOn = #"""
    {"id":"117482969882048354","username":"acted_382","domain":null,"created_at":"2026-10-22T05:44:15.852Z","email":"acted_382@example.com","ip":null,"confirmed":true,"suspended":false,"silenced":false,"sensitized":false,"disabled":false,"approved":true,"locale":null,"invite_request":null,"ips":[],"account":{"id":"117482969882048354","username":"acted_382","acct":"acted_382","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@acted_382","uri":"https://mastodon.localhost/ap/users/117482969882048354","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"role":{"id":"-99","name":"","permissions":"65536","color":"","highlighted":false,"collection_limit":10}}
    """#

    /// `POST …/:id/action` with `type=silence`: answered with nothing.
    static let silence = #"""
    {}
    """#

    /// The account read again after it: `silenced` true.
    static let silenced = #"""
    {"id":"117482969882048354","username":"acted_382","domain":null,"created_at":"2026-10-22T05:44:15.852Z","email":"acted_382@example.com","ip":null,"confirmed":true,"suspended":false,"silenced":true,"sensitized":false,"disabled":false,"approved":true,"locale":null,"invite_request":null,"ips":[],"account":{"id":"117482969882048354","username":"acted_382","acct":"acted_382","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@acted_382","uri":"https://mastodon.localhost/ap/users/117482969882048354","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"limited":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"role":{"id":"-99","name":"","permissions":"65536","color":"","highlighted":false,"collection_limit":10}}
    """#

    /// `POST …/:id/unsilence`: the account as it now stands.
    static let unsilence = #"""
    {"id":"117482969882048354","username":"acted_382","domain":null,"created_at":"2026-10-22T05:44:15.852Z","email":"acted_382@example.com","ip":null,"confirmed":true,"suspended":false,"silenced":false,"sensitized":false,"disabled":false,"approved":true,"locale":null,"invite_request":null,"ips":[],"account":{"id":"117482969882048354","username":"acted_382","acct":"acted_382","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@acted_382","uri":"https://mastodon.localhost/ap/users/117482969882048354","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"role":{"id":"-99","name":"","permissions":"65536","color":"","highlighted":false,"collection_limit":10}}
    """#

    /// An act of a type the server does not know: 422, in its words.
    static let badType = #"""
    {"error":"Validation failed: Type is not included in the list"}
    """#

    /// `POST …/:id/approve` of a sign-up: the account, approved.
    static let approve = #"""
    {"id":"117482969869627831","username":"asks_382_in","domain":null,"created_at":"2026-10-22T05:44:15.583Z","email":"asks_382_in@example.com","ip":null,"confirmed":true,"suspended":false,"silenced":false,"sensitized":false,"disabled":false,"approved":true,"locale":null,"invite_request":"Let me in, please.","ips":[],"account":{"id":"117482969869627831","username":"asks_382_in","acct":"asks_382_in","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-22T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@asks_382_in","uri":"https://mastodon.localhost/ap/users/117482969869627831","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":0,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]},"role":{"id":"-99","name":"","permissions":"65536","color":"","highlighted":false,"collection_limit":10}}
    """#

    /// `POST …/:id/reject` of a sign-up: answered with nothing; the account is gone.
    static let reject = #"""
    {}
    """#

    /// The list as the writer, holding tending's words and no standing: 403.
    static let writerList = #"""
    {"error":"This action is not allowed"}
    """#
}
