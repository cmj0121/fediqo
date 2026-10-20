import Foundation

/// What a Mastodon says of muting and blocking people and whole servers (#314), **as a real server
/// sent it**: the Mastodon 4.6.6 image `servers/compose.yml` pins, the web process alone, as
/// `servers/mastodon/seed.rb` left it — brought up under a compose project of its own and thrown
/// away afterwards (`down -v`). Fetched with `curl`, asking in English, on 2026-10-20, as the
/// seed's writer with one sign-in for everything, and as its sign-in that sees and changes who
/// the writer follows and holds nothing of muting. No token and nobody real is in here.
///
/// **Every constant here is every byte the server sent**: each body whole, and the `Link` header
/// beside it where it sent one.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | a mute, for good or for a time, with or without notices | 200, the whole standing: `muting`, `muting_notifications` as sent, `muting_expires_at` for a time |
/// | the same mute again | 200, the same: **the length of a mute said again is kept** as first sent |
/// | an unmute, of somebody muted or not | 200, the standing with `muting` false |
/// | a block; an unblock | 200 each, the standing as it is afterwards |
/// | whom the reader mutes or blocks, a stretch at a time | 200, the accounts, newest first; `Link` names the next by **the number of the mute or the block**, never the account; a mute carries `mute_expires_at` |
/// | the stretch after the last | 200, `[]`, and no `Link` at all |
/// | to block a server; the same again; the reader's own server | 200 `{}` each — **the source blocks even its own server** |
/// | to block a name that is no host, or none | 422 `Validation failed: …` |
/// | the servers blocked, a stretch at a time | 200, the names, newest first; `Link` as for people; a stretch shorter than asked for names no next |
/// | to take a server's block back, named in the form or in the query; of a server not blocked | 200 `{}` each |
/// | how the reader stands to somebody of a server they block | `domain_blocking` true; nothing else changed |
/// | any of it by a sign-in without the word | 403 `This action is outside the authorized scopes`, `WWW-Authenticate` naming `follow write write:mutes` (or `write:blocks`, `read:mutes`, `read:blocks`) |
enum MastodonBlocksCaptures {
    static let host = "mastodon.localhost"
    /// The people muted and blocked, the one the seed muted, and the one who lives elsewhere.
    static let first = "117472892064426927"
    static let second = "117472892070441704"
    static let third = "117472892078141078"
    static let far = "117472892183483310"
    static let seeded = "117472892092895338"

    /// POST /api/v1/accounts/117472892064426927/mute with `notifications=true&duration=0`: muted for good, notices too.
    static let mutedForGood = #"{"id":"117472892064426927","following":false,"showing_reblogs":false,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":true,"muting_notifications":true,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// POST /api/v1/accounts/117472892078141078/mute with `notifications=false&duration=3600`: muted for an hour, notices let through.
    static let mutedForAnHour = #"{"id":"117472892078141078","following":false,"showing_reblogs":false,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":true,"muting_notifications":false,"muting_expires_at":"2026-10-20T12:28:50Z","requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// `GET /api/v1/mutes?limit=2`, with four people muted: the newest two, and a next by the number of the mute.
    static let mutesFirst = #"[{"id":"117472892078141078","username":"fediqo_fan_3","acct":"fediqo_fan_3","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-20T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_fan_3","uri":"https://mastodon.localhost/ap/users/117472892078141078","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":1,"following_count":1,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"mute_expires_at":"2026-10-20T12:28:50.515Z","emojis":[],"roles":[],"fields":[]},{"id":"117472892064426927","username":"fediqo_fan_1","acct":"fediqo_fan_1","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-20T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_fan_1","uri":"https://mastodon.localhost/ap/users/117472892064426927","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":1,"following_count":6,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"mute_expires_at":null,"emojis":[],"roles":[],"fields":[]}]"#
    static let mutesFirstLink = #"<https://mastodon.localhost/api/v1/mutes?limit=2&max_id=4>; rel="next", <https://mastodon.localhost/api/v1/mutes?limit=2&since_id=5>; rel="prev""#

    /// `GET /api/v1/mutes?limit=2&max_id=4`: the other two — one muted for an hour, and the one the seed muted — and a next that leads to nobody.
    static let mutesNext = #"[{"id":"117472892070441704","username":"fediqo_fan_2","acct":"fediqo_fan_2","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-20T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_fan_2","uri":"https://mastodon.localhost/ap/users/117472892070441704","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":1,"following_count":3,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"mute_expires_at":"2026-10-20T12:02:07.289Z","emojis":[],"roles":[],"fields":[]},{"id":"117472892092895338","username":"fediqo_fan_5","acct":"fediqo_fan_5","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-20T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_fan_5","uri":"https://mastodon.localhost/ap/users/117472892092895338","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":1,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"mute_expires_at":null,"emojis":[],"roles":[],"fields":[]}]"#
    static let mutesNextLink = #"<https://mastodon.localhost/api/v1/mutes?limit=2&max_id=1>; rel="next", <https://mastodon.localhost/api/v1/mutes?limit=2&since_id=3>; rel="prev""#

    /// POST /api/v1/accounts/117472892064426927/unmute.
    static let unmuted = #"{"id":"117472892064426927","following":false,"showing_reblogs":false,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// POST /api/v1/accounts/117472892078141078/block.
    static let blocked = #"{"id":"117472892078141078","following":false,"showing_reblogs":false,"notifying":false,"languages":null,"followed_by":false,"blocking":true,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// `GET /api/v1/blocks`, with two people blocked, one of them by the seed: no next.
    static let blocks = #"[{"id":"117472892078141078","username":"fediqo_fan_3","acct":"fediqo_fan_3","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-20T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_fan_3","uri":"https://mastodon.localhost/ap/users/117472892078141078","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":1,"following_count":1,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[],"roles":[],"fields":[]},{"id":"117472892083818108","username":"fediqo_fan_4","acct":"fediqo_fan_4","display_name":"","locked":false,"bot":false,"discoverable":true,"indexable":false,"group":false,"created_at":"2026-10-20T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_fan_4","uri":"https://mastodon.localhost/ap/users/117472892083818108","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":0,"following_count":1,"statuses_count":0,"last_status_at":null,"hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":["public"],"manual":[],"current_user":"automatic"},"emojis":[],"roles":[],"fields":[]}]"#
    static let blocksLink = #"<https://mastodon.localhost/api/v1/blocks?since_id=4>; rel="prev""#

    /// POST /api/v1/accounts/117472892078141078/unblock.
    static let unblocked = #"{"id":"117472892078141078","following":false,"showing_reblogs":false,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// POST /api/v1/domain_blocks with `domain=spam.example`; the same again answers the same.
    static let serverBlocked = #"{}"#

    /// `GET /api/v1/domain_blocks?limit=2`, with three servers blocked: the newest two, and a next.
    static let serversFirst = #"["spam.example","third.example"]"#
    static let serversFirstLink = #"<https://mastodon.localhost/api/v1/domain_blocks?limit=2&max_id=3>; rel="next", <https://mastodon.localhost/api/v1/domain_blocks?limit=2&since_id=5>; rel="prev""#

    /// `GET /api/v1/domain_blocks?limit=2&max_id=3`: the last, and no next.
    static let serversNext = #"["elsewhere.example"]"#
    static let serversNextLink = #"<https://mastodon.localhost/api/v1/domain_blocks?limit=2&since_id=1>; rel="prev""#

    /// `GET /api/v1/accounts/relationships?id[]=117472892183483310`, somebody on `elsewhere.example`, which is blocked.
    static let farStanding = #"[{"id":"117472892183483310","following":false,"showing_reblogs":false,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":true,"endorsed":false,"note":""}]"#

    /// DELETE /api/v1/domain_blocks with `domain=spam.example` as its form; of a server not blocked it answers the same.
    static let serverUnblocked = #"{}"#

    /// POST /api/v1/domain_blocks naming an address: 422.
    static let serverInvalid = #"{"error":"Validation failed: Domain is invalid, Domain is invalid"}"#

    /// A mute by a sign-in without `write:mutes`: 403, and `WWW-Authenticate` naming what it needs.
    static let muteRefused = #"{"error":"This action is outside the authorized scopes"}"#
    static let muteRefusedAuthenticate = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _follow write write:mutes_.""#

    /// `GET /api/v1/mutes` by a sign-in without `read:mutes`: 403.
    static let mutesRefused = #"{"error":"This action is outside the authorized scopes"}"#
    static let mutesRefusedAuthenticate = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _follow read read:mutes_.""#

    /// `GET /api/v1/domain_blocks` by a sign-in without `read:blocks`: 403.
    static let serversRefused = #"{"error":"This action is outside the authorized scopes"}"#
    static let serversRefusedAuthenticate = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _follow read read:blocks_.""#
}
