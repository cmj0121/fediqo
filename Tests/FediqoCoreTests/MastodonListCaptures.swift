import Foundation

/// What a Mastodon 4.6.6 says of a list (#337), **as the server this repo brings up sent it**.
///
/// Asked with `curl` on 2026-10-27 of the image `servers/compose.yml` pins, already running for
/// another lane, as a sign-in that may write and as one that may only read lists. The seeded
/// list `fediqo-298` was read and left in place. No token is in here.
///
/// **Every constant is every byte the server sent** for that answer. A list is `id`, `title`,
/// `replies_policy` and `exclusive`. Making one with only a title comes back `replies_policy`
/// `list` and `exclusive` false. `replies_policy` takes `followed`, `list` and `none`. A title
/// of 200 letters was taken. An empty title, a policy the server has not, and adding somebody
/// it will not list are 422 in its own sentence. An id it has not is 404 `Record not found`,
/// which is a missing record and not a missing address. Removing a list, and adding or removing
/// a person, come back `{}`. A sign-in without `write:lists` is 403, and `WWW-Authenticate`
/// names `write write:lists`. Reading lists, who is on one, and which lists a person is on do
/// not need that word. Who is on a list pages by `Link`, `max_id` of `rel="next"`.
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | `GET /api/v1/lists` | 200, the seeded list |
/// | `POST /api/v1/lists` with only `title` | 200, `replies_policy` `list`, `exclusive` false |
/// | `PUT` title, `replies_policy` `followed` and `exclusive` true | 200, those |
/// | `PUT` `replies_policy` `none`, then `list` | 200, each |
/// | `PUT` `replies_policy` `everyone` | 422, policy is not one it has |
/// | a title of nothing | 422, title can't be blank |
/// | a title of 200 letters | 200 |
/// | an id the server has not, read, changed or removed again | 404 `Record not found` |
/// | `DELETE` a list | 200 `{}` |
/// | `GET …/accounts` of an empty list | 200 `[]` |
/// | `GET …/accounts?limit=1` | 200, one account, and `Link` |
/// | add somebody followed, somebody of this server not followed, or oneself | 200 `{}` |
/// | add somebody of another server | 422, account must be a followed account |
/// | add an id it has not | 404 `Record not found` |
/// | remove somebody | 200 `{}` |
/// | `GET /api/v1/accounts/:id/lists` | 200, the lists that account is on |
/// | any write by a sign-in without `write:lists` | 403, naming `write:lists` |
enum MastodonListCaptures {
    static let host = "mastodon.localhost"
    /// The seeded list, left in place.
    static let seeded = "1"
    /// Somebody of this server who is followed. The paged read's `Link` names the same id.
    static let person = "117510097148048886"
    /// `GET /api/v1/lists`, and the same bytes for a sign-in that only reads, and for `GET /api/v1/accounts/:id/lists`.
    static let lists = #"[{"id":"1","title":"fediqo-298","replies_policy":"list","exclusive":false}]"#

    /// `POST /api/v1/lists` with only a title.
    static let created = #"{"id":"2","title":"fediqo-337-probe","replies_policy":"list","exclusive":false}"#

    /// `GET /api/v1/lists/:id` of the list just made.
    static let readBack = #"{"id":"2","title":"fediqo-337-probe","replies_policy":"list","exclusive":false}"#

    /// `PUT` with a new title, `replies_policy=followed` and `exclusive=true`.
    static let renamedFollowed = #"{"id":"2","title":"fediqo-337-renamed","replies_policy":"followed","exclusive":true}"#

    /// `PUT` with `replies_policy=none` and `exclusive=false`.
    static let renamedNone = #"{"id":"2","title":"fediqo-337-renamed","replies_policy":"none","exclusive":false}"#

    /// `PUT` with `replies_policy=list` and `exclusive=false`.
    static let renamedList = #"{"id":"2","title":"fediqo-337-renamed","replies_policy":"list","exclusive":false}"#

    /// `PUT` with `replies_policy=everyone`: 422.
    static let badPolicy = #"{"error":"Validation failed: Replies policy is not included in the list"}"#

    /// `POST` with an empty title: 422.
    static let blankTitle = #"{"error":"Validation failed: Title can't be blank"}"#

    /// `GET` of an id the server has not: 404.
    static let missing = #"{"error":"Record not found"}"#

    /// `PUT` of an id the server has not: 404.
    static let putMissing = #"{"error":"Record not found"}"#

    /// `DELETE` of a list: 200.
    static let removed = #"{}"#

    /// `DELETE` of a list already gone: 404.
    static let removedAgain = #"{"error":"Record not found"}"#

    /// `GET /api/v1/lists/:id/accounts` when nobody is on it.
    static let nobody = #"[]"#

    /// `GET /api/v1/lists/1/accounts?limit=1`: one account, the whole object. The unpaged read of that one person was these same bytes.
    static let onePerson = #"[{"id":"117510097148048886","username":"fediqo_other","acct":"fediqo_other","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-27T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo_other","uri":"https://mastodon.localhost/ap/users/117510097148048886","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":2,"following_count":0,"statuses_count":8,"last_status_at":"2026-10-27","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]}]"#

    /// Adding somebody who is followed: 200. Adding somebody of this server who is not, and adding oneself, answered the same `{}`.
    static let added = #"{}"#

    /// Adding a local account the reader does not follow: 200. The server did not refuse it.
    static let addedUnfollowed = #"{}"#

    /// Adding the reader themself: 200.
    static let addedSelf = #"{}"#

    /// Adding somebody of another server: 422.
    static let mustFollow = #"{"error":"Validation failed: Account must be a followed account"}"#

    /// Adding an id the server has not: 404.
    static let missingAccount = #"{"error":"Record not found"}"#

    /// Removing somebody: 200.
    static let dropped = #"{}"#

    /// A write without `write:lists`: 403. The same body for removing a list and for adding a person.
    static let outside = #"{"error":"This action is outside the authorized scopes"}"#

    /// `POST` with a title of 200 letters: 200. Nothing here caps a title short of the server.
    static let longTitle = #"{"id":"3","title":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","replies_policy":"list","exclusive":false}"#

    /// `GET /api/v1/accounts/:id/lists`: the lists that account is on, not the lists they own.
    static let ofPerson = #"[{"id":"1","title":"fediqo-298","replies_policy":"list","exclusive":false}]"#

    /// `Link` on that paged read, the header value alone.
    static let personLink = #"<https://mastodon.localhost/api/v1/lists/1/accounts?limit=1&max_id=117510097148048886>; rel="next", <https://mastodon.localhost/api/v1/lists/1/accounts?limit=1&since_id=117510097148048886>; rel="prev""#

    /// `WWW-Authenticate` on that 403.
    static let outsideAuthenticate = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _write write:lists_.""#
}
