import Foundation

/// What the same real Mastodon 4.6.6 answered when its notices were **acted on**, and asked what
/// it was holding back (#323) — the server, the three accounts and the day `MastodonNoticeCaptures`
/// says, as `fediqo`, with a token that reads notices and one that also acts on them.
///
/// What had happened: `fediqo` told the server to hold back notices from people it does not
/// follow, and `fediqo_third` then mentioned it — one request, of one notice.
///
/// **Trimmed, not edited**, by the rule the reads were: the request is whole, its post and its
/// person keep what a note and a person are read from.
extension MastodonNoticeCaptures {
    /// Every act that went through — dismissing a notice or a gathered line, dismissing all,
    /// letting a request through, letting one go: `200`, and this. **Also** a gathered line that
    /// never existed (`…/favourite-1-1/dismiss`).
    static let done = "{}"

    /// A single notice dismissed a second time: `404`, and this.
    static let gone = #"{"error":"Record not found"}"#

    /// `GET /api/v2/notifications/policy` on a fresh account: nothing waiting.
    static let policy = #"""
    {
      "for_not_following": "accept",
      "for_not_followers": "accept",
      "for_new_accounts": "accept",
      "for_private_mentions": "filter",
      "for_limited_accounts": "filter",
      "for_bots": "accept",
      "summary": {
        "pending_requests_count": 0,
        "pending_notifications_count": 0
      }
    }
    """#

    /// The same, once one mention had been held back.
    static let policyHolding = #"""
    {
      "for_not_following": "filter",
      "for_not_followers": "accept",
      "for_new_accounts": "accept",
      "for_private_mentions": "filter",
      "for_limited_accounts": "filter",
      "for_bots": "accept",
      "summary": {
        "pending_requests_count": 1,
        "pending_notifications_count": 1
      }
    }
    """#

    /// `GET /api/v1/notifications/requests` with nothing held, and again after the one request
    /// was let through or let go.
    static let noRequests = "[]"

    /// `GET /api/v1/notifications/requests` with that one mention held. `notifications_count`
    /// is a string.
    static let requests = #"""
    [
      {
        "id": "117402380222400467",
        "created_at": "2026-10-08T00:09:15.260Z",
        "updated_at": "2026-10-08T00:09:15.260Z",
        "notifications_count": "1",
        "account": {
          "id": "117402374895127898",
          "username": "fediqo_third",
          "acct": "fediqo_third",
          "display_name": "",
          "url": "https://mastodon.localhost/@fediqo_third",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "last_status": {
          "id": "117402379855948870",
          "created_at": "2026-10-08T00:09:09.659Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://mastodon.localhost/ap/users/117402374895127898/statuses/117402379855948870",
          "url": "https://mastodon.localhost/@fediqo_third/117402379855948870",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "edited_at": null,
          "favourited": false,
          "reblogged": false,
          "bookmarked": false,
          "content": "<p><span class=\"h-card\" translate=\"no\"><a href=\"https://mastodon.localhost/@fediqo\" class=\"u-url mention\">@<span>fediqo</span></a></span> a mention that should be held back</p>",
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
      }
    ]
    """#
}
