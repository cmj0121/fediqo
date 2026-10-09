import Foundation

/// A Mastodon's notices (#323), **as a real server sent them** — the Mastodon 4.6.6 image
/// `servers/compose.yml` pins, brought up with `make servers`, with three local accounts
/// (`fediqo`, whose notices these are, `fediqo_other` and `fediqo_third`) acting on one another
/// through the API and the queued notification jobs run by hand, since `servers/` runs no
/// worker. Fetched with `curl` on 2026-10-08 as `fediqo`, with a token that reads notices; the
/// server was then thrown away.
///
/// What had happened, oldest first: `fediqo_third` asked to follow (1); `fediqo_other` followed
/// (3); both boosted (4, 7) and both favoured (5, 6) `fediqo`'s first post; a poll of `fediqo`'s
/// ended (8); `fediqo_other` answered that first post (9) and `fediqo_third` mentioned `fediqo`
/// (10); a post of `fediqo_other`'s that `fediqo` had boosted was changed (11). The quote (14)
/// was made later, after the notices above were cleared.
///
/// **Trimmed, not edited.** Each line and each notice is whole. A post keeps the fields a note
/// is read from, in the order the server wrote them; a person keeps who and which picture, and
/// the rest of both is cut. No token and nobody real is in here: the accounts are the seed's,
/// the host the local `mastodon.localhost`.
enum MastodonNoticeCaptures {
    static let host = "mastodon.localhost"

    /// Both reads asked past the last notice: `200`, and nothing.
    static let gatheredPastTheEnd = #"{"accounts":[],"statuses":[],"notification_groups":[]}"#
    static let singlePastTheEnd = "[]"

    /// Either read asked with a token that was never asked for notices: `403`, and this.
    static let outsideScope = #"{"error":"This action is outside the authorized scopes"}"#

    /// `GET /api/v2/notifications`: eight lines, the people and the posts beside them. The boosts and the
    /// favourites stand for two notices each; `most_recent_notification_id` is a number where the page's
    /// ids are strings.
    static let gathered = #"""
    {
      "accounts": [
        {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        {
          "id": "117402374895127898",
          "username": "fediqo_third",
          "acct": "fediqo_third",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_third",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        {
          "id": "117402373959322312",
          "username": "fediqo",
          "acct": "fediqo",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        }
      ],
      "statuses": [
        {
          "id": "117402373993370914",
          "created_at": "2026-10-08T00:07:40.201Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373986097681/statuses/117402373993370914",
          "url": "https://mastodon.localhost/@fediqo_other/117402373993370914",
          "replies_count": 0,
          "reblogs_count": 1,
          "favourites_count": 0,
          "edited_at": "2026-10-08T00:08:10.678Z",
          "favourited": false,
          "reblogged": true,
          "bookmarked": false,
          "content": "<p>fediqo298seed plain, now changed</p>",
          "reblog": null,
          "account": {
            "id": "117402373986097681",
            "username": "fediqo_other",
            "acct": "fediqo_other",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_other",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        },
        {
          "id": "117402375948153967",
          "created_at": "2026-10-08T00:08:10.033Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402374895127898/statuses/117402375948153967",
          "url": "https://mastodon.localhost/@fediqo_third/117402375948153967",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p><span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo\" class=\"u-url mention\">@<span>fediqo</span></a></span> a mention from a third person</p>",
          "reblog": null,
          "account": {
            "id": "117402374895127898",
            "username": "fediqo_third",
            "acct": "fediqo_third",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_third",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [
            {
              "id": "117402373959322312",
              "username": "fediqo",
              "url": "https://mastodon.localhost/@fediqo",
              "acct": "fediqo"
            }
          ],
          "emojis": [],
          "quote": null
        },
        {
          "id": "117402375936869384",
          "created_at": "2026-10-08T00:08:09.860Z",
          "in_reply_to_id": "117402373970258685",
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373986097681/statuses/117402375936869384",
          "url": "https://mastodon.localhost/@fediqo_other/117402375936869384",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p><span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo\" class=\"u-url mention\">@<span>fediqo</span></a></span> an answer to the first note</p>",
          "reblog": null,
          "account": {
            "id": "117402373986097681",
            "username": "fediqo_other",
            "acct": "fediqo_other",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_other",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [
            {
              "id": "117402373959322312",
              "username": "fediqo",
              "url": "https://mastodon.localhost/@fediqo",
              "acct": "fediqo"
            }
          ],
          "emojis": [],
          "quote": null
        },
        {
          "id": "117402375997909609",
          "created_at": "2026-10-08T00:08:10.788Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402375997909609",
          "url": "https://mastodon.localhost/@fediqo/117402375997909609",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>a poll</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        },
        {
          "id": "117402373970258685",
          "created_at": "2026-10-08T00:07:39.863Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402373970258685",
          "url": "https://mastodon.localhost/@fediqo/117402373970258685",
          "replies_count": 1,
          "reblogs_count": 2,
          "favourites_count": 2,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>A public note on this machine</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      ],
      "notification_groups": [
        {
          "group_key": "ungrouped-11",
          "notifications_count": 1,
          "type": "update",
          "most_recent_notification_id": 11,
          "page_min_id": "11",
          "page_max_id": "11",
          "latest_page_notification_at": "2026-10-08T00:08:16.886Z",
          "sample_account_ids": [
            "117402373986097681"
          ],
          "status_id": "117402373993370914"
        },
        {
          "group_key": "ungrouped-10",
          "notifications_count": 1,
          "type": "mention",
          "most_recent_notification_id": 10,
          "page_min_id": "10",
          "page_max_id": "10",
          "latest_page_notification_at": "2026-10-08T00:08:16.868Z",
          "sample_account_ids": [
            "117402374895127898"
          ],
          "status_id": "117402375948153967"
        },
        {
          "group_key": "ungrouped-9",
          "notifications_count": 1,
          "type": "mention",
          "most_recent_notification_id": 9,
          "page_min_id": "9",
          "page_max_id": "9",
          "latest_page_notification_at": "2026-10-08T00:08:16.857Z",
          "sample_account_ids": [
            "117402373986097681"
          ],
          "status_id": "117402375936869384"
        },
        {
          "group_key": "ungrouped-8",
          "notifications_count": 1,
          "type": "poll",
          "most_recent_notification_id": 8,
          "page_min_id": "8",
          "page_max_id": "8",
          "latest_page_notification_at": "2026-10-08T00:08:16.801Z",
          "sample_account_ids": [
            "117402373959322312"
          ],
          "status_id": "117402375997909609"
        },
        {
          "group_key": "reblog-117402373970258685-497616",
          "notifications_count": 2,
          "type": "reblog",
          "most_recent_notification_id": 7,
          "page_min_id": "4",
          "page_max_id": "7",
          "latest_page_notification_at": "2026-10-08T00:08:15.934Z",
          "sample_account_ids": [
            "117402373986097681",
            "117402374895127898"
          ],
          "status_id": "117402373970258685"
        },
        {
          "group_key": "favourite-117402373970258685-497616",
          "notifications_count": 2,
          "type": "favourite",
          "most_recent_notification_id": 6,
          "page_min_id": "5",
          "page_max_id": "6",
          "latest_page_notification_at": "2026-10-08T00:08:15.896Z",
          "sample_account_ids": [
            "117402373986097681",
            "117402374895127898"
          ],
          "status_id": "117402373970258685"
        },
        {
          "group_key": "follow-497616",
          "notifications_count": 1,
          "type": "follow",
          "most_recent_notification_id": 3,
          "page_min_id": "3",
          "page_max_id": "3",
          "latest_page_notification_at": "2026-10-08T00:08:15.688Z",
          "sample_account_ids": [
            "117402373986097681"
          ]
        },
        {
          "group_key": "ungrouped-1",
          "notifications_count": 1,
          "type": "follow_request",
          "most_recent_notification_id": 1,
          "page_min_id": "1",
          "page_max_id": "1",
          "latest_page_notification_at": "2026-10-08T00:08:15.143Z",
          "sample_account_ids": [
            "117402374895127898"
          ]
        }
      ]
    }
    """#

    /// `GET /api/v1/notifications`, the same ten notices one by one: the person and the post inside each.
    static let single = #"""
    [
      {
        "id": "11",
        "type": "update",
        "created_at": "2026-10-08T00:08:16.886Z",
        "group_key": "ungrouped-11",
        "account": {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402373993370914",
          "created_at": "2026-10-08T00:07:40.201Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373986097681/statuses/117402373993370914",
          "url": "https://mastodon.localhost/@fediqo_other/117402373993370914",
          "replies_count": 0,
          "reblogs_count": 1,
          "favourites_count": 0,
          "edited_at": "2026-10-08T00:08:10.678Z",
          "favourited": false,
          "reblogged": true,
          "bookmarked": false,
          "content": "<p>fediqo298seed plain, now changed</p>",
          "reblog": null,
          "account": {
            "id": "117402373986097681",
            "username": "fediqo_other",
            "acct": "fediqo_other",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_other",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "10",
        "type": "mention",
        "created_at": "2026-10-08T00:08:16.868Z",
        "group_key": "ungrouped-10",
        "account": {
          "id": "117402374895127898",
          "username": "fediqo_third",
          "acct": "fediqo_third",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_third",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402375948153967",
          "created_at": "2026-10-08T00:08:10.033Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402374895127898/statuses/117402375948153967",
          "url": "https://mastodon.localhost/@fediqo_third/117402375948153967",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p><span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo\" class=\"u-url mention\">@<span>fediqo</span></a></span> a mention from a third person</p>",
          "reblog": null,
          "account": {
            "id": "117402374895127898",
            "username": "fediqo_third",
            "acct": "fediqo_third",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_third",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [
            {
              "id": "117402373959322312",
              "username": "fediqo",
              "url": "https://mastodon.localhost/@fediqo",
              "acct": "fediqo"
            }
          ],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "9",
        "type": "mention",
        "created_at": "2026-10-08T00:08:16.857Z",
        "group_key": "ungrouped-9",
        "account": {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402375936869384",
          "created_at": "2026-10-08T00:08:09.860Z",
          "in_reply_to_id": "117402373970258685",
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373986097681/statuses/117402375936869384",
          "url": "https://mastodon.localhost/@fediqo_other/117402375936869384",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p><span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo\" class=\"u-url mention\">@<span>fediqo</span></a></span> an answer to the first note</p>",
          "reblog": null,
          "account": {
            "id": "117402373986097681",
            "username": "fediqo_other",
            "acct": "fediqo_other",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_other",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [
            {
              "id": "117402373959322312",
              "username": "fediqo",
              "url": "https://mastodon.localhost/@fediqo",
              "acct": "fediqo"
            }
          ],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "8",
        "type": "poll",
        "created_at": "2026-10-08T00:08:16.801Z",
        "group_key": "ungrouped-8",
        "account": {
          "id": "117402373959322312",
          "username": "fediqo",
          "acct": "fediqo",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402375997909609",
          "created_at": "2026-10-08T00:08:10.788Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402375997909609",
          "url": "https://mastodon.localhost/@fediqo/117402375997909609",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>a poll</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "7",
        "type": "reblog",
        "created_at": "2026-10-08T00:08:15.934Z",
        "group_key": "reblog-117402373970258685-497616",
        "account": {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402373970258685",
          "created_at": "2026-10-08T00:07:39.863Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402373970258685",
          "url": "https://mastodon.localhost/@fediqo/117402373970258685",
          "replies_count": 1,
          "reblogs_count": 2,
          "favourites_count": 2,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>A public note on this machine</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "6",
        "type": "favourite",
        "created_at": "2026-10-08T00:08:15.896Z",
        "group_key": "favourite-117402373970258685-497616",
        "account": {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402373970258685",
          "created_at": "2026-10-08T00:07:39.863Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402373970258685",
          "url": "https://mastodon.localhost/@fediqo/117402373970258685",
          "replies_count": 1,
          "reblogs_count": 2,
          "favourites_count": 2,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>A public note on this machine</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "5",
        "type": "favourite",
        "created_at": "2026-10-08T00:08:15.886Z",
        "group_key": "favourite-117402373970258685-497616",
        "account": {
          "id": "117402374895127898",
          "username": "fediqo_third",
          "acct": "fediqo_third",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_third",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402373970258685",
          "created_at": "2026-10-08T00:07:39.863Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402373970258685",
          "url": "https://mastodon.localhost/@fediqo/117402373970258685",
          "replies_count": 1,
          "reblogs_count": 2,
          "favourites_count": 2,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>A public note on this machine</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "4",
        "type": "reblog",
        "created_at": "2026-10-08T00:08:15.711Z",
        "group_key": "reblog-117402373970258685-497616",
        "account": {
          "id": "117402374895127898",
          "username": "fediqo_third",
          "acct": "fediqo_third",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_third",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402373970258685",
          "created_at": "2026-10-08T00:07:39.863Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402373970258685",
          "url": "https://mastodon.localhost/@fediqo/117402373970258685",
          "replies_count": 1,
          "reblogs_count": 2,
          "favourites_count": 2,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>A public note on this machine</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "3",
        "type": "follow",
        "created_at": "2026-10-08T00:08:15.688Z",
        "group_key": "follow-497616",
        "account": {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        }
      },
      {
        "id": "1",
        "type": "follow_request",
        "created_at": "2026-10-08T00:08:15.143Z",
        "group_key": "ungrouped-1",
        "account": {
          "id": "117402374895127898",
          "username": "fediqo_third",
          "acct": "fediqo_third",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_third",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        }
      }
    ]
    """#

    /// `GET /api/v2/notifications?limit=3`: the newest stretch.
    static let gatheredNewest = #"""
    {
      "accounts": [
        {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        {
          "id": "117402374895127898",
          "username": "fediqo_third",
          "acct": "fediqo_third",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_third",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        }
      ],
      "statuses": [
        {
          "id": "117402373993370914",
          "created_at": "2026-10-08T00:07:40.201Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373986097681/statuses/117402373993370914",
          "url": "https://mastodon.localhost/@fediqo_other/117402373993370914",
          "replies_count": 0,
          "reblogs_count": 1,
          "favourites_count": 0,
          "edited_at": "2026-10-08T00:08:10.678Z",
          "favourited": false,
          "reblogged": true,
          "bookmarked": false,
          "content": "<p>fediqo298seed plain, now changed</p>",
          "reblog": null,
          "account": {
            "id": "117402373986097681",
            "username": "fediqo_other",
            "acct": "fediqo_other",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_other",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        },
        {
          "id": "117402375948153967",
          "created_at": "2026-10-08T00:08:10.033Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402374895127898/statuses/117402375948153967",
          "url": "https://mastodon.localhost/@fediqo_third/117402375948153967",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p><span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo\" class=\"u-url mention\">@<span>fediqo</span></a></span> a mention from a third person</p>",
          "reblog": null,
          "account": {
            "id": "117402374895127898",
            "username": "fediqo_third",
            "acct": "fediqo_third",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_third",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [
            {
              "id": "117402373959322312",
              "username": "fediqo",
              "url": "https://mastodon.localhost/@fediqo",
              "acct": "fediqo"
            }
          ],
          "emojis": [],
          "quote": null
        },
        {
          "id": "117402375936869384",
          "created_at": "2026-10-08T00:08:09.860Z",
          "in_reply_to_id": "117402373970258685",
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373986097681/statuses/117402375936869384",
          "url": "https://mastodon.localhost/@fediqo_other/117402375936869384",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p><span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo\" class=\"u-url mention\">@<span>fediqo</span></a></span> an answer to the first note</p>",
          "reblog": null,
          "account": {
            "id": "117402373986097681",
            "username": "fediqo_other",
            "acct": "fediqo_other",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_other",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [
            {
              "id": "117402373959322312",
              "username": "fediqo",
              "url": "https://mastodon.localhost/@fediqo",
              "acct": "fediqo"
            }
          ],
          "emojis": [],
          "quote": null
        }
      ],
      "notification_groups": [
        {
          "group_key": "ungrouped-11",
          "notifications_count": 1,
          "type": "update",
          "most_recent_notification_id": 11,
          "page_min_id": "11",
          "page_max_id": "11",
          "latest_page_notification_at": "2026-10-08T00:08:16.886Z",
          "sample_account_ids": [
            "117402373986097681"
          ],
          "status_id": "117402373993370914"
        },
        {
          "group_key": "ungrouped-10",
          "notifications_count": 1,
          "type": "mention",
          "most_recent_notification_id": 10,
          "page_min_id": "10",
          "page_max_id": "10",
          "latest_page_notification_at": "2026-10-08T00:08:16.868Z",
          "sample_account_ids": [
            "117402374895127898"
          ],
          "status_id": "117402375948153967"
        },
        {
          "group_key": "ungrouped-9",
          "notifications_count": 1,
          "type": "mention",
          "most_recent_notification_id": 9,
          "page_min_id": "9",
          "page_max_id": "9",
          "latest_page_notification_at": "2026-10-08T00:08:16.857Z",
          "sample_account_ids": [
            "117402373986097681"
          ],
          "status_id": "117402375936869384"
        }
      ]
    }
    """#

    /// `…?limit=3&max_id=9`: the next. The boosts and the favourites each say they are two, and reach
    /// only the newer of the two (`page_min_id` 7, and 6).
    static let gatheredOlder = #"""
    {
      "accounts": [
        {
          "id": "117402373959322312",
          "username": "fediqo",
          "acct": "fediqo",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        {
          "id": "117402374895127898",
          "username": "fediqo_third",
          "acct": "fediqo_third",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_third",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        }
      ],
      "statuses": [
        {
          "id": "117402375997909609",
          "created_at": "2026-10-08T00:08:10.788Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402375997909609",
          "url": "https://mastodon.localhost/@fediqo/117402375997909609",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>a poll</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        },
        {
          "id": "117402373970258685",
          "created_at": "2026-10-08T00:07:39.863Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402373970258685",
          "url": "https://mastodon.localhost/@fediqo/117402373970258685",
          "replies_count": 1,
          "reblogs_count": 2,
          "favourites_count": 2,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>A public note on this machine</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      ],
      "notification_groups": [
        {
          "group_key": "ungrouped-8",
          "notifications_count": 1,
          "type": "poll",
          "most_recent_notification_id": 8,
          "page_min_id": "8",
          "page_max_id": "8",
          "latest_page_notification_at": "2026-10-08T00:08:16.801Z",
          "sample_account_ids": [
            "117402373959322312"
          ],
          "status_id": "117402375997909609"
        },
        {
          "group_key": "reblog-117402373970258685-497616",
          "notifications_count": 2,
          "type": "reblog",
          "most_recent_notification_id": 7,
          "page_min_id": "7",
          "page_max_id": "7",
          "latest_page_notification_at": "2026-10-08T00:08:15.934Z",
          "sample_account_ids": [
            "117402373986097681",
            "117402374895127898"
          ],
          "status_id": "117402373970258685"
        },
        {
          "group_key": "favourite-117402373970258685-497616",
          "notifications_count": 2,
          "type": "favourite",
          "most_recent_notification_id": 6,
          "page_min_id": "6",
          "page_max_id": "6",
          "latest_page_notification_at": "2026-10-08T00:08:15.896Z",
          "sample_account_ids": [
            "117402373986097681",
            "117402374895127898"
          ],
          "status_id": "117402373970258685"
        }
      ]
    }
    """#

    /// `…?limit=3&max_id=6`: the one after. **The same two `group_key`s again**, each with the one notice
    /// the page before cut off.
    static let gatheredOldest = #"""
    {
      "accounts": [
        {
          "id": "117402374895127898",
          "username": "fediqo_third",
          "acct": "fediqo_third",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_third",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        }
      ],
      "statuses": [
        {
          "id": "117402373970258685",
          "created_at": "2026-10-08T00:07:39.863Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402373970258685",
          "url": "https://mastodon.localhost/@fediqo/117402373970258685",
          "replies_count": 1,
          "reblogs_count": 2,
          "favourites_count": 2,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>A public note on this machine</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      ],
      "notification_groups": [
        {
          "group_key": "favourite-117402373970258685-497616",
          "notifications_count": 1,
          "type": "favourite",
          "most_recent_notification_id": 5,
          "page_min_id": "5",
          "page_max_id": "5",
          "latest_page_notification_at": "2026-10-08T00:08:15.886Z",
          "sample_account_ids": [
            "117402374895127898"
          ],
          "status_id": "117402373970258685"
        },
        {
          "group_key": "reblog-117402373970258685-497616",
          "notifications_count": 1,
          "type": "reblog",
          "most_recent_notification_id": 4,
          "page_min_id": "4",
          "page_max_id": "4",
          "latest_page_notification_at": "2026-10-08T00:08:15.711Z",
          "sample_account_ids": [
            "117402374895127898"
          ],
          "status_id": "117402373970258685"
        },
        {
          "group_key": "follow-497616",
          "notifications_count": 1,
          "type": "follow",
          "most_recent_notification_id": 3,
          "page_min_id": "3",
          "page_max_id": "3",
          "latest_page_notification_at": "2026-10-08T00:08:15.688Z",
          "sample_account_ids": [
            "117402373986097681"
          ]
        }
      ]
    }
    """#

    /// `GET /api/v1/notifications?limit=3`.
    static let singleNewest = #"""
    [
      {
        "id": "11",
        "type": "update",
        "created_at": "2026-10-08T00:08:16.886Z",
        "group_key": "ungrouped-11",
        "account": {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402373993370914",
          "created_at": "2026-10-08T00:07:40.201Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373986097681/statuses/117402373993370914",
          "url": "https://mastodon.localhost/@fediqo_other/117402373993370914",
          "replies_count": 0,
          "reblogs_count": 1,
          "favourites_count": 0,
          "edited_at": "2026-10-08T00:08:10.678Z",
          "favourited": false,
          "reblogged": true,
          "bookmarked": false,
          "content": "<p>fediqo298seed plain, now changed</p>",
          "reblog": null,
          "account": {
            "id": "117402373986097681",
            "username": "fediqo_other",
            "acct": "fediqo_other",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_other",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "10",
        "type": "mention",
        "created_at": "2026-10-08T00:08:16.868Z",
        "group_key": "ungrouped-10",
        "account": {
          "id": "117402374895127898",
          "username": "fediqo_third",
          "acct": "fediqo_third",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_third",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402375948153967",
          "created_at": "2026-10-08T00:08:10.033Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402374895127898/statuses/117402375948153967",
          "url": "https://mastodon.localhost/@fediqo_third/117402375948153967",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p><span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo\" class=\"u-url mention\">@<span>fediqo</span></a></span> a mention from a third person</p>",
          "reblog": null,
          "account": {
            "id": "117402374895127898",
            "username": "fediqo_third",
            "acct": "fediqo_third",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_third",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [
            {
              "id": "117402373959322312",
              "username": "fediqo",
              "url": "https://mastodon.localhost/@fediqo",
              "acct": "fediqo"
            }
          ],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "9",
        "type": "mention",
        "created_at": "2026-10-08T00:08:16.857Z",
        "group_key": "ungrouped-9",
        "account": {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402375936869384",
          "created_at": "2026-10-08T00:08:09.860Z",
          "in_reply_to_id": "117402373970258685",
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373986097681/statuses/117402375936869384",
          "url": "https://mastodon.localhost/@fediqo_other/117402375936869384",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p><span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo\" class=\"u-url mention\">@<span>fediqo</span></a></span> an answer to the first note</p>",
          "reblog": null,
          "account": {
            "id": "117402373986097681",
            "username": "fediqo_other",
            "acct": "fediqo_other",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_other",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [
            {
              "id": "117402373959322312",
              "username": "fediqo",
              "url": "https://mastodon.localhost/@fediqo",
              "acct": "fediqo"
            }
          ],
          "emojis": [],
          "quote": null
        }
      }
    ]
    """#

    /// `…?limit=3&max_id=9`.
    static let singleOlder = #"""
    [
      {
        "id": "8",
        "type": "poll",
        "created_at": "2026-10-08T00:08:16.801Z",
        "group_key": "ungrouped-8",
        "account": {
          "id": "117402373959322312",
          "username": "fediqo",
          "acct": "fediqo",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402375997909609",
          "created_at": "2026-10-08T00:08:10.788Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402375997909609",
          "url": "https://mastodon.localhost/@fediqo/117402375997909609",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>a poll</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "7",
        "type": "reblog",
        "created_at": "2026-10-08T00:08:15.934Z",
        "group_key": "reblog-117402373970258685-497616",
        "account": {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402373970258685",
          "created_at": "2026-10-08T00:07:39.863Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402373970258685",
          "url": "https://mastodon.localhost/@fediqo/117402373970258685",
          "replies_count": 1,
          "reblogs_count": 2,
          "favourites_count": 2,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>A public note on this machine</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      },
      {
        "id": "6",
        "type": "favourite",
        "created_at": "2026-10-08T00:08:15.896Z",
        "group_key": "favourite-117402373970258685-497616",
        "account": {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402373970258685",
          "created_at": "2026-10-08T00:07:39.863Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402373970258685",
          "url": "https://mastodon.localhost/@fediqo/117402373970258685",
          "replies_count": 1,
          "reblogs_count": 2,
          "favourites_count": 2,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p>A public note on this machine</p>",
          "reblog": null,
          "account": {
            "id": "117402373959322312",
            "username": "fediqo",
            "acct": "fediqo",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null
        }
      }
    ]
    """#

    /// `GET /api/v2/notifications` once the second account had quoted the first's post: the line and its
    /// post, which is the quoting one.
    static let quoteGathered = #"""
    {
      "accounts": [
        {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        }
      ],
      "statuses": [
        {
          "id": "117402383687438886",
          "created_at": "2026-10-08T00:10:08.121Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373986097681/statuses/117402383687438886",
          "url": "https://mastodon.localhost/@fediqo_other/117402383687438886",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@fediqo/117402383675483420\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@fediqo/117</span><span class=\"invisible\">402383675483420</span></a></p><p>quoting a public note</p>",
          "reblog": null,
          "account": {
            "id": "117402373986097681",
            "username": "fediqo_other",
            "acct": "fediqo_other",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_other",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": {
            "state": "accepted",
            "quoted_status": {
              "id": "117402383675483420",
              "created_at": "2026-10-08T00:10:07.938Z",
              "in_reply_to_id": null,
              "sensitive": false,
              "spoiler_text": "",
              "visibility": "public",
              "language": "en",
              "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402383675483420",
              "url": "https://mastodon.localhost/@fediqo/117402383675483420",
              "replies_count": 0,
              "reblogs_count": 0,
              "favourites_count": 0,
              "edited_at": null,
              "favourited": false,
              "reblogged": false,
              "bookmarked": false,
              "content": "<p>a public note to be quoted</p>",
              "reblog": null,
              "account": {
                "id": "117402373959322312",
                "username": "fediqo",
                "acct": "fediqo",
                "display_name": "",
                "url": "https://mastodon.localhost/@fediqo",
                "avatar": "https://mastodon.localhost/avatars/original/missing.png",
                "emojis": []
              },
              "media_attachments": [],
              "mentions": [],
              "emojis": [],
              "quote": null
            }
          }
        }
      ],
      "notification_groups": [
        {
          "group_key": "ungrouped-14",
          "notifications_count": 1,
          "type": "quote",
          "most_recent_notification_id": 14,
          "page_min_id": "14",
          "page_max_id": "14",
          "latest_page_notification_at": "2026-10-08T00:10:12.692Z",
          "sample_account_ids": [
            "117402373986097681"
          ],
          "status_id": "117402383687438886"
        }
      ]
    }
    """#

    /// The same notice through `GET /api/v1/notifications`.
    static let quoteSingle = #"""
    [
      {
        "id": "14",
        "type": "quote",
        "created_at": "2026-10-08T00:10:12.692Z",
        "group_key": "ungrouped-14",
        "account": {
          "id": "117402373986097681",
          "username": "fediqo_other",
          "acct": "fediqo_other",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_other",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "status": {
          "id": "117402383687438886",
          "created_at": "2026-10-08T00:10:08.121Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402373986097681/statuses/117402383687438886",
          "url": "https://mastodon.localhost/@fediqo_other/117402383687438886",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@fediqo/117402383675483420\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@fediqo/117</span><span class=\"invisible\">402383675483420</span></a></p><p>quoting a public note</p>",
          "reblog": null,
          "account": {
            "id": "117402373986097681",
            "username": "fediqo_other",
            "acct": "fediqo_other",
            "display_name": "",
            "url": "https://mastodon.localhost/@fediqo_other",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": {
            "state": "accepted",
            "quoted_status": {
              "id": "117402383675483420",
              "created_at": "2026-10-08T00:10:07.938Z",
              "in_reply_to_id": null,
              "sensitive": false,
              "spoiler_text": "",
              "visibility": "public",
              "language": "en",
              "uri": "https://mastodon.localhost/ap/users/117402373959322312/statuses/117402383675483420",
              "url": "https://mastodon.localhost/@fediqo/117402383675483420",
              "replies_count": 0,
              "reblogs_count": 0,
              "favourites_count": 0,
              "edited_at": null,
              "favourited": false,
              "reblogged": false,
              "bookmarked": false,
              "content": "<p>a public note to be quoted</p>",
              "reblog": null,
              "account": {
                "id": "117402373959322312",
                "username": "fediqo",
                "acct": "fediqo",
                "display_name": "",
                "url": "https://mastodon.localhost/@fediqo",
                "avatar": "https://mastodon.localhost/avatars/original/missing.png",
                "emojis": []
              },
              "media_attachments": [],
              "mentions": [],
              "emojis": [],
              "quote": null
            }
          }
        }
      }
    ]
    """#
}
