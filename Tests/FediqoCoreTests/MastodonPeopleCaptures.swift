import Foundation

/// What a Mastodon says of a person, of the people around them and of their posts (#310, #311),
/// **as a real server sent it** — the Mastodon 4.6.6 image `servers/compose.yml` pins, seeded by
/// `servers/mastodon/seed.rb` with the people of #309: `fediqo_person`, who has a name partly
/// written in a picture, words, two fields, eight followers and four they follow;
/// `fediqo_locked`; `fediqo_hidden`, who hides their lists and has two followers; `fediqo_moved`,
/// who moved to the first; `fediqo_gone`, suspended; `fediqo_limited`; `fediqo_robot`, automated
/// and with nothing; and `far` and `far_hidden` of `elsewhere.example`, as this server would
/// hold somebody living on another. Fetched with `curl` on 2026-10-10, with no sign-in unless
/// said, in the one window the story's plan calls step 0; the server was then thrown away.
///
/// **Trimmed, not edited.** An account asked for by itself is whole, but for the account it
/// moved to, which is cut to who that is. An account in a list keeps the fields a person is
/// read from, in the order the server wrote them; a post keeps the fields a note is read from
/// and its author cut to who and which picture. No token and nobody real is in here: the
/// accounts are the seed's, the host the local `mastodon.localhost`.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | an account, by id or by handle (`lookup?acct=`) | the same body by either, to anyone: no sign-in, a sign-in, and **a token that is no token at all** are answered alike (200). `acct` may be `name`, `name@this.host`, `@name` or in another case; somebody of another server only as `name@their.host`, and only where this server has already heard of them — nothing is asked of the other server |
/// | nobody of that handle, no `acct`, an id nobody has, an id that is not a number | 404 `{"error":"Record not found"}`, each |
/// | somebody living elsewhere | `acct` is `name@host` where a local one is `name`; `url` and `uri` are the other server's; `avatar` is this server's copy; **the counts are the other server's** (2811 followers) while the lists hold what reached here (2) |
/// | a list its owner hides | `200 []`, no `Link` — **exactly what an empty list is**. Only the account says why: `hide_collections` is `true`. The owner, signed in, is given the list |
/// | `hide_collections` where nobody hides | `null` for a local account that never set it, not `false`. For somebody living elsewhere the server's own source sets it from whether their collections can be read (`ProcessAccountService`: `following_private? \|\| followers_private?`) — **read off the source, not asked**: this server cannot be made to hear of a real other one |
/// | a list of somebody who blocks the reader, of a suspended account | `200 []` as well, and nothing on the account says so to the one blocked |
/// | a suspended account | 200 by id and by handle, with `"suspended": true`, no name, no words, no fields — and its counts still; its posts and both lists `200 []` |
/// | a moved account | the account, with the one it moved to whole inside it under `moved` |
/// | a locked one, an automated one, a limited one | `"locked": true`; `"bot": true`; `"limited": true`, a key absent from every other account |
/// | followers and following, a stretch at a time | newest follow first; `Link` names `rel="next"` with `max_id` **and that id is the follow's, not a person's** (`max_id=19`), so nothing in the body says where the next stretch begins. A stretch as long as was asked for names a next even when it was the last: the stretch after is `200 []` with no `Link`. `limit` is held to 80 and the default is 40 (`stretchLengths`) |
/// | the same list, signed in | the people the reader blocks or mutes are left out — six of the eight — and a stretch is still two long: the server filters before it cuts |
/// | their posts, a stretch at a time | newest first, a boost listed under its own id; `Link` names `rel="next"` with `max_id` the last post's id and `rel="prev"` with `min_id` the first's. The last stretch, shorter than asked, names no next. Followers-only and direct posts are not given to a reader who may not see them. An id that is not one (`max_id=abc`) is `200 []` |
/// | how the reader stands to people (`relationships?id[]=`) | one entry an id asked, in the server's order, **none for an id nobody has and none for a suspended account** unless `with_suspended=true`. No sign-in: 401. A sign-in without `read:follows`: 403 and `WWW-Authenticate: … error="insufficient_scope" … requires scope _read read:follows_`. The app's reading scopes alone do not hold it |
enum MastodonPeopleCaptures {
    static let host = "mastodon.localhost"

    /// `GET /api/v1/accounts/:id`, and `GET /api/v1/accounts/lookup?acct=fediqo_person` byte for byte.
    static let person = #"""
    {
      "id": "117417151802177425",
      "username": "fediqo_person",
      "acct": "fediqo_person",
      "display_name": "Per :fediqo_mark: Son",
      "locked": false,
      "bot": false,
      "discoverable": null,
      "indexable": false,
      "group": false,
      "created_at": "2026-10-10T00:00:00.000Z",
      "note": "<p>Reads <a href=\"https://mastodon.localhost/tags/fediqo309\" class=\"mention hashtag\" rel=\"tag\">#<span>fediqo309</span></a> beside <span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo_other\" class=\"u-url mention\">@<span>fediqo_other</span></a></span> :fediqo_mark:<br /><a href=\"https://example.com/about\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/about</span><span class=\"invisible\"></span></a></p>",
      "url": "https://mastodon.localhost/@fediqo_person",
      "uri": "https://mastodon.localhost/ap/users/117417151802177425",
      "avatar": "https://mastodon.localhost/avatars/original/missing.png",
      "avatar_static": "https://mastodon.localhost/avatars/original/missing.png",
      "avatar_description": "",
      "header": "https://mastodon.localhost/headers/original/missing.png",
      "header_static": "https://mastodon.localhost/headers/original/missing.png",
      "header_description": "",
      "followers_count": 8,
      "following_count": 4,
      "statuses_count": 9,
      "last_status_at": "2026-10-10",
      "hide_collections": null,
      "show_media": true,
      "show_media_replies": true,
      "show_featured": true,
      "noindex": false,
      "feature_approval": {
        "automatic": [],
        "manual": [],
        "current_user": "denied"
      },
      "emojis": [
        {
          "shortcode": "fediqo_mark",
          "url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/adb2dc4e93fe6cab.png",
          "static_url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/adb2dc4e93fe6cab.png",
          "visible_in_picker": true
        }
      ],
      "roles": [],
      "fields": [
        {
          "name": "Site",
          "value": "<a href=\"https://example.com/per\" target=\"_blank\" rel=\"nofollow noopener me\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"\">example.com/per</span><span class=\"invisible\"></span></a>",
          "verified_at": "2026-10-01T00:00:00.000+00:00"
        },
        {
          "name": "Pronouns :fediqo_mark:",
          "value": "they/them",
          "verified_at": null
        }
      ]
    }
    """#

    /// Somebody living on another server, as this one holds them.
    static let far = #"""
    {
      "id": "117417151906965812",
      "username": "far",
      "acct": "far@elsewhere.example",
      "display_name": "Far :far_mark: Away",
      "locked": false,
      "bot": false,
      "discoverable": null,
      "indexable": false,
      "group": false,
      "created_at": "2026-10-10T00:00:00.000Z",
      "note": "<p>Lives elsewhere :far_mark:</p>",
      "url": "https://elsewhere.example/@far",
      "uri": "https://elsewhere.example/users/far",
      "avatar": "https://mastodon.localhost/avatars/original/missing.png",
      "avatar_static": "https://mastodon.localhost/avatars/original/missing.png",
      "avatar_description": "",
      "header": "https://mastodon.localhost/headers/original/missing.png",
      "header_static": "https://mastodon.localhost/headers/original/missing.png",
      "header_description": "",
      "followers_count": 2811,
      "following_count": 310,
      "statuses_count": 1204,
      "last_status_at": "2026-10-10",
      "hide_collections": null,
      "show_media": true,
      "show_media_replies": true,
      "show_featured": true,
      "feature_approval": {
        "automatic": [],
        "manual": [],
        "current_user": "denied"
      },
      "emojis": [
        {
          "shortcode": "far_mark",
          "url": "https://mastodon.localhost/system/cache/custom_emojis/images/000/000/002/original/7497236a04d8578d.png",
          "static_url": "https://mastodon.localhost/system/cache/custom_emojis/images/000/000/002/static/7497236a04d8578d.png",
          "visible_in_picker": true
        }
      ],
      "fields": [
        {
          "name": "Home",
          "value": "<a href=\"https://elsewhere.example/far\" rel=\"nofollow noopener\" target=\"_blank\">elsewhere.example/far</a>",
          "verified_at": null
        }
      ]
    }
    """#

    /// Somebody living elsewhere whose lists this server holds to be hidden.
    static let farHidden = #"""
    {
      "id": "117417151911024455",
      "username": "far_hidden",
      "acct": "far_hidden@elsewhere.example",
      "display_name": "Far Hidden",
      "locked": false,
      "bot": false,
      "group": false,
      "note": "",
      "avatar": "https://mastodon.localhost/avatars/original/missing.png",
      "header": "https://mastodon.localhost/headers/original/missing.png",
      "followers_count": 77,
      "following_count": 55,
      "statuses_count": 33,
      "hide_collections": true,
      "emojis": [],
      "fields": []
    }
    """#

    /// Somebody here who hides who they follow and who follows them.
    static let hidden = #"""
    {
      "id": "117417151865995738",
      "username": "fediqo_hidden",
      "acct": "fediqo_hidden",
      "display_name": "",
      "locked": false,
      "bot": false,
      "group": false,
      "note": "",
      "avatar": "https://mastodon.localhost/avatars/original/missing.png",
      "header": "https://mastodon.localhost/headers/original/missing.png",
      "followers_count": 2,
      "following_count": 1,
      "statuses_count": 1,
      "hide_collections": true,
      "emojis": [],
      "fields": []
    }
    """#

    /// Somebody who must agree before anybody follows them.
    static let locked = #"""
    {
      "id": "117417151858808174",
      "username": "fediqo_locked",
      "acct": "fediqo_locked",
      "display_name": "",
      "locked": true,
      "bot": false,
      "group": false,
      "note": "",
      "avatar": "https://mastodon.localhost/avatars/original/missing.png",
      "header": "https://mastodon.localhost/headers/original/missing.png",
      "followers_count": 0,
      "following_count": 0,
      "statuses_count": 0,
      "hide_collections": null,
      "emojis": [],
      "fields": []
    }
    """#

    /// An automated account, with no posts, nobody following and following nobody.
    static let robot = #"""
    {
      "id": "117417151897283606",
      "username": "fediqo_robot",
      "acct": "fediqo_robot",
      "display_name": "",
      "locked": false,
      "bot": true,
      "group": false,
      "note": "",
      "avatar": "https://mastodon.localhost/avatars/original/missing.png",
      "header": "https://mastodon.localhost/headers/original/missing.png",
      "followers_count": 0,
      "following_count": 0,
      "statuses_count": 0,
      "hide_collections": null,
      "emojis": [],
      "fields": []
    }
    """#

    /// Somebody who moved, and to whom.
    static let moved = #"""
    {
      "id": "117417151872460831",
      "username": "fediqo_moved",
      "acct": "fediqo_moved",
      "display_name": "",
      "locked": false,
      "bot": false,
      "discoverable": null,
      "indexable": false,
      "group": false,
      "created_at": "2026-10-10T00:00:00.000Z",
      "note": "",
      "url": "https://mastodon.localhost/@fediqo_moved",
      "uri": "https://mastodon.localhost/ap/users/117417151872460831",
      "avatar": "https://mastodon.localhost/avatars/original/missing.png",
      "avatar_static": "https://mastodon.localhost/avatars/original/missing.png",
      "avatar_description": "",
      "header": "https://mastodon.localhost/headers/original/missing.png",
      "header_static": "https://mastodon.localhost/headers/original/missing.png",
      "header_description": "",
      "followers_count": 0,
      "following_count": 0,
      "statuses_count": 0,
      "last_status_at": null,
      "hide_collections": null,
      "show_media": true,
      "show_media_replies": true,
      "show_featured": true,
      "noindex": false,
      "feature_approval": {
        "automatic": [],
        "manual": [],
        "current_user": "denied"
      },
      "moved": {
        "id": "117417151802177425",
        "username": "fediqo_person",
        "acct": "fediqo_person",
        "display_name": "Per :fediqo_mark: Son"
      },
      "emojis": [],
      "roles": [],
      "fields": []
    }
    """#

    /// A suspended account: who it was, and nothing it said.
    static let gone = #"""
    {
      "id": "117417151879639419",
      "username": "fediqo_gone",
      "acct": "fediqo_gone",
      "display_name": "",
      "locked": false,
      "bot": false,
      "discoverable": false,
      "indexable": false,
      "group": false,
      "created_at": "2026-10-10T00:00:00.000Z",
      "note": "",
      "url": "https://mastodon.localhost/@fediqo_gone",
      "uri": "https://mastodon.localhost/ap/users/117417151879639419",
      "avatar": "https://mastodon.localhost/avatars/original/missing.png",
      "avatar_static": "https://mastodon.localhost/avatars/original/missing.png",
      "avatar_description": "",
      "header": "https://mastodon.localhost/headers/original/missing.png",
      "header_static": "https://mastodon.localhost/headers/original/missing.png",
      "header_description": "",
      "followers_count": 1,
      "following_count": 0,
      "statuses_count": 1,
      "last_status_at": "2026-10-10",
      "hide_collections": null,
      "show_media": true,
      "show_media_replies": true,
      "show_featured": true,
      "suspended": true,
      "noindex": false,
      "feature_approval": {
        "automatic": [],
        "manual": [],
        "current_user": "denied"
      },
      "emojis": [],
      "roles": [],
      "fields": []
    }
    """#

    /// An account this server limits.
    static let limited = #"""
    {
      "id": "117417151888632041",
      "username": "fediqo_limited",
      "acct": "fediqo_limited",
      "display_name": "",
      "locked": false,
      "bot": false,
      "group": false,
      "note": "",
      "avatar": "https://mastodon.localhost/avatars/original/missing.png",
      "header": "https://mastodon.localhost/headers/original/missing.png",
      "followers_count": 0,
      "following_count": 0,
      "statuses_count": 0,
      "hide_collections": null,
      "limited": true,
      "emojis": [],
      "fields": []
    }
    """#

    /// Nobody of that handle, or of that id: `404`, and this.
    static let missing = #"{"error":"Record not found"}"#

    /// One stretch of a list as it came: its body, and its `Link` header where it sent one.
    struct Stretch {
        let body: String
        let link: String?
    }

    /// The id the seed's person is listed under, and the ids their eight followers are, newest
    /// follow first: the two who live elsewhere, the one who hides their lists, and five more.
    static let personID = "117417151802177425"
    static let followerIDs = ["117417151911024455", "117417151906965812", "117417151865995738", "117417151846712450", "117417151840160634", "117417151829378362", "117417151822900697", "117417151817219450"]

    /// `GET /api/v1/accounts/:id/followers?limit=2`, read on by each answer's own next until one
    /// named none: four stretches of two, and a fifth with nobody.
    static let followers = [
        Stretch(body: #"""
        [
          {
            "id": "117417151911024455",
            "username": "far_hidden",
            "acct": "far_hidden@elsewhere.example",
            "display_name": "Far Hidden",
            "locked": false,
            "bot": false,
            "group": false,
            "note": "",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "header": "https://mastodon.localhost/headers/original/missing.png",
            "followers_count": 77,
            "following_count": 55,
            "statuses_count": 33,
            "hide_collections": true,
            "emojis": [],
            "fields": []
          },
          {
            "id": "117417151906965812",
            "username": "far",
            "acct": "far@elsewhere.example",
            "display_name": "Far :far_mark: Away",
            "locked": false,
            "bot": false,
            "group": false,
            "note": "<p>Lives elsewhere :far_mark:</p>",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "header": "https://mastodon.localhost/headers/original/missing.png",
            "followers_count": 2811,
            "following_count": 310,
            "statuses_count": 1204,
            "hide_collections": null,
            "emojis": [
              {
                "shortcode": "far_mark",
                "url": "https://mastodon.localhost/system/cache/custom_emojis/images/000/000/002/original/7497236a04d8578d.png",
                "static_url": "https://mastodon.localhost/system/cache/custom_emojis/images/000/000/002/static/7497236a04d8578d.png",
                "visible_in_picker": true
              }
            ],
            "fields": [
              {
                "name": "Home",
                "value": "<a href=\"https://elsewhere.example/far\" rel=\"nofollow noopener\" target=\"_blank\">elsewhere.example/far</a>",
                "verified_at": null
              }
            ]
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&max_id=19>; rel="next", <https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&since_id=21>; rel="prev""#),
        Stretch(body: #"""
        [
          {
            "id": "117417151865995738",
            "username": "fediqo_hidden",
            "acct": "fediqo_hidden",
            "display_name": "",
            "locked": false,
            "bot": false,
            "group": false,
            "note": "",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "header": "https://mastodon.localhost/headers/original/missing.png",
            "followers_count": 2,
            "following_count": 1,
            "statuses_count": 1,
            "hide_collections": true,
            "emojis": [],
            "fields": []
          },
          {
            "id": "117417151846712450",
            "username": "fediqo_fan_5",
            "acct": "fediqo_fan_5",
            "display_name": "",
            "locked": false,
            "bot": false,
            "group": false,
            "note": "",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "header": "https://mastodon.localhost/headers/original/missing.png",
            "followers_count": 0,
            "following_count": 1,
            "statuses_count": 0,
            "hide_collections": null,
            "emojis": [],
            "fields": []
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&max_id=7>; rel="next", <https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&since_id=14>; rel="prev""#),
        Stretch(body: #"""
        [
          {
            "id": "117417151840160634",
            "username": "fediqo_fan_4",
            "acct": "fediqo_fan_4",
            "display_name": "",
            "locked": false,
            "bot": false,
            "group": false,
            "note": "",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "header": "https://mastodon.localhost/headers/original/missing.png",
            "followers_count": 0,
            "following_count": 1,
            "statuses_count": 0,
            "hide_collections": null,
            "emojis": [],
            "fields": []
          },
          {
            "id": "117417151829378362",
            "username": "fediqo_fan_3",
            "acct": "fediqo_fan_3",
            "display_name": "",
            "locked": false,
            "bot": false,
            "group": false,
            "note": "",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "header": "https://mastodon.localhost/headers/original/missing.png",
            "followers_count": 1,
            "following_count": 1,
            "statuses_count": 0,
            "hide_collections": null,
            "emojis": [],
            "fields": []
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&max_id=5>; rel="next", <https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&since_id=6>; rel="prev""#),
        Stretch(body: #"""
        [
          {
            "id": "117417151822900697",
            "username": "fediqo_fan_2",
            "acct": "fediqo_fan_2",
            "display_name": "",
            "locked": false,
            "bot": false,
            "group": false,
            "note": "",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "header": "https://mastodon.localhost/headers/original/missing.png",
            "followers_count": 1,
            "following_count": 3,
            "statuses_count": 0,
            "hide_collections": null,
            "emojis": [],
            "fields": []
          },
          {
            "id": "117417151817219450",
            "username": "fediqo_fan_1",
            "acct": "fediqo_fan_1",
            "display_name": "",
            "locked": false,
            "bot": false,
            "group": false,
            "note": "",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "header": "https://mastodon.localhost/headers/original/missing.png",
            "followers_count": 1,
            "following_count": 6,
            "statuses_count": 0,
            "hide_collections": null,
            "emojis": [],
            "fields": []
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&max_id=3>; rel="next", <https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&since_id=4>; rel="prev""#),
        Stretch(body: #"""
        []
        """#, link: nil),
    ]

    /// `GET /api/v1/accounts/:id/following`, with no length asked for: all four, and a `Link` that names only
    /// what is newer.
    static let following = Stretch(body: #"""
    [
      {
        "id": "117417151556960776",
        "username": "fediqo_other",
        "acct": "fediqo_other",
        "display_name": "",
        "locked": false,
        "bot": false,
        "group": false,
        "note": "",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "header": "https://mastodon.localhost/headers/original/missing.png",
        "followers_count": 2,
        "following_count": 0,
        "statuses_count": 8,
        "hide_collections": null,
        "emojis": [],
        "fields": []
      },
      {
        "id": "117417151829378362",
        "username": "fediqo_fan_3",
        "acct": "fediqo_fan_3",
        "display_name": "",
        "locked": false,
        "bot": false,
        "group": false,
        "note": "",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "header": "https://mastodon.localhost/headers/original/missing.png",
        "followers_count": 1,
        "following_count": 1,
        "statuses_count": 0,
        "hide_collections": null,
        "emojis": [],
        "fields": []
      },
      {
        "id": "117417151822900697",
        "username": "fediqo_fan_2",
        "acct": "fediqo_fan_2",
        "display_name": "",
        "locked": false,
        "bot": false,
        "group": false,
        "note": "",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "header": "https://mastodon.localhost/headers/original/missing.png",
        "followers_count": 1,
        "following_count": 3,
        "statuses_count": 0,
        "hide_collections": null,
        "emojis": [],
        "fields": []
      },
      {
        "id": "117417151817219450",
        "username": "fediqo_fan_1",
        "acct": "fediqo_fan_1",
        "display_name": "",
        "locked": false,
        "bot": false,
        "group": false,
        "note": "",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "header": "https://mastodon.localhost/headers/original/missing.png",
        "followers_count": 1,
        "following_count": 6,
        "statuses_count": 0,
        "hide_collections": null,
        "emojis": [],
        "fields": []
      }
    ]
    """#, link: #"<https://mastodon.localhost/api/v1/accounts/117417151802177425/following?since_id=11>; rel="prev""#)

    /// Either list of somebody who hides them, of somebody with nobody, of a suspended account and of
    /// somebody who blocks the reader: `200`, no `Link`, and this — the same from each.
    static let nobodyListed = #"[]"#

    /// The first two stretches of the same followers asked as a reader who blocks one of them and mutes
    /// another: the second stretch is still two long, without those two.
    static let followersSignedIn = [
        Stretch(body: #"""
        [
          {
            "id": "117417151911024455",
            "username": "far_hidden",
            "acct": "far_hidden@elsewhere.example",
            "display_name": "Far Hidden"
          },
          {
            "id": "117417151906965812",
            "username": "far",
            "acct": "far@elsewhere.example",
            "display_name": "Far :far_mark: Away"
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&max_id=19>; rel="next", <https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&since_id=21>; rel="prev""#),
        Stretch(body: #"""
        [
          {
            "id": "117417151865995738",
            "username": "fediqo_hidden",
            "acct": "fediqo_hidden",
            "display_name": ""
          },
          {
            "id": "117417151829378362",
            "username": "fediqo_fan_3",
            "acct": "fediqo_fan_3",
            "display_name": ""
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&max_id=5>; rel="next", <https://mastodon.localhost/api/v1/accounts/117417151802177425/followers?limit=2&since_id=14>; rel="prev""#),
    ]

    /// `GET /api/v1/accounts/:id/statuses?limit=3`, read on by each answer's own next: three, three and
    /// two — a boost first, an answer, and six posts of their own.
    static let posts = [
        Stretch(body: #"""
        [
          {
            "id": "117417151809415268",
            "created_at": "2026-10-10T14:45:51.779Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "public",
            "language": null,
            "uri": "https://mastodon.localhost/ap/users/117417151802177425/statuses/117417151809415268/activity",
            "url": "https://mastodon.localhost/users/fediqo_person/statuses/117417151809415268/activity",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 0,
            "edited_at": null,
            "content": "",
            "reblog": {
              "id": "117417151563393736",
              "created_at": "2026-10-10T14:45:48.025Z",
              "in_reply_to_id": null,
              "sensitive": false,
              "spoiler_text": "",
              "visibility": "public",
              "language": "en",
              "uri": "https://mastodon.localhost/ap/users/117417151556960776/statuses/117417151563393736",
              "url": "https://mastodon.localhost/@fediqo_other/117417151563393736",
              "replies_count": 0,
              "reblogs_count": 1,
              "favourites_count": 0,
              "edited_at": null,
              "content": "<p>fediqo298seed plain</p>",
              "reblog": null,
              "account": {
                "id": "117417151556960776",
                "username": "fediqo_other",
                "acct": "fediqo_other",
                "display_name": "",
                "avatar": "https://mastodon.localhost/avatars/original/missing.png",
                "emojis": []
              },
              "media_attachments": [],
              "mentions": [],
              "emojis": [],
              "quote": null
            },
            "account": {
              "id": "117417151802177425",
              "username": "fediqo_person",
              "acct": "fediqo_person",
              "display_name": "Per :fediqo_mark: Son",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": [
                {
                  "shortcode": "fediqo_mark",
                  "url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/adb2dc4e93fe6cab.png",
                  "static_url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/adb2dc4e93fe6cab.png",
                  "visible_in_picker": true
                }
              ]
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          },
          {
            "id": "117417151808635667",
            "created_at": "2026-10-10T14:45:51.767Z",
            "in_reply_to_id": "117417151804136795",
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "unlisted",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117417151802177425/statuses/117417151808635667",
            "url": "https://mastodon.localhost/@fediqo_person/117417151808635667",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 0,
            "edited_at": null,
            "content": "<p>fediqo309seed answering</p>",
            "reblog": null,
            "account": {
              "id": "117417151802177425",
              "username": "fediqo_person",
              "acct": "fediqo_person",
              "display_name": "Per :fediqo_mark: Son",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": [
                {
                  "shortcode": "fediqo_mark",
                  "url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/adb2dc4e93fe6cab.png",
                  "static_url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/adb2dc4e93fe6cab.png",
                  "visible_in_picker": true
                }
              ]
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          },
          {
            "id": "117417151807144931",
            "created_at": "2026-10-10T14:45:51.744Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "public",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117417151802177425/statuses/117417151807144931",
            "url": "https://mastodon.localhost/@fediqo_person/117417151807144931",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 0,
            "edited_at": null,
            "content": "<p>fediqo309seed in public :fediqo_mark:</p>",
            "reblog": null,
            "account": {
              "id": "117417151802177425",
              "username": "fediqo_person",
              "acct": "fediqo_person",
              "display_name": "Per :fediqo_mark: Son",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": [
                {
                  "shortcode": "fediqo_mark",
                  "url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/adb2dc4e93fe6cab.png",
                  "static_url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/adb2dc4e93fe6cab.png",
                  "visible_in_picker": true
                }
              ]
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [
              {
                "shortcode": "fediqo_mark",
                "url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/adb2dc4e93fe6cab.png",
                "static_url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/adb2dc4e93fe6cab.png",
                "visible_in_picker": true
              }
            ],
            "quote": null
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117417151802177425/statuses?limit=3&max_id=117417151807144931>; rel="next", <https://mastodon.localhost/api/v1/accounts/117417151802177425/statuses?limit=3&min_id=117417151809415268>; rel="prev""#),
        Stretch(body: #"""
        [
          {
            "id": "117417151806675949",
            "created_at": "2026-10-10T14:45:51.736Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "unlisted",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117417151802177425/statuses/117417151806675949",
            "url": "https://mastodon.localhost/@fediqo_person/117417151806675949",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 0,
            "edited_at": null,
            "content": "<p>fediqo309seed post 05</p>",
            "reblog": null,
            "account": {
              "id": "117417151802177425",
              "username": "fediqo_person",
              "acct": "fediqo_person",
              "display_name": "Per :fediqo_mark: Son",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": [
                {
                  "shortcode": "fediqo_mark",
                  "url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/adb2dc4e93fe6cab.png",
                  "static_url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/adb2dc4e93fe6cab.png",
                  "visible_in_picker": true
                }
              ]
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          },
          {
            "id": "117417151806152424",
            "created_at": "2026-10-10T14:45:51.728Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "unlisted",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117417151802177425/statuses/117417151806152424",
            "url": "https://mastodon.localhost/@fediqo_person/117417151806152424",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 0,
            "edited_at": null,
            "content": "<p>fediqo309seed post 04</p>",
            "reblog": null,
            "account": {
              "id": "117417151802177425",
              "username": "fediqo_person",
              "acct": "fediqo_person",
              "display_name": "Per :fediqo_mark: Son",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": [
                {
                  "shortcode": "fediqo_mark",
                  "url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/adb2dc4e93fe6cab.png",
                  "static_url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/adb2dc4e93fe6cab.png",
                  "visible_in_picker": true
                }
              ]
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          },
          {
            "id": "117417151805516092",
            "created_at": "2026-10-10T14:45:51.719Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "unlisted",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117417151802177425/statuses/117417151805516092",
            "url": "https://mastodon.localhost/@fediqo_person/117417151805516092",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 0,
            "edited_at": null,
            "content": "<p>fediqo309seed post 03</p>",
            "reblog": null,
            "account": {
              "id": "117417151802177425",
              "username": "fediqo_person",
              "acct": "fediqo_person",
              "display_name": "Per :fediqo_mark: Son",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": [
                {
                  "shortcode": "fediqo_mark",
                  "url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/adb2dc4e93fe6cab.png",
                  "static_url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/adb2dc4e93fe6cab.png",
                  "visible_in_picker": true
                }
              ]
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117417151802177425/statuses?limit=3&max_id=117417151805516092>; rel="next", <https://mastodon.localhost/api/v1/accounts/117417151802177425/statuses?limit=3&min_id=117417151806675949>; rel="prev""#),
        Stretch(body: #"""
        [
          {
            "id": "117417151804850707",
            "created_at": "2026-10-10T14:45:51.709Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "unlisted",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117417151802177425/statuses/117417151804850707",
            "url": "https://mastodon.localhost/@fediqo_person/117417151804850707",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 0,
            "edited_at": null,
            "content": "<p>fediqo309seed post 02</p>",
            "reblog": null,
            "account": {
              "id": "117417151802177425",
              "username": "fediqo_person",
              "acct": "fediqo_person",
              "display_name": "Per :fediqo_mark: Son",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": [
                {
                  "shortcode": "fediqo_mark",
                  "url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/adb2dc4e93fe6cab.png",
                  "static_url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/adb2dc4e93fe6cab.png",
                  "visible_in_picker": true
                }
              ]
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          },
          {
            "id": "117417151804136795",
            "created_at": "2026-10-10T14:45:51.698Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "unlisted",
            "language": "en",
            "uri": "https://mastodon.localhost/ap/users/117417151802177425/statuses/117417151804136795",
            "url": "https://mastodon.localhost/@fediqo_person/117417151804136795",
            "replies_count": 1,
            "reblogs_count": 0,
            "favourites_count": 0,
            "edited_at": null,
            "content": "<p>fediqo309seed post 01</p>",
            "reblog": null,
            "account": {
              "id": "117417151802177425",
              "username": "fediqo_person",
              "acct": "fediqo_person",
              "display_name": "Per :fediqo_mark: Son",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": [
                {
                  "shortcode": "fediqo_mark",
                  "url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/original/adb2dc4e93fe6cab.png",
                  "static_url": "https://mastodon.localhost/system/custom_emojis/images/000/000/001/static/adb2dc4e93fe6cab.png",
                  "visible_in_picker": true
                }
              ]
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null
          }
        ]
        """#, link: #"<https://mastodon.localhost/api/v1/accounts/117417151802177425/statuses?limit=3&min_id=117417151804850707>; rel="prev""#),
    ]

    /// What the first stretch's `rel="prev"` brings when nothing newer was written: `200`, no `Link`.
    static let newerThanTheNewest = #"[]"#

    /// `GET /api/v1/accounts/relationships?id[]=…` as the writer, with every scope: the person, somebody the
    /// writer blocks, somebody they mute, somebody who blocks them, somebody living elsewhere, somebody who
    /// hides their lists, somebody locked whom the writer asked to follow — and no entry for the suspended
    /// account or for the id nobody has, both of which were asked.
    static let standing = #"""
    [
      {
        "id": "117417151802177425",
        "following": false,
        "showing_reblogs": false,
        "notifying": false,
        "languages": null,
        "followed_by": false,
        "blocking": false,
        "blocked_by": false,
        "muting": false,
        "muting_notifications": false,
        "muting_expires_at": null,
        "requested": false,
        "requested_by": false,
        "domain_blocking": false,
        "endorsed": false,
        "note": ""
      },
      {
        "id": "117417151840160634",
        "following": false,
        "showing_reblogs": false,
        "notifying": false,
        "languages": null,
        "followed_by": false,
        "blocking": true,
        "blocked_by": false,
        "muting": false,
        "muting_notifications": false,
        "muting_expires_at": null,
        "requested": false,
        "requested_by": false,
        "domain_blocking": false,
        "endorsed": false,
        "note": ""
      },
      {
        "id": "117417151846712450",
        "following": false,
        "showing_reblogs": false,
        "notifying": false,
        "languages": null,
        "followed_by": false,
        "blocking": false,
        "blocked_by": false,
        "muting": true,
        "muting_notifications": true,
        "muting_expires_at": null,
        "requested": false,
        "requested_by": false,
        "domain_blocking": false,
        "endorsed": false,
        "note": ""
      },
      {
        "id": "117417151858808174",
        "following": false,
        "showing_reblogs": true,
        "notifying": false,
        "languages": null,
        "followed_by": false,
        "blocking": false,
        "blocked_by": false,
        "muting": false,
        "muting_notifications": false,
        "muting_expires_at": null,
        "requested": true,
        "requested_by": false,
        "domain_blocking": false,
        "endorsed": false,
        "note": ""
      },
      {
        "id": "117417151865995738",
        "following": false,
        "showing_reblogs": false,
        "notifying": false,
        "languages": null,
        "followed_by": false,
        "blocking": false,
        "blocked_by": false,
        "muting": false,
        "muting_notifications": false,
        "muting_expires_at": null,
        "requested": false,
        "requested_by": false,
        "domain_blocking": false,
        "endorsed": false,
        "note": ""
      },
      {
        "id": "117417151903758667",
        "following": false,
        "showing_reblogs": false,
        "notifying": false,
        "languages": null,
        "followed_by": false,
        "blocking": false,
        "blocked_by": true,
        "muting": false,
        "muting_notifications": false,
        "muting_expires_at": null,
        "requested": false,
        "requested_by": false,
        "domain_blocking": false,
        "endorsed": false,
        "note": ""
      },
      {
        "id": "117417151906965812",
        "following": false,
        "showing_reblogs": false,
        "notifying": false,
        "languages": null,
        "followed_by": false,
        "blocking": false,
        "blocked_by": false,
        "muting": false,
        "muting_notifications": false,
        "muting_expires_at": null,
        "requested": false,
        "requested_by": false,
        "domain_blocking": false,
        "endorsed": false,
        "note": ""
      }
    ]
    """#

    /// The same of three the seed had already made: somebody the writer follows who asked to follow them
    /// back, somebody who follows the writer, and the writer themself.
    static let standingKnown = #"""
    [
      {
        "id": "117417151556960776",
        "following": true,
        "showing_reblogs": true,
        "notifying": false,
        "languages": null,
        "followed_by": false,
        "blocking": false,
        "blocked_by": false,
        "muting": false,
        "muting_notifications": false,
        "muting_expires_at": null,
        "requested": false,
        "requested_by": true,
        "domain_blocking": false,
        "endorsed": false,
        "note": ""
      },
      {
        "id": "117417151579604944",
        "following": false,
        "showing_reblogs": false,
        "notifying": false,
        "languages": null,
        "followed_by": true,
        "blocking": false,
        "blocked_by": false,
        "muting": false,
        "muting_notifications": false,
        "muting_expires_at": null,
        "requested": false,
        "requested_by": false,
        "domain_blocking": false,
        "endorsed": false,
        "note": ""
      },
      {
        "id": "117417151529278907",
        "following": false,
        "showing_reblogs": false,
        "notifying": false,
        "languages": null,
        "followed_by": false,
        "blocking": false,
        "blocked_by": false,
        "muting": false,
        "muting_notifications": false,
        "muting_expires_at": null,
        "requested": false,
        "requested_by": false,
        "domain_blocking": false,
        "endorsed": false,
        "note": ""
      }
    ]
    """#

    /// Asked with the scopes this app reads by and no `read:follows`: `403`, this, and the header beside it.
    static let standingRefused = #"{"error":"This action is outside the authorized scopes"}"#

    static let standingRefusedHeader = #"Bearer realm="Doorkeeper", error="insufficient_scope", error_description="Access to this resource requires scope _read read:follows_.""#

    /// Asked with no sign-in, or a token that is none: `401`, and this.
    static let standingUnsigned = #"{"error":"The access token is invalid"}"#

    // MARK: - Asked in a second window

    // The same day, of a server seeded afresh — so the ids below are that server's, and not the
    // ones above. Three things were made by hand in it for these asks and are in no seed: the
    // writer followed `fediqo_fan_1`, who follows `fediqo_person`; `fediqo_person` featured the
    // hashtag `fediqo309`; and eighty-five more accounts of `elsewhere.example` followed them.
    //
    // | Asked | Answered |
    // | ----- | -------- |
    // | the people the reader follows who follow somebody (`familiar_followers?id[]=`) | one entry an id asked, each with its `accounts`; **none for an id nobody has**, and nobody listed for an account that hides its lists or has no followers. No sign-in: 401. The app's reading scopes: 403 `insufficient_scope … requires scope _read read:follows_`, as `relationships` is; with `read:follows`, 200 |
    // | the hashtags somebody features (`accounts/:id/featured_tags`) | given to anyone. `statuses_count` is a **string**, `last_status_at` a day or null, `url` the person's own page of that hashtag. Nobody featuring any, and a suspended account: `200 []`. An id nobody has: 404 |
    // | how long a stretch may be asked | followers and following: 40 where none is asked, and **80 at most** — `limit=80`, `81` and `500` each bring 80, and the `Link` echoes the length asked, not the one given. A person's posts: 20 where none is asked, 40 at most. `limit=0` and `limit=abc` are answered **500**, with a page of the server's own and no JSON |

    /// `GET /api/v1/accounts/familiar_followers?id[]=…` as the writer, asked of the person, of somebody
    /// who hides their lists, of an automated account with no followers, and of an id nobody has.
    static let familiarFollowers = #"""
    [
      {
        "id": "117417230662667983",
        "accounts": [
          {
            "id": "117417230678747306",
            "username": "fediqo_fan_1",
            "acct": "fediqo_fan_1",
            "display_name": "",
            "locked": false,
            "bot": false,
            "group": false,
            "note": "",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "header": "https://mastodon.localhost/headers/original/missing.png",
            "followers_count": 2,
            "following_count": 6,
            "statuses_count": 0,
            "hide_collections": null,
            "emojis": [],
            "fields": []
          }
        ]
      },
      {
        "id": "117417230720019112",
        "accounts": []
      },
      {
        "id": "117417230750907580",
        "accounts": []
      }
    ]
    """#
    /// `GET /api/v1/accounts/:id/featured_tags`, of the person.
    static let featuredTags = #"""
    [
      {
        "id": "1",
        "name": "fediqo309",
        "url": "https://mastodon.localhost/@fediqo_person/tagged/fediqo309",
        "statuses_count": "0",
        "last_status_at": null
      }
    ]
    """#
    /// How many people one stretch of the person's ninety-three followers brought, by the length asked;
    /// nothing asked is 40.
    static let stretchLengths = ["": 40, "80": 80, "81": 80, "500": 80]
    /// And how many posts one stretch of the writer's posts brought: nothing asked is 20.
    static let postStretchLengths = ["": 20, "40": 40, "41": 40, "100": 40]
}
