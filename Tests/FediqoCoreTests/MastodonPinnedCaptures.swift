import Foundation

/// What a Mastodon says of the posts somebody pinned (#310), **as a real server sent it** — the
/// Mastodon 4.6.6 image `servers/compose.yml` pins — and beside it what a GoToSocial 0.22.2 sent
/// to the same asks (`FEDIQO_SERVERS_GOTOSOCIAL=1 make servers`). Fetched with `curl` on
/// 2026-10-13. Nobody in either seed has pinned anything, so three posts of the Mastodon seed's
/// writer (`fediqo`) were pinned through the server's own API as them — the third of their spare
/// posts, then the seventh, then the first — and two of the GoToSocial seed's `other`; each was
/// unpinned again when the answers were in.
///
/// **Trimmed, not edited**, as `MastodonPeopleCaptures` is: a post keeps the fields a note is
/// read from, what it says of the reader, and its author cut to who and which picture. No token
/// and nobody real is in here.
///
/// ## What was asked, and what the servers answered
///
/// | Asked | Mastodon 4.6.6 | GoToSocial 0.22.2 |
/// | ----- | -------------- | ----------------- |
/// | `accounts/:id/statuses?pinned=true`, of somebody who pinned nothing | `200 []`, no `Link` — with no sign-in, as themselves, as anybody | `200 []`, no `Link`, signed in |
/// | the same, with no sign-in | 200, as to anybody; a token that is none is answered as nobody is | **401** `{"error":"Unauthorized: token not supplied"}`, as it answers every read |
/// | the same, of a suspended account, of somebody who blocks the reader, of somebody of another server, of an account with nothing | `200 []`, each | not asked: its seed has none |
/// | the same, of an id nobody has | 404 `{"error":"Record not found"}` | **`200 []`** |
/// | of somebody who pinned three | the three, **the one pinned last first** — not in the order of their ids, nor of when they were written | the ones pinned, **the one pinned first first** |
/// | whether a pinned post says it is | **only to its author**: `"pinned": true` on each, and `false` on their other posts wherever one is carried. To anybody else, and with no sign-in, a post carries no `pinned` at all — in this answer or alone | `pinned` on every post to everybody, and it is about the reader: `true` to the author, **`false` to anybody else on a post that is pinned** |
/// | the `Link` of the answer | `rel="prev"` alone where nothing was cut, and **every address in it repeats `pinned=true`** as it was sent (`pinned=1` and `pinned=yes` are taken for yes too, and repeated so) | **none at all** on a pinned answer |
/// | with a length shorter than what is pinned (`limit=2`) | cut, and `rel="next"` names `max_id` **the last listed post's id — in a list that is not in id order**: the stretch after it is every pinned post with a smaller id, the pin order over again, so it repeats one already given, and a post with a larger id than the last listed would never come | `limit` and `max_id` are passed over: the whole answer again |
/// | with no length | all of them: a stretch is twenty, and an account may pin five (`configuration.accounts.max_pinned_statuses`) | all of them; its document says no such figure |
/// | a made-up word in place of the word (`fediqo_pinned=true`), and the word with no value | **their ordinary newest posts**, and a `Link` whose addresses do not carry the word | their ordinary newest posts, boosts among them, and a `Link` whose addresses say **`pinned=false`** — as its `Link` says on every ordinary answer |
/// | `pinned=false`, `pinned=0` | their ordinary posts, the word repeated as sent | their ordinary posts; `pinned=yes` is **400** |
/// | a boost pinned by who boosted; somebody else's post pinned | 422 `"A boost cannot be pinned"`; 422 `"Someone else's post cannot be pinned"` | 422 `"cannot pin boosts"`; 422, the post "does not belong to" them |
///
/// So nothing on a post tells anybody but its author that it is pinned, and on one server it
/// says the opposite. What tells an answer to the word from the ordinary posts is what the
/// answer names for more — the word repeated, or no address at all, against an address without
/// it or with it as a no — and that no boost is ever pinned (`MastodonPerson.pinned`).
enum MastodonPinnedCaptures {
    typealias Stretch = MastodonPeopleCaptures.Stretch

    static let host = "mastodon.localhost"
    /// The id the seed's writer is listed under, and their three pinned posts as the server
    /// lists them: the one pinned last first.
    static let writerID = "117431477460495369"
    static let pinnedIDs = ["117431477709493982", "117431477716556178", "117431477712578675"]

    /// `GET /api/v1/accounts/:id/statuses?pinned=true` of somebody who pinned nothing: `200`, no `Link`.
    static let nonePinned = #"[]"#


    /// `GET /api/v1/accounts/:id/statuses?pinned=true`, with no sign-in: all three, and a `Link` that names only
    /// what is newer.
    static let pinned = Stretch(body: #"""
    [
      {
        "id": "117431477709493982",
        "created_at": "2026-10-13T03:29:07.666Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "unlisted",
        "language": "en",
        "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431477709493982",
        "url": "https://mastodon.localhost/@fediqo/117431477709493982",
        "replies_count": 0,
        "reblogs_count": 0,
        "favourites_count": 1,
        "edited_at": null,
        "content": "<p>fediqo323seed spare 001</p>",
        "reblog": null,
        "account": {
          "id": "117431477460495369",
          "username": "fediqo",
          "acct": "fediqo",
          "display_name": "",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": [],
        "quote": null
      },
      {
        "id": "117431477716556178",
        "created_at": "2026-10-13T03:29:07.774Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "unlisted",
        "language": "en",
        "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431477716556178",
        "url": "https://mastodon.localhost/@fediqo/117431477716556178",
        "replies_count": 0,
        "reblogs_count": 0,
        "favourites_count": 1,
        "edited_at": null,
        "content": "<p>fediqo323seed spare 007</p>",
        "reblog": null,
        "account": {
          "id": "117431477460495369",
          "username": "fediqo",
          "acct": "fediqo",
          "display_name": "",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": [],
        "quote": null
      },
      {
        "id": "117431477712578675",
        "created_at": "2026-10-13T03:29:07.713Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "unlisted",
        "language": "en",
        "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431477712578675",
        "url": "https://mastodon.localhost/@fediqo/117431477712578675",
        "replies_count": 0,
        "reblogs_count": 0,
        "favourites_count": 1,
        "edited_at": null,
        "content": "<p>fediqo323seed spare 003</p>",
        "reblog": null,
        "account": {
          "id": "117431477460495369",
          "username": "fediqo",
          "acct": "fediqo",
          "display_name": "",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": [],
        "quote": null
      }
    ]
    """#, link: #"<https://mastodon.localhost/api/v1/accounts/117431477460495369/statuses?min_id=117431477709493982&pinned=true>; rel="prev""#)

    /// The same asked as their author with `limit=1`: the post says it is pinned, and what the reader did to it.
    static let pinnedToTheirAuthor = Stretch(body: #"""
    [
      {
        "id": "117431477709493982",
        "created_at": "2026-10-13T03:29:07.666Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "unlisted",
        "language": "en",
        "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431477709493982",
        "url": "https://mastodon.localhost/@fediqo/117431477709493982",
        "replies_count": 0,
        "reblogs_count": 0,
        "favourites_count": 1,
        "edited_at": null,
        "favourited": false,
        "reblogged": false,
        "bookmarked": false,
        "pinned": true,
        "content": "<p>fediqo323seed spare 001</p>",
        "reblog": null,
        "account": {
          "id": "117431477460495369",
          "username": "fediqo",
          "acct": "fediqo",
          "display_name": "",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": [],
        "quote": null
      }
    ]
    """#, link: #"<https://mastodon.localhost/api/v1/accounts/117431477460495369/statuses?limit=1&max_id=117431477709493982&pinned=true>; rel="next", <https://mastodon.localhost/api/v1/accounts/117431477460495369/statuses?limit=1&min_id=117431477709493982&pinned=true>; rel="prev""#)

    /// The same with `limit=2` and no sign-in, read on by each answer's own next: two, two — the first of them
    /// given already — and one, given twice already, with no next.
    static let pinnedByLength = [
        Stretch(body: #"""
        [
          {
            "id": "117431477709493982",
            "created_at": "2026-10-13T03:29:07.666Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "unlisted",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431477709493982",
            "url": "https://mastodon.localhost/@fediqo/117431477709493982",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 1,
            "edited_at": null,
            "content": "<p>fediqo323seed spare 001</p>",
            "reblog": null,
            "account": {
              "id": "117431477460495369",
              "username": "fediqo",
              "acct": "fediqo",
              "display_name": "",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": []
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          },
          {
            "id": "117431477716556178",
            "created_at": "2026-10-13T03:29:07.774Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "unlisted",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431477716556178",
            "url": "https://mastodon.localhost/@fediqo/117431477716556178",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 1,
            "edited_at": null,
            "content": "<p>fediqo323seed spare 007</p>",
            "reblog": null,
            "account": {
              "id": "117431477460495369",
              "username": "fediqo",
              "acct": "fediqo",
              "display_name": "",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": []
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117431477460495369/statuses?limit=2&max_id=117431477716556178&pinned=true>; rel="next", <https://mastodon.localhost/api/v1/accounts/117431477460495369/statuses?limit=2&min_id=117431477709493982&pinned=true>; rel="prev""#),
        Stretch(body: #"""
        [
          {
            "id": "117431477709493982",
            "created_at": "2026-10-13T03:29:07.666Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "unlisted",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431477709493982",
            "url": "https://mastodon.localhost/@fediqo/117431477709493982",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 1,
            "edited_at": null,
            "content": "<p>fediqo323seed spare 001</p>",
            "reblog": null,
            "account": {
              "id": "117431477460495369",
              "username": "fediqo",
              "acct": "fediqo",
              "display_name": "",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": []
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          },
          {
            "id": "117431477712578675",
            "created_at": "2026-10-13T03:29:07.713Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "unlisted",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431477712578675",
            "url": "https://mastodon.localhost/@fediqo/117431477712578675",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 1,
            "edited_at": null,
            "content": "<p>fediqo323seed spare 003</p>",
            "reblog": null,
            "account": {
              "id": "117431477460495369",
              "username": "fediqo",
              "acct": "fediqo",
              "display_name": "",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": []
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117431477460495369/statuses?limit=2&max_id=117431477712578675&pinned=true>; rel="next", <https://mastodon.localhost/api/v1/accounts/117431477460495369/statuses?limit=2&min_id=117431477709493982&pinned=true>; rel="prev""#),
        Stretch(body: #"""
        [
          {
            "id": "117431477709493982",
            "created_at": "2026-10-13T03:29:07.666Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "unlisted",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431477709493982",
            "url": "https://mastodon.localhost/@fediqo/117431477709493982",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 1,
            "edited_at": null,
            "content": "<p>fediqo323seed spare 001</p>",
            "reblog": null,
            "account": {
              "id": "117431477460495369",
              "username": "fediqo",
              "acct": "fediqo",
              "display_name": "",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": []
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117431477460495369/statuses?limit=2&min_id=117431477709493982&pinned=true>; rel="prev""#),
    ]

    /// `GET /api/v1/accounts/:id/statuses?fediqo_pinned=true&limit=3`: the word passed over, and their ordinary
    /// newest posts — none of them pinned.
    static let wordPassedOver = Stretch(body: #"""
    [
      {
        "id": "117431482161160850",
        "created_at": "2026-10-13T03:30:15.593Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "public",
        "language": "zh-TW",
        "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431482161160850",
        "url": "https://mastodon.localhost/@fediqo/117431482161160850",
        "replies_count": 0,
        "reblogs_count": 1,
        "favourites_count": 0,
        "edited_at": null,
        "content": "<p>fediqo-106-EF993AB8</p>",
        "reblog": null,
        "account": {
          "id": "117431477460495369",
          "username": "fediqo",
          "acct": "fediqo",
          "display_name": "",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": [],
        "quote": null
      },
      {
        "id": "117431482146351778",
        "created_at": "2026-10-13T03:30:15.368Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "public",
        "language": "zh-TW",
        "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431482146351778",
        "url": "https://mastodon.localhost/@fediqo/117431482146351778",
        "replies_count": 0,
        "reblogs_count": 0,
        "favourites_count": 0,
        "edited_at": null,
        "content": "<p>fediqo-56-BBD6F569</p>",
        "reblog": null,
        "account": {
          "id": "117431477460495369",
          "username": "fediqo",
          "acct": "fediqo",
          "display_name": "",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": [],
        "quote": null
      },
      {
        "id": "117431482119294278",
        "created_at": "2026-10-13T03:30:14.960Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "public",
        "language": "zh-TW",
        "uri": "https://mastodon.localhost/ap/users/117431477460495369/statuses/117431482119294278",
        "url": "https://mastodon.localhost/@fediqo/117431482119294278",
        "replies_count": 0,
        "reblogs_count": 0,
        "favourites_count": 0,
        "edited_at": null,
        "content": "<p>fediqo-55-E6191DD9</p>",
        "reblog": null,
        "account": {
          "id": "117431477460495369",
          "username": "fediqo",
          "acct": "fediqo",
          "display_name": "",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": [],
        "quote": null
      }
    ]
    """#, link: #"<https://mastodon.localhost/api/v1/accounts/117431477460495369/statuses?limit=3&max_id=117431482119294278>; rel="next", <https://mastodon.localhost/api/v1/accounts/117431477460495369/statuses?limit=3&min_id=117431482161160850>; rel="prev""#)

    /// A GoToSocial's host, and the id its seed's `other` is listed under.
    static let otherHost = "gotosocial.localhost"
    static let otherID = "01YP0RT2FVWEV353EE5W05QDTQ"

    /// A GoToSocial asked `GET /api/v1/accounts/:id/statuses?pinned=true` as somebody else: the two pinned, the
    /// one pinned first first, each saying `"pinned": false`, and no `Link`.
    static let otherPinned = Stretch(body: #"""
    [
      {
        "id": "01M4SMY2QYQRN9YFG42KPN5K1C",
        "created_at": "2026-10-13T03:29:40.606Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "public",
        "language": "en",
        "uri": "https://gotosocial.localhost/users/other/statuses/01M4SMY2QYQRN9YFG42KPN5K1C",
        "url": "https://gotosocial.localhost/@other/statuses/01M4SMY2QYQRN9YFG42KPN5K1C",
        "replies_count": 0,
        "reblogs_count": 0,
        "favourites_count": 0,
        "edited_at": "2026-10-13T03:29:40.634Z",
        "favourited": false,
        "reblogged": false,
        "bookmarked": false,
        "pinned": false,
        "content": "<p>Another person's post, after it was changed.</p>",
        "reblog": null,
        "account": {
          "id": "01YP0RT2FVWEV353EE5W05QDTQ",
          "username": "other",
          "acct": "other",
          "display_name": "other",
          "avatar": "https://gotosocial.localhost/assets/default_avatars/GoToSocial_icon4.webp",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": []
      },
      {
        "id": "01M4SMY2Q30H6CXRBCAGQ42734",
        "created_at": "2026-10-13T03:29:40.579Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "public",
        "language": "en",
        "uri": "https://gotosocial.localhost/users/other/statuses/01M4SMY2Q30H6CXRBCAGQ42734",
        "url": "https://gotosocial.localhost/@other/statuses/01M4SMY2Q30H6CXRBCAGQ42734",
        "replies_count": 0,
        "reblogs_count": 0,
        "favourites_count": 0,
        "edited_at": null,
        "favourited": false,
        "reblogged": false,
        "bookmarked": false,
        "pinned": false,
        "content": "<p>Another person's post, never changed. <a href=\"https://gotosocial.localhost/tags/fediqo\" class=\"mention hashtag\" rel=\"tag nofollow noreferrer noopener\" target=\"_blank\">#<span>fediqo</span></a></p>",
        "reblog": null,
        "account": {
          "id": "01YP0RT2FVWEV353EE5W05QDTQ",
          "username": "other",
          "acct": "other",
          "display_name": "other",
          "avatar": "https://gotosocial.localhost/assets/default_avatars/GoToSocial_icon4.webp",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": []
      }
    ]
    """#, link: nil)

    /// The same server asked for the same account's posts with a made-up word in place of the word: a boost,
    /// two posts, and a `Link` that says `pinned=false`.
    static let otherWordPassedOver = Stretch(body: #"""
    [
      {
        "id": "01M4SMY2SHBRADB3YVW3GDH83H",
        "created_at": "2026-10-13T03:29:40.000Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "public",
        "language": null,
        "uri": "https://gotosocial.localhost/users/other/statuses/01M4SMY2SHBRADB3YVW3GDH83H",
        "url": "https://gotosocial.localhost/@other/statuses/01M4SMY2SHBRADB3YVW3GDH83H",
        "replies_count": 0,
        "reblogs_count": 0,
        "favourites_count": 0,
        "edited_at": null,
        "favourited": false,
        "reblogged": false,
        "bookmarked": false,
        "pinned": false,
        "content": "",
        "reblog": {
          "id": "01M4SMY2P3W13ETQGFFP4R91ZW",
          "created_at": "2026-10-13T03:29:40.552Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://gotosocial.localhost/users/writer/statuses/01M4SMY2P3W13ETQGFFP4R91ZW",
          "url": "https://gotosocial.localhost/@writer/statuses/01M4SMY2P3W13ETQGFFP4R91ZW",
          "replies_count": 0,
          "reblogs_count": 1,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "pinned": false,
          "content": "<p>A public note on this machine. <a href=\"https://gotosocial.localhost/tags/fediqo\" class=\"mention hashtag\" rel=\"tag nofollow noreferrer noopener\" target=\"_blank\">#<span>fediqo</span></a></p>",
          "reblog": null,
          "account": {
            "id": "01WXK0DEZX3E41NK6AM6R998R7",
            "username": "writer",
            "acct": "writer",
            "display_name": "writer",
            "avatar": "https://gotosocial.localhost/assets/default_avatars/GoToSocial_icon4.webp",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": []
        },
        "account": {
          "id": "01YP0RT2FVWEV353EE5W05QDTQ",
          "username": "other",
          "acct": "other",
          "display_name": "other",
          "avatar": "https://gotosocial.localhost/assets/default_avatars/GoToSocial_icon4.webp",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": []
      },
      {
        "id": "01M4SMY2QYQRN9YFG42KPN5K1C",
        "created_at": "2026-10-13T03:29:40.606Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "public",
        "language": "en",
        "uri": "https://gotosocial.localhost/users/other/statuses/01M4SMY2QYQRN9YFG42KPN5K1C",
        "url": "https://gotosocial.localhost/@other/statuses/01M4SMY2QYQRN9YFG42KPN5K1C",
        "replies_count": 0,
        "reblogs_count": 0,
        "favourites_count": 0,
        "edited_at": "2026-10-13T03:29:40.634Z",
        "favourited": false,
        "reblogged": false,
        "bookmarked": false,
        "pinned": false,
        "content": "<p>Another person's post, after it was changed.</p>",
        "reblog": null,
        "account": {
          "id": "01YP0RT2FVWEV353EE5W05QDTQ",
          "username": "other",
          "acct": "other",
          "display_name": "other",
          "avatar": "https://gotosocial.localhost/assets/default_avatars/GoToSocial_icon4.webp",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": []
      },
      {
        "id": "01M4SMY2Q30H6CXRBCAGQ42734",
        "created_at": "2026-10-13T03:29:40.579Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "public",
        "language": "en",
        "uri": "https://gotosocial.localhost/users/other/statuses/01M4SMY2Q30H6CXRBCAGQ42734",
        "url": "https://gotosocial.localhost/@other/statuses/01M4SMY2Q30H6CXRBCAGQ42734",
        "replies_count": 0,
        "reblogs_count": 0,
        "favourites_count": 0,
        "edited_at": null,
        "favourited": false,
        "reblogged": false,
        "bookmarked": false,
        "pinned": false,
        "content": "<p>Another person's post, never changed. <a href=\"https://gotosocial.localhost/tags/fediqo\" class=\"mention hashtag\" rel=\"tag nofollow noreferrer noopener\" target=\"_blank\">#<span>fediqo</span></a></p>",
        "reblog": null,
        "account": {
          "id": "01YP0RT2FVWEV353EE5W05QDTQ",
          "username": "other",
          "acct": "other",
          "display_name": "other",
          "avatar": "https://gotosocial.localhost/assets/default_avatars/GoToSocial_icon4.webp",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": []
      }
    ]
    """#, link: #"<https://gotosocial.localhost/api/v1/accounts/01YP0RT2FVWEV353EE5W05QDTQ/statuses?limit=30&max_id=01M4SMY2Q30H6CXRBCAGQ42734&exclude_replies=false&exclude_reblogs=false&pinned=false&only_media=false&only_public=false>; rel="next", <https://gotosocial.localhost/api/v1/accounts/01YP0RT2FVWEV353EE5W05QDTQ/statuses?limit=30&min_id=01M4SMY2SHBRADB3YVW3GDH83H&exclude_replies=false&exclude_reblogs=false&pinned=false&only_media=false&only_public=false>; rel="prev""#)
}
