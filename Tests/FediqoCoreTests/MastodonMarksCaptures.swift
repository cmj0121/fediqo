import Foundation

/// What a Mastodon says of the posts its reader bookmarked and favourited (#317), **as a real
/// server sent it** — the Mastodon 4.6.6 image `servers/compose.yml` pins, brought up alone under
/// a compose project of its own and thrown away after (`down -v`). Fetched with `curl` on
/// 2026-10-20. A second person wrote five posts, one after another; the reader bookmarked them
/// in another order — the third, the first, the fifth, the second, the fourth — and favourited
/// the fifth, then the first.
///
/// **Trimmed, not edited**: a post keeps the fields a note is read from and what it says of the
/// reader, and its author is cut to who and which picture. No token and nobody real is in here.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Mastodon 4.6.6 |
/// | ----- | -------------- |
/// | `bookmarks?limit=2` | the two **bookmarked last** — the fourth post, then the second — and a `Link` whose `next` is `max_id=4` and `prev` `min_id=5` |
/// | `bookmarks?limit=2&max_id=4` | the fifth post, then the first; `next` `max_id=2` |
/// | `bookmarks?limit=2&max_id=2` | the third alone, and **no `next`**: the end |
/// | `favourites?limit=40` | the first, then the fifth — favourited last first — and only a `prev` |
/// | `bookmarks?limit=40`, after the first post's bookmark came off | the four still marked, in mark order |
/// | either, by a sign-in that was not given its word | 403 `{"error":"This action is outside the authorized scopes"}`, and a `WWW-Authenticate` naming `insufficient_scope` and `read:bookmarks` or `read:favourites` |
///
/// So the cursor the `Link` names is **the server's own number for the mark**, counted from one
/// — `4`, `2` — and no post's id, which here are eighteen digits; the order is the order of the
/// marks, and no order of ids or of when the posts were written.
enum MastodonMarksCaptures {
    static let host = "mastodon.localhost"

    /// The first post the writer wrote.
    static let post1 = #"""
    {
      "id": "117470295251806272",
      "created_at": "2026-10-20T00:00:56.378Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "language": "en",
      "uri": "https://mastodon.localhost/ap/users/117470295244860172/statuses/117470295251806272",
      "url": "https://mastodon.localhost/@writer/117470295251806272",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 1,
      "edited_at": null,
      "favourited": true,
      "reblogged": false,
      "bookmarked": true,
      "content": "<p>post 1</p>",
      "reblog": null,
      "media_attachments": [],
      "mentions": [],
      "tags": [],
      "emojis": [],
      "account": {
        "id": "117470295244860172",
        "username": "writer",
        "acct": "writer",
        "display_name": "",
        "url": "https://mastodon.localhost/@writer",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png"
      }
    }
    """#

    /// The second post the writer wrote.
    static let post2 = #"""
    {
      "id": "117470295256611821",
      "created_at": "2026-10-20T00:00:56.430Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "language": "en",
      "uri": "https://mastodon.localhost/ap/users/117470295244860172/statuses/117470295256611821",
      "url": "https://mastodon.localhost/@writer/117470295256611821",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "edited_at": null,
      "favourited": false,
      "reblogged": false,
      "bookmarked": true,
      "content": "<p>post 2</p>",
      "reblog": null,
      "media_attachments": [],
      "mentions": [],
      "tags": [],
      "emojis": [],
      "account": {
        "id": "117470295244860172",
        "username": "writer",
        "acct": "writer",
        "display_name": "",
        "url": "https://mastodon.localhost/@writer",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png"
      }
    }
    """#

    /// The third post the writer wrote.
    static let post3 = #"""
    {
      "id": "117470295257764551",
      "created_at": "2026-10-20T00:00:56.447Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "language": "en",
      "uri": "https://mastodon.localhost/ap/users/117470295244860172/statuses/117470295257764551",
      "url": "https://mastodon.localhost/@writer/117470295257764551",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "edited_at": null,
      "favourited": false,
      "reblogged": false,
      "bookmarked": true,
      "content": "<p>post 3</p>",
      "reblog": null,
      "media_attachments": [],
      "mentions": [],
      "tags": [],
      "emojis": [],
      "account": {
        "id": "117470295244860172",
        "username": "writer",
        "acct": "writer",
        "display_name": "",
        "url": "https://mastodon.localhost/@writer",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png"
      }
    }
    """#

    /// The fourth post the writer wrote.
    static let post4 = #"""
    {
      "id": "117470295259191980",
      "created_at": "2026-10-20T00:00:56.469Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "language": "en",
      "uri": "https://mastodon.localhost/ap/users/117470295244860172/statuses/117470295259191980",
      "url": "https://mastodon.localhost/@writer/117470295259191980",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "edited_at": null,
      "favourited": false,
      "reblogged": false,
      "bookmarked": true,
      "content": "<p>post 4</p>",
      "reblog": null,
      "media_attachments": [],
      "mentions": [],
      "tags": [],
      "emojis": [],
      "account": {
        "id": "117470295244860172",
        "username": "writer",
        "acct": "writer",
        "display_name": "",
        "url": "https://mastodon.localhost/@writer",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png"
      }
    }
    """#

    /// The fifth post the writer wrote.
    static let post5 = #"""
    {
      "id": "117470295261204463",
      "created_at": "2026-10-20T00:00:56.500Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "language": "en",
      "uri": "https://mastodon.localhost/ap/users/117470295244860172/statuses/117470295261204463",
      "url": "https://mastodon.localhost/@writer/117470295261204463",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 1,
      "edited_at": null,
      "favourited": true,
      "reblogged": false,
      "bookmarked": true,
      "content": "<p>post 5</p>",
      "reblog": null,
      "media_attachments": [],
      "mentions": [],
      "tags": [],
      "emojis": [],
      "account": {
        "id": "117470295244860172",
        "username": "writer",
        "acct": "writer",
        "display_name": "",
        "url": "https://mastodon.localhost/@writer",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png"
      }
    }
    """#

    /// The posts, by when each was written: the first to the fifth.
    static let posts = [post1, post2, post3, post4, post5]
    /// Their ids, by when each was written.
    static let ids = ["117470295251806272", "117470295256611821", "117470295257764551", "117470295259191980", "117470295261204463"]

    /// A list of posts as the server sends one.
    static func listing(_ posts: [String]) -> String {
        "[" + posts.joined(separator: ",") + "]"
    }

    /// `GET /api/v1/bookmarks?limit=2`, then each next it named until one named none.
    static let bookmarkStretches: [(body: String, link: String?)] = [
        (listing([post4, post2]), #"<https://mastodon.localhost/api/v1/bookmarks?limit=2&max_id=4>; rel="next", <https://mastodon.localhost/api/v1/bookmarks?limit=2&min_id=5>; rel="prev""#),
        (listing([post5, post1]), #"<https://mastodon.localhost/api/v1/bookmarks?limit=2&max_id=2>; rel="next", <https://mastodon.localhost/api/v1/bookmarks?limit=2&min_id=3>; rel="prev""#),
        (listing([post3]), #"<https://mastodon.localhost/api/v1/bookmarks?limit=2&min_id=1>; rel="prev""#),
    ]

    /// `GET /api/v1/favourites?limit=40`: the first post, favourited last, then the fifth.
    static let favourites = (body: listing([post1, post5]), link: #"<https://mastodon.localhost/api/v1/favourites?limit=40&min_id=2>; rel="prev""#)

    /// `GET /api/v1/bookmarks?limit=40` after the first post's bookmark was taken off.
    static let bookmarksAfterOne = (body: listing([post4, post2, post5, post3]), link: #"<https://mastodon.localhost/api/v1/bookmarks?limit=40&min_id=5>; rel="prev""#)

    /// Either, asked by a sign-in not given its word: 403.
    static let outsideScope = #"{"error":"This action is outside the authorized scopes"}"#
    static let outsideScopeHeader = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _read read:bookmarks_.""#
}
