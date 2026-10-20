import Foundation

/// A copy of the core suite's captures of the same name — test targets share no files — for the
/// shell's checks of a poll. Mastodon statuses that carry a poll (#331), and a vote's answer, **in the shape Mastodon 4.x
/// sends them** — the `Poll` entity's fields, names and nulls as a 4.6 server writes them inside
/// `GET /api/v1/statuses/:id` and as the whole answer to `POST /api/v1/polls/:id/votes`.
///
/// **Written by hand from that shape, not captured**: no Mastodon image was on this machine to
/// bring up (`servers/compose.yml` pins 4.6.6), so where these differ from a real answer the
/// difference is this file's. What they hold to is what the shape says: `voted` and `own_votes`
/// absent on a read made signed out, a choice's `votes_count` `null` while a poll that keeps its
/// figures back has not ended, `voters_count` a figure on a poll of several choices, `poll: null`
/// on a status with none. The accounts are made up and the host is the fixtures' own.
enum MastodonPollCaptures {
    /// A status around `poll`, read as `ada`'s post on `social.example`.
    static func status(id: String = "9", poll: String, edited: String? = nil, content: String = "<p>Which one?</p>") -> String {
        let edit = edited.map { #""\#($0)""# } ?? "null"
        return """
        {
          "id": "\(id)",
          "created_at": "2026-10-19T08:00:00.000Z",
          "in_reply_to_id": null,
          "sensitive": false,
          "spoiler_text": "",
          "visibility": "public",
          "language": "en",
          "uri": "https://social.example/users/ada/statuses/\(id)",
          "url": "https://social.example/@ada/\(id)",
          "replies_count": 0,
          "reblogs_count": 1,
          "favourites_count": 2,
          "edited_at": \(edit),
          "content": "\(content)",
          "reblog": null,
          "application": {"name": "Web", "website": null},
          "account": {
            "id": "1",
            "username": "ada",
            "acct": "ada",
            "display_name": "Ada",
            "url": "https://social.example/@ada",
            "avatar": "https://social.example/avatars/original/missing.png",
            "emojis": []
          },
          "media_attachments": [],
          "mentions": [],
          "tags": [],
          "emojis": [],
          "card": null,
          "poll": \(poll)
        }
        """
    }

    /// One choice of three, open until 2036-10-20 08:00 (far enough that no run of these checks meets it), read signed in by somebody who has not
    /// voted: `voted` false, `own_votes` empty, every figure said.
    static let open = """
    {
      "id": "34830",
      "expires_at": "2036-10-20T08:00:00.000Z",
      "expired": false,
      "multiple": false,
      "votes_count": 10,
      "voters_count": 10,
      "voted": false,
      "own_votes": [],
      "options": [
        {"title": "Tea", "votes_count": 6},
        {"title": "Coffee", "votes_count": 3},
        {"title": "Water", "votes_count": 1}
      ],
      "emojis": []
    }
    """

    /// The same poll read signed out: no `voted`, no `own_votes`.
    static let signedOut = """
    {
      "id": "34830",
      "expires_at": "2036-10-20T08:00:00.000Z",
      "expired": false,
      "multiple": false,
      "votes_count": 10,
      "voters_count": 10,
      "options": [
        {"title": "Tea", "votes_count": 6},
        {"title": "Coffee", "votes_count": 3},
        {"title": "Water", "votes_count": 1}
      ],
      "emojis": []
    }
    """

    /// The answer to a vote for "Coffee": the poll, voted, and its figures with the vote in.
    static let votedCoffee = """
    {
      "id": "34830",
      "expires_at": "2036-10-20T08:00:00.000Z",
      "expired": false,
      "multiple": false,
      "votes_count": 11,
      "voters_count": 11,
      "voted": true,
      "own_votes": [1],
      "options": [
        {"title": "Tea", "votes_count": 6},
        {"title": "Coffee", "votes_count": 4},
        {"title": "Water", "votes_count": 1}
      ],
      "emojis": []
    }
    """

    /// Several choices, the figures kept back until it ends: each choice's `votes_count` null,
    /// the poll's own count said, voted by the reader for the first and the third.
    static let hiddenMany = """
    {
      "id": "40001",
      "expires_at": "2036-10-26T08:00:00.000Z",
      "expired": false,
      "multiple": true,
      "votes_count": 7,
      "voters_count": 4,
      "voted": true,
      "own_votes": [0, 2],
      "options": [
        {"title": "Mon", "votes_count": null},
        {"title": "Wed", "votes_count": null},
        {"title": "Fri", "votes_count": null}
      ],
      "emojis": []
    }
    """

    /// Ended a week before, never voted in by the reader.
    static let ended = """
    {
      "id": "50002",
      "expires_at": "2026-10-12T08:00:00.000Z",
      "expired": true,
      "multiple": false,
      "votes_count": 3,
      "voters_count": 3,
      "voted": false,
      "own_votes": [],
      "options": [
        {"title": "Yes", "votes_count": 2},
        {"title": "No", "votes_count": 1}
      ],
      "emojis": []
    }
    """

    /// A shape no Mastodon sends: a figure as a word, choices as a string. No poll, and the
    /// status around it still reads.
    static let garbled = #"{"id": "1", "votes_count": "many", "options": "Tea, Coffee"}"#

    /// A poll the author changed: the same id, its choices worded anew, its votes started again.
    static let reworded = """
    {
      "id": "34830",
      "expires_at": "2036-10-20T08:00:00.000Z",
      "expired": false,
      "multiple": false,
      "votes_count": 0,
      "voters_count": 0,
      "voted": false,
      "own_votes": [],
      "options": [
        {"title": "Green tea", "votes_count": 0},
        {"title": "Black coffee", "votes_count": 0}
      ],
      "emojis": []
    }
    """

    /// The instance document's `configuration`, as a 4.6 server writes it, polls beside media.
    static let instance = """
    {
      "domain": "social.example",
      "configuration": {
        "statuses": {"max_characters": 500, "max_media_attachments": 4, "characters_reserved_per_url": 23},
        "media_attachments": {"supported_mime_types": ["image/png"], "image_size_limit": 16777216, "description_limit": 1500},
        "polls": {"max_options": 6, "max_characters_per_option": 80, "min_expiration": 300, "max_expiration": 604800}
      }
    }
    """
}
