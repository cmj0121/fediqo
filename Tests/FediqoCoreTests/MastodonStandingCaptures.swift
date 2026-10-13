import Foundation

/// What a Mastodon says of how the reader stands to somebody, and of following them (#310,
/// #313), **as a real server sent it**: the Mastodon 4.6.6 image `servers/compose.yml` pins,
/// the web process alone, as `servers/mastodon/seed.rb` left it. Fetched with `curl`, asking
/// in English (`Accept-Language: en`), on 2026-10-13, with no sign-in and with three of the
/// writer's the seed makes: this app's reading words and `read:follows`; those and
/// `write:follows`; and one for everything. Nothing was registered. Whoever was followed was
/// unfollowed again, the request to the locked account was put back, the mute was made for
/// good again, and the server was thrown away afterwards. No token and nobody real is in here.
///
/// **Every constant here is every byte the server sent**: each body whole. The ids are those
/// of the sitting recorded. What the same server said of how the reader stands to seven people
/// at once is `MastodonPeopleCaptures.standing`, asked for #310; what it refuses a sign-in
/// that lacks a word is `MastodonSignInCaptures`, asked for #347. Neither is asked again here.
///
/// `MastodonStandingSaysTests` asks a server brought up again for every row of this table.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | how the reader stands to themselves (`relationships?id[]=` their own id) | 200, an entry like any other, every part `false` |
/// | to follow somebody (`POST /api/v1/accounts/:id/follow`), with no sign-in | **401** `{"error":"The access token is invalid"}` |
/// | the same, and to unfollow, with the reading words and `read:follows` | **403**, `WWW-Authenticate` naming `follow write write:follows`: the word that sees does not change |
/// | to follow somebody of this server who is not locked, with both words of follows | 200: one standing, `following` true. `relationships` then says the same |
/// | to follow them again; to unfollow them; to unfollow them again | 200 each, the same answer: **each is asked twice at no cost** |
/// | to follow somebody **locked** | 200: `following` false, **`requested` true**. Asked again: the same |
/// | to unfollow somebody asked and not yet followed | 200: `requested` false — **unfollowing is what withdraws a request**, and `relationships` then says so |
/// | to follow somebody **who lives on another server** | 200, and the answer says **`following` true, `requested` false** — while `relationships`, asked next, says `following` false, **`requested` true**: the answer to the press says what was pressed for, and only the next read says how it stands until their server agrees |
/// | to follow somebody **who blocks the reader**, somebody **the reader blocks**, or somebody **who moved** | **403** `{"error":"This action is not allowed"}`, and no `WWW-Authenticate`. Nothing changes; the block stays |
/// | to unfollow any of those | 200, the standing as it was |
/// | to follow a **suspended** account, an id nobody has, or an id that is no number | **404** `{"error":"Record not found"}` |
/// | to follow **themselves** | **403** `{"error":"Following your own account is not allowed"}`; to unfollow themselves, 200 |
/// | how the reader stands to somebody they mute **for a time** | `muting` true and `muting_expires_at` a moment, to the second with no fraction (`2026-10-13T01:37:16Z`); muted for good, `null` |
enum MastodonStandingCaptures {
    static let host = "mastodon.localhost"

    /// Somebody of this server who is not locked, and nobody follows.
    static let followable = "117430794424495804"
    /// Somebody locked.
    static let locked = "117430794346719452"
    /// Somebody of another server.
    static let far = "117430794426789903"
    /// Somebody the reader mutes.
    static let muted = "117430794334147789"

    /// `POST /api/v1/accounts/117430794424495804/follow`, and the same again.
    static let followed = #"{"id":"117430794424495804","following":true,"showing_reblogs":true,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// `POST /api/v1/accounts/117430794424495804/unfollow`, and the same again.
    static let unfollowed = #"{"id":"117430794424495804","following":false,"showing_reblogs":false,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// `POST /api/v1/accounts/117430794346719452/follow`, of somebody locked: asked, not followed.
    static let asked = #"{"id":"117430794346719452","following":false,"showing_reblogs":true,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":true,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// `POST /api/v1/accounts/117430794346719452/unfollow`, while they were asked: the request withdrawn.
    static let withdrawn = #"{"id":"117430794346719452","following":false,"showing_reblogs":false,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// `POST /api/v1/accounts/117430794426789903/follow`, of somebody of another server: what
    /// the press was answered.
    static let farFollowed = #"{"id":"117430794426789903","following":true,"showing_reblogs":true,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// `GET /api/v1/accounts/relationships?id[]=117430794426789903`, asked next: how it stands.
    static let farAsked = #"[{"id":"117430794426789903","following":false,"showing_reblogs":true,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":true,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}]"#

    /// `GET /api/v1/accounts/relationships?id[]=117430794334147789`, while they were muted for an hour.
    static let mutedForATime = #"[{"id":"117430794334147789","following":false,"showing_reblogs":false,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":true,"muting_notifications":true,"muting_expires_at":"2026-10-13T01:37:16Z","requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}]"#

    /// Following somebody who blocks the reader, whom the reader blocks, or who moved: 403 and this.
    static let notAllowed = #"{"error":"This action is not allowed"}"#
    /// Following a suspended account, or an id nobody has: 404 and this.
    static let notFound = #"{"error":"Record not found"}"#
    /// Following oneself: 403 and this.
    static let ownAccount = #"{"error":"Following your own account is not allowed"}"#
}
