import Foundation

/// Mastodon statuses that quote another (#214), **as a real server sent them** — the Mastodon 4.6.6
/// image `servers/compose.yml` pins, brought up alone under its own compose project, with three
/// local accounts (`ada`, `bob`, `cyd`) seeded by a Rails runner and the posts made through
/// `POST /api/v1/statuses` with `quoted_status_id`. Fetched with `curl` on 2026-09-24 through
/// `GET /api/v1/statuses/:id`, signed out unless a case says otherwise; the server was then
/// thrown away.
///
/// **Trimmed, not edited.** Each status keeps the fields a note is read from, in the order the
/// server wrote them; an account keeps who and which picture, and the rest of it is cut. No token
/// and nobody real is in here: the accounts are the seed's, the host the local `mastodon.localhost`.
enum MastodonQuoteCaptures {
    /// Bob quoting Ada, read signed out: `accepted`, the quoted status in full, its own `quote` null.
    static let accepted = #"""
    {
      "id": "117322970522996496",
      "created_at": "2026-09-23T23:34:19.396Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://mastodon.localhost/ap/users/117322968547282932/statuses/117322970522996496",
      "url": "https://mastodon.localhost/@bob/117322970522996496",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "quotes_count": 1,
      "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@ada/117322969977080442\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@ada/117322</span><span class=\"invisible\">969977080442</span></a></p><p>Bob says this is worth reading</p>",
      "reblog": null,
      "account": {
        "id": "117322968547282932",
        "username": "bob",
        "acct": "bob",
        "display_name": "",
        "url": "https://mastodon.localhost/@bob",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": {
        "state": "accepted",
        "quoted_status": {
          "id": "117322969977080442",
          "created_at": "2026-09-23T23:34:11.088Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "uri": "https://mastodon.localhost/ap/users/117322968517380917/statuses/117322969977080442",
          "url": "https://mastodon.localhost/@ada/117322969977080442",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "quotes_count": 3,
          "content": "<p>The first post, by Ada</p>",
          "reblog": null,
          "account": {
            "id": "117322968517380917",
            "username": "ada",
            "acct": "ada",
            "display_name": "",
            "url": "https://mastodon.localhost/@ada",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null,
          "quote_approval": {
            "automatic": [
              "public"
            ],
            "manual": [],
            "current_user": "denied"
          }
        }
      },
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "denied"
      }
    }
    """#

    /// Cyd quoting Bob's quote of Ada: `accepted`, and inside the quoted status its own quote a level
    /// down as a `ShallowQuote` — a state and `quoted_status_id` alone.
    static let nested = #"""
    {
      "id": "117322971113679563",
      "created_at": "2026-09-23T23:34:28.409Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://mastodon.localhost/ap/users/117322968555383283/statuses/117322971113679563",
      "url": "https://mastodon.localhost/@cyd/117322971113679563",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "quotes_count": 0,
      "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@bob/117322970522996496\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@bob/117322</span><span class=\"invisible\">970522996496</span></a></p><p>Cyd quotes the quote</p>",
      "reblog": null,
      "account": {
        "id": "117322968555383283",
        "username": "cyd",
        "acct": "cyd",
        "display_name": "",
        "url": "https://mastodon.localhost/@cyd",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": {
        "state": "accepted",
        "quoted_status": {
          "id": "117322970522996496",
          "created_at": "2026-09-23T23:34:19.396Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "uri": "https://mastodon.localhost/ap/users/117322968547282932/statuses/117322970522996496",
          "url": "https://mastodon.localhost/@bob/117322970522996496",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "quotes_count": 1,
          "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@ada/117322969977080442\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@ada/117322</span><span class=\"invisible\">969977080442</span></a></p><p>Bob says this is worth reading</p>",
          "reblog": null,
          "account": {
            "id": "117322968547282932",
            "username": "bob",
            "acct": "bob",
            "display_name": "",
            "url": "https://mastodon.localhost/@bob",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": {
            "state": "accepted",
            "quoted_status_id": "117322969977080442"
          },
          "quote_approval": {
            "automatic": [
              "public"
            ],
            "manual": [],
            "current_user": "denied"
          }
        }
      },
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "denied"
      }
    }
    """#

    /// Bob quoting a post Ada covered — `sensitive`, a spoiler line, and an image with its alt text.
    static let covered = #"""
    {
      "id": "117322972364417825",
      "created_at": "2026-09-23T23:34:47.494Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://mastodon.localhost/ap/users/117322968547282932/statuses/117322972364417825",
      "url": "https://mastodon.localhost/@bob/117322972364417825",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "quotes_count": 0,
      "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@ada/117322971960695428\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@ada/117322</span><span class=\"invisible\">971960695428</span></a></p><p>Bob quotes a covered post</p>",
      "reblog": null,
      "account": {
        "id": "117322968547282932",
        "username": "bob",
        "acct": "bob",
        "display_name": "",
        "url": "https://mastodon.localhost/@bob",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": {
        "state": "accepted",
        "quoted_status": {
          "id": "117322971960695428",
          "created_at": "2026-09-23T23:34:41.333Z",
          "in_reply_to_id": null,
          "sensitive": true,
          "spoiler_text": "A spoiler",
          "visibility": "public",
          "uri": "https://mastodon.localhost/ap/users/117322968517380917/statuses/117322971960695428",
          "url": "https://mastodon.localhost/@ada/117322971960695428",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "quotes_count": 1,
          "content": "<p>Under the cover</p>",
          "reblog": null,
          "account": {
            "id": "117322968517380917",
            "username": "ada",
            "acct": "ada",
            "display_name": "",
            "url": "https://mastodon.localhost/@ada",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [
            {
              "id": "117322971645585166",
              "type": "image",
              "url": "https://mastodon.localhost/system/media_attachments/files/117/322/971/645/585/166/original/15236f003fee2cae.png",
              "preview_url": "https://mastodon.localhost/system/media_attachments/files/117/322/971/645/585/166/small/15236f003fee2cae.png",
              "description": "A red square",
              "meta": {
                "original": {
                  "width": 16,
                  "height": 16,
                  "size": "16x16",
                  "aspect": 1.0
                },
                "small": {
                  "width": 16,
                  "height": 16,
                  "size": "16x16",
                  "aspect": 1.0
                }
              }
            }
          ],
          "mentions": [],
          "emojis": [],
          "quote": null,
          "quote_approval": {
            "automatic": [
              "public"
            ],
            "manual": [],
            "current_user": "denied"
          }
        }
      },
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "denied"
      }
    }
    """#

    /// Ada boosting Bob's quote: the quote rides on the boosted status (`reblog.quote`).
    static let boost = #"""
    {
      "id": "117322981371207485",
      "created_at": "2026-09-23T23:37:04.927Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://mastodon.localhost/ap/users/117322968517380917/statuses/117322981371207485/activity",
      "url": "https://mastodon.localhost/users/ada/statuses/117322981371207485/activity",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "quotes_count": 0,
      "content": "",
      "reblog": {
        "id": "117322970522996496",
        "created_at": "2026-09-23T23:34:19.396Z",
        "in_reply_to_id": null,
        "sensitive": false,
        "spoiler_text": "",
        "visibility": "public",
        "uri": "https://mastodon.localhost/ap/users/117322968547282932/statuses/117322970522996496",
        "url": "https://mastodon.localhost/@bob/117322970522996496",
        "replies_count": 0,
        "reblogs_count": 1,
        "favourites_count": 0,
        "quotes_count": 1,
        "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@ada/117322969977080442\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@ada/117322</span><span class=\"invisible\">969977080442</span></a></p><p>Bob says this is worth reading</p>",
        "reblog": null,
        "account": {
          "id": "117322968547282932",
          "username": "bob",
          "acct": "bob",
          "display_name": "",
          "url": "https://mastodon.localhost/@bob",
          "avatar": "https://mastodon.localhost/avatars/original/missing.png",
          "emojis": []
        },
        "media_attachments": [],
        "mentions": [],
        "emojis": [],
        "quote": {
          "state": "accepted",
          "quoted_status": {
            "id": "117322969977080442",
            "created_at": "2026-09-23T23:34:11.088Z",
            "in_reply_to_id": null,
            "sensitive": false,
            "spoiler_text": "",
            "visibility": "public",
            "uri": "https://mastodon.localhost/ap/users/117322968517380917/statuses/117322969977080442",
            "url": "https://mastodon.localhost/@ada/117322969977080442",
            "replies_count": 0,
            "reblogs_count": 0,
            "favourites_count": 0,
            "quotes_count": 3,
            "content": "<p>The first post, by Ada</p>",
            "reblog": null,
            "account": {
              "id": "117322968517380917",
              "username": "ada",
              "acct": "ada",
              "display_name": "",
              "url": "https://mastodon.localhost/@ada",
              "avatar": "https://mastodon.localhost/avatars/original/missing.png",
              "emojis": []
            },
            "media_attachments": [],
            "mentions": [],
            "emojis": [],
            "quote": null,
            "quote_approval": {
              "automatic": [
                "public"
              ],
              "manual": [],
              "current_user": "denied"
            }
          }
        },
        "quote_approval": {
          "automatic": [
            "public"
          ],
          "manual": [],
          "current_user": "denied"
        }
      },
      "account": {
        "id": "117322968517380917",
        "username": "ada",
        "acct": "ada",
        "display_name": "",
        "url": "https://mastodon.localhost/@ada",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": null,
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "denied"
      }
    }
    """#

    /// A quote Ada has not answered: `pending`, `quoted_status` null. Set with `update_column` on a
    /// real quote row, since a local server settles a local quote at once.
    static let pending = #"""
    {
      "id": "117322976446535742",
      "created_at": "2026-09-23T23:35:49.782Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://mastodon.localhost/ap/users/117322968547282932/statuses/117322976446535742",
      "url": "https://mastodon.localhost/@bob/117322976446535742",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "quotes_count": 0,
      "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@ada/117322969977080442\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@ada/117322</span><span class=\"invisible\">969977080442</span></a></p><p>Bob quotes Ada, pending</p>",
      "reblog": null,
      "account": {
        "id": "117322968547282932",
        "username": "bob",
        "acct": "bob",
        "display_name": "",
        "url": "https://mastodon.localhost/@bob",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": {
        "state": "pending",
        "quoted_status": null
      },
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "denied"
      }
    }
    """#

    /// A quote Ada said no to: `rejected`, set as `pending` was.
    static let rejected = #"""
    {
      "id": "117322976451564188",
      "created_at": "2026-09-23T23:35:49.859Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://mastodon.localhost/ap/users/117322968547282932/statuses/117322976451564188",
      "url": "https://mastodon.localhost/@bob/117322976451564188",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "quotes_count": 0,
      "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@ada/117322969977080442\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@ada/117322</span><span class=\"invisible\">969977080442</span></a></p><p>Bob quotes Ada, rejected</p>",
      "reblog": null,
      "account": {
        "id": "117322968547282932",
        "username": "bob",
        "acct": "bob",
        "display_name": "",
        "url": "https://mastodon.localhost/@bob",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": {
        "state": "rejected",
        "quoted_status": null
      },
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "denied"
      }
    }
    """#

    /// A quote Ada allowed and took back (`POST /api/v1/statuses/:id/quotes/:quoting_id/revoke`):
    /// `revoked`, `quoted_status` null — and the `RE:` line still in the words.
    static let revoked = #"""
    {
      "id": "117322973139009739",
      "created_at": "2026-09-23T23:34:59.312Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://mastodon.localhost/ap/users/117322968547282932/statuses/117322973139009739",
      "url": "https://mastodon.localhost/@bob/117322973139009739",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "quotes_count": 0,
      "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@ada/117322972815116106\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@ada/117322</span><span class=\"invisible\">972815116106</span></a></p><p>Bob quotes a post whose author takes it back</p>",
      "reblog": null,
      "account": {
        "id": "117322968547282932",
        "username": "bob",
        "acct": "bob",
        "display_name": "",
        "url": "https://mastodon.localhost/@bob",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": {
        "state": "revoked",
        "quoted_status": null
      },
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "denied"
      }
    }
    """#

    /// A quote whose quoted post Ada deleted: `deleted`, `quoted_status` null.
    static let deleted = #"""
    {
      "id": "117322972792934258",
      "created_at": "2026-09-23T23:34:54.031Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://mastodon.localhost/ap/users/117322968547282932/statuses/117322972792934258",
      "url": "https://mastodon.localhost/@bob/117322972792934258",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "quotes_count": 0,
      "content": "<p>Bob quotes a post that goes</p>",
      "reblog": null,
      "account": {
        "id": "117322968547282932",
        "username": "bob",
        "acct": "bob",
        "display_name": "",
        "url": "https://mastodon.localhost/@bob",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": {
        "state": "deleted",
        "quoted_status": null
      },
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "denied"
      }
    }
    """#

    /// Bob quoting Ada's followers-only post, read signed out: `unauthorized`, `quoted_status` null.
    /// The quote row was written with validations off: the API refuses a public quote of a private post.
    static let unauthorized = #"""
    {
      "id": "117322976455725680",
      "created_at": "2026-09-23T23:35:49.922Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://mastodon.localhost/ap/users/117322968547282932/statuses/117322976455725680",
      "url": "https://mastodon.localhost/@bob/117322976455725680",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "quotes_count": 0,
      "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@ada/117322976454302238\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@ada/117322</span><span class=\"invisible\">976454302238</span></a></p><p>Bob quotes a post you may not see</p>",
      "reblog": null,
      "account": {
        "id": "117322968547282932",
        "username": "bob",
        "acct": "bob",
        "display_name": "",
        "url": "https://mastodon.localhost/@bob",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": {
        "state": "unauthorized",
        "quoted_status": null
      },
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "denied"
      }
    }
    """#

    /// Bob's quote of Ada, read by Cyd, who muted Ada: `muted_account` — **with the quoted status still
    /// sent in full**, which is why `Quote` keeps nothing of a quoted post whose state is not `accepted`.
    static let mutedAccount = #"""
    {
      "id": "117322970522996496",
      "created_at": "2026-09-23T23:34:19.396Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://mastodon.localhost/ap/users/117322968547282932/statuses/117322970522996496",
      "url": "https://mastodon.localhost/@bob/117322970522996496",
      "replies_count": 0,
      "reblogs_count": 1,
      "favourites_count": 0,
      "quotes_count": 1,
      "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@ada/117322969977080442\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@ada/117322</span><span class=\"invisible\">969977080442</span></a></p><p>Bob says this is worth reading</p>",
      "reblog": null,
      "account": {
        "id": "117322968547282932",
        "username": "bob",
        "acct": "bob",
        "display_name": "",
        "url": "https://mastodon.localhost/@bob",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": {
        "state": "muted_account",
        "quoted_status": {
          "id": "117322969977080442",
          "created_at": "2026-09-23T23:34:11.088Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "uri": "https://mastodon.localhost/ap/users/117322968517380917/statuses/117322969977080442",
          "url": "https://mastodon.localhost/@ada/117322969977080442",
          "replies_count": 0,
          "reblogs_count": 0,
          "favourites_count": 0,
          "quotes_count": 3,
          "content": "<p>The first post, by Ada</p>",
          "reblog": null,
          "account": {
            "id": "117322968517380917",
            "username": "ada",
            "acct": "ada",
            "display_name": "",
            "url": "https://mastodon.localhost/@ada",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null,
          "quote_approval": {
            "automatic": [
              "public"
            ],
            "manual": [],
            "current_user": "automatic"
          }
        }
      },
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "automatic"
      }
    }
    """#

    /// Cyd's quote of Bob's quote, read by Bob, who blocked Ada: the outer quote `accepted`, the inner
    /// one `blocked_account` with its id.
    static let blockedAccount = #"""
    {
      "id": "117322971113679563",
      "created_at": "2026-09-23T23:34:28.409Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://mastodon.localhost/ap/users/117322968555383283/statuses/117322971113679563",
      "url": "https://mastodon.localhost/@cyd/117322971113679563",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 0,
      "quotes_count": 0,
      "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@bob/117322970522996496\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@bob/117322</span><span class=\"invisible\">970522996496</span></a></p><p>Cyd quotes the quote</p>",
      "reblog": null,
      "account": {
        "id": "117322968555383283",
        "username": "cyd",
        "acct": "cyd",
        "display_name": "",
        "url": "https://mastodon.localhost/@cyd",
        "avatar": "https://mastodon.localhost/avatars/original/missing.png",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": {
        "state": "accepted",
        "quoted_status": {
          "id": "117322970522996496",
          "created_at": "2026-09-23T23:34:19.396Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "uri": "https://mastodon.localhost/ap/users/117322968547282932/statuses/117322970522996496",
          "url": "https://mastodon.localhost/@bob/117322970522996496",
          "replies_count": 0,
          "reblogs_count": 1,
          "favourites_count": 0,
          "quotes_count": 1,
          "content": "<p class=\"quote-inline\">RE: <a href=\"https://mastodon.localhost/@ada/117322969977080442\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">mastodon.localhost/@ada/117322</span><span class=\"invisible\">969977080442</span></a></p><p>Bob says this is worth reading</p>",
          "reblog": null,
          "account": {
            "id": "117322968547282932",
            "username": "bob",
            "acct": "bob",
            "display_name": "",
            "url": "https://mastodon.localhost/@bob",
            "avatar": "https://mastodon.localhost/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": {
            "state": "blocked_account",
            "quoted_status_id": "117322969977080442"
          },
          "quote_approval": {
            "automatic": [
              "public"
            ],
            "manual": [],
            "current_user": "automatic"
          }
        }
      },
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "automatic"
      }
    }
    """#

    /// A public quote post on g0v.social (Mastodon 4.7.2), as the reader's own app met it: read
    /// signed out through `GET /api/v1/statuses/117322759665402925` on 2026-09-24 and trimmed as
    /// the rest are. `accepted`, the quoted status in full, and the `RE:` line ahead of the words.
    static let g0v = #"""
    {
      "id": "117322759665402925",
      "created_at": "2026-09-23T22:40:41.965Z",
      "in_reply_to_id": null,
      "sensitive": false,
      "spoiler_text": "",
      "visibility": "public",
      "uri": "https://g0v.social/users/wancw/statuses/117322759665402925",
      "url": "https://g0v.social/@wancw/117322759665402925",
      "replies_count": 0,
      "reblogs_count": 0,
      "favourites_count": 4,
      "quotes_count": 0,
      "content": "<p class=\"quote-inline\">RE: <a href=\"https://g0v.social/@wancw/117277361887436248\" target=\"_blank\" rel=\"nofollow noopener\" translate=\"no\"><span class=\"invisible\">https://</span><span class=\"ellipsis\">g0v.social/@wancw/117277361887</span><span class=\"invisible\">436248</span></a></p><p>這週上班日四天。請了一天假，剩下三天都是騎腳踏車上班。</p><p>似乎有愈來愈輕鬆？ 🤔</p>",
      "reblog": null,
      "account": {
        "id": "108995399780066355",
        "username": "wancw",
        "acct": "wancw",
        "display_name": "寫 code 求生的鼯鼠 🦊",
        "url": "https://g0v.social/@wancw",
        "avatar": "https://objects.g0v.social/accounts/avatars/108/995/399/780/066/355/original/8ff80e3de3d4e45e.jpeg",
        "emojis": []
      },
      "media_attachments": [],
      "mentions": [],
      "emojis": [],
      "quote": {
        "state": "accepted",
        "quoted_status": {
          "id": "117277361887436248",
          "created_at": "2026-09-15T22:15:26.847Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "uri": "https://g0v.social/users/wancw/statuses/117277361887436248",
          "url": "https://g0v.social/@wancw/117277361887436248",
          "replies_count": 3,
          "reblogs_count": 0,
          "favourites_count": 14,
          "quotes_count": 1,
          "content": "<p>騎 YouBike 到公司，跟搭公車的時間差不多。但我大腿快不行了……我已經是騎電動輔助的了。 Orz</p>",
          "reblog": null,
          "account": {
            "id": "108995399780066355",
            "username": "wancw",
            "acct": "wancw",
            "display_name": "寫 code 求生的鼯鼠 🦊",
            "url": "https://g0v.social/@wancw",
            "avatar": "https://objects.g0v.social/accounts/avatars/108/995/399/780/066/355/original/8ff80e3de3d4e45e.jpeg",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "emojis": [],
          "quote": null,
          "quote_approval": {
            "automatic": [
              "public"
            ],
            "manual": [],
            "current_user": "denied"
          }
        }
      },
      "quote_approval": {
        "automatic": [
          "public"
        ],
        "manual": [],
        "current_user": "denied"
      }
    }
    """#
}
