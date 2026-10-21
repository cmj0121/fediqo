import Foundation

/// One's own post changed after it was published (#332), **as a real server sent it** — the
/// Mastodon 4.6.6 image `servers/compose.yml` pins — asked with the seed's writer (`fediqo`) and
/// its second person on 2026-10-21. Every post asked about was written for the asking and taken
/// back after it. `MastodonChangeSaysTests` asks the same again on every servers-unlocked run.
///
/// **Trimmed, not edited**: a status keeps the fields a note and a change are read from, and its
/// author is cut to who. No token and nobody real is in here.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Mastodon 4.6.6 |
/// | ----- | -------------- |
/// | `GET /statuses/:id/source` | **`id`, `text`, `spoiler_text` — nothing else**: the words as typed (`\n`, `@name` as written), the cover line, `""` for none. No language, sensitivity, media or poll: those are read off `GET /statuses/:id` |
/// | the same, by a sign-in that only reads, or by another person who may see the post | 200, the same answer: it is a read (`read:statuses`) |
/// | `GET /statuses/:id/history` of a post never changed | 200, **one entry**: the post as it is |
/// | the same after changes | one entry per wording, **the original first**, each `content` (HTML), `spoiler_text`, `sensitive`, `created_at` (when that wording began: the post's own time, then each `edited_at`), `media_attachments` (ids and descriptions then), `poll` (`options[].title` alone) where it had one, `account`, `emojis`. No language |
/// | `PUT /statuses/:id`, changed words, cover, language, sensitive, files | 200, the status as it now is, `edited_at` the moment of the change; the same id and poll id |
/// | the same with nothing different | 200, **no change**: `edited_at` stays `null`, history stays one entry |
/// | a file's description alone changed (`media_attributes[][id]` + `[description]`) | 200, a change: `edited_at` moves, a new history entry with the same words |
/// | a file left out of `media_ids[]` | taken off the post |
/// | `visibility` sent with the change | **passed over in silence**: 200, the visibility as it was |
/// | a poll sent beside media on a change | **200, taken** — which a new post is not; this app refuses it here as it refuses it on a new post |
/// | the poll left out of the change | **the poll taken off** (`poll: null`; the history keeps its choices) |
/// | the poll sent again as it was | votes kept, poll id kept — but **`expires_at` moves to the change's moment plus `expires_in`**: the run starts again |
/// | the run changed (`expires_in`) | votes kept |
/// | figures hidden (`hide_totals`) changed | votes kept |
/// | choices reordered · one reworded · one added · single became several | **every vote lost** (`votes_count` 0), poll id kept |
/// | `poll[multiple]` left out of the change, all else as it was | **every vote lost**: absent is not taken for "one" when it is compared |
/// | a poll already ended, sent again with `expires_in` 0 | 422 `Validation failed: Deadline is too soon` (`deadline`) |
/// | the same with a new run (3600) | 200, **the poll open again** (`expired` false, a new end), its votes kept: a change of a post can keep an ended poll only by opening it again |
/// | empty words; words over the limit | 422 `Validation failed: Text can't be blank`; 422 `Validation failed: Text character limit of 500 exceeded` |
/// | another person's post | **404** `{"error":"Record not found"}` — not 403 |
/// | by a sign-in without `write:statuses` | 403 `This action is outside the authorized scopes` |
/// | `source` / `history` of a post taken back | 404 `{"error":"Not Found"}` |
/// | the thirty-first post taken back by one account in half an hour | **429** `Too many requests`, `X-RateLimit-Limit: 30` — so the checks write one post each and take back no more |
enum MastodonChangeCaptures {
    static let host = "mastodon.localhost"
    static let statusID = "117476049082026876"

    /// `GET /api/v1/statuses/:id/source` of a post written with a line break and a cover line.
    static let source = #"{"id":"117476042627241864","text":"probe one @other line\ntwo","spoiler_text":"cw"}"#

    /// The same of a post with no cover line.
    static let sourceUncovered = #"{"id":"117476049082026876","text":"media probe","spoiler_text":""}"#

    /// `GET /api/v1/statuses/:id` of the post with two files, the second with no description.
    static let withMedia = status(
        content: "<p>media probe</p>", edited: nil, sensitive: false, language: "en",
        media: [("117476049068757210", "\"first alt\""), ("117476049076597848", "null")]
    )

    /// `PUT /api/v1/statuses/:id` with new words, French, sensitive, the first file left out and
    /// the second described: the answer.
    static let changed = status(
        content: "<p>media probe two</p>", edited: "2026-10-21T00:24:13.007Z", sensitive: true, language: "fr",
        media: [("117476049076597848", "\"second alt\"")]
    )

    /// `GET /api/v1/statuses/:id/history` after that change and one of a description alone.
    static let history = """
    [
      {"content":"<p>media probe</p>","spoiler_text":"","sensitive":false,"created_at":"2026-10-21T00:24:12.838Z",
       "account":{"id":"117476039616356918","username":"fediqo","acct":"fediqo","display_name":""},
       "media_attachments":[\(media("117476049068757210", "\"first alt\"")),\(media("117476049076597848", "null"))],"emojis":[]},
      {"content":"<p>media probe two</p>","spoiler_text":"","sensitive":true,"created_at":"2026-10-21T00:24:13.007Z",
       "account":{"id":"117476039616356918","username":"fediqo","acct":"fediqo","display_name":""},
       "media_attachments":[\(media("117476049076597848", "\"second alt\""))],"emojis":[]},
      {"content":"<p>media probe two</p>","spoiler_text":"","sensitive":true,"created_at":"2026-10-21T00:24:13.106Z",
       "account":{"id":"117476039616356918","username":"fediqo","acct":"fediqo","display_name":""},
       "media_attachments":[\(media("117476049076597848", "\"third alt\""))],"emojis":[]}
    ]
    """

    /// The same of a post never changed: one entry, the post as it is.
    static let historyUnchanged = """
    [{"content":"<p>probe one @other line<br />two</p>","spoiler_text":"cw","sensitive":true,"created_at":"2026-10-21T00:22:34.361Z",
      "poll":{"options":[{"title":"A"},{"title":"B"}]},
      "account":{"id":"117476039616356918","username":"fediqo","acct":"fediqo","display_name":""},"media_attachments":[],"emojis":[]}]
    """

    /// A poll of three, one vote in it, a run of an hour — before a change, and after the
    /// choices were reordered: the votes gone, the id kept.
    static let pollBefore = """
    {"id":"7","expires_at":"2026-10-21T01:23:24.372Z","expired":false,"multiple":false,"votes_count":1,"voters_count":1,"voted":true,"own_votes":[],
     "options":[{"title":"A","votes_count":1},{"title":"B","votes_count":0},{"title":"C","votes_count":0}],"emojis":[]}
    """
    static let pollReordered = """
    {"id":"7","expires_at":"2026-10-21T01:23:24.442Z","expired":false,"multiple":false,"votes_count":0,"voters_count":0,"voted":true,"own_votes":[],
     "options":[{"title":"B","votes_count":0},{"title":"A","votes_count":0},{"title":"C","votes_count":0}],"emojis":[]}
    """
    /// A poll that keeps its figures back until it ends, as its own author is answered.
    static let pollHidden = """
    {"id":"2","expires_at":"2026-10-21T01:22:34.302Z","expired":false,"multiple":false,"votes_count":0,"voters_count":0,"voted":true,"own_votes":[],
     "options":[{"title":"A","votes_count":null},{"title":"B","votes_count":null}],"emojis":[]}
    """

    static let blank = #"{"error":"Validation failed: Text can't be blank"}"#
    static let tooLong = #"{"error":"Validation failed: Text character limit of 500 exceeded"}"#
    static let notTheirs = #"{"error":"Record not found"}"#
    static let outside = #"{"error":"This action is outside the authorized scopes"}"#
    static let gone = #"{"error":"Not Found"}"#
    static let deadline = #"{"error":"Validation failed: Deadline is too soon"}"#

    static func media(_ id: String, _ description: String) -> String {
        """
        {"id":"\(id)","type":"image","url":"https://mastodon.localhost/system/media_attachments/files/\(id)/original/a.png",
         "preview_url":"https://mastodon.localhost/system/media_attachments/files/\(id)/small/a.png","remote_url":null,
         "meta":{"original":{"width":1,"height":1}},"description":\(description)}
        """
    }

    /// A status of the writer's, as the server wrote one, around what differs between answers.
    static func status(
        id: String = statusID, content: String, edited: String?, sensitive: Bool, language: String?,
        spoiler: String = "", media files: [(String, String)] = [], poll: String = "null"
    ) -> String {
        """
        {"id":"\(id)","created_at":"2026-10-21T00:24:12.838Z","in_reply_to_id":null,"sensitive":\(sensitive),
         "spoiler_text":"\(spoiler)","visibility":"public","language":\(language.map { "\"\($0)\"" } ?? "null"),
         "uri":"https://mastodon.localhost/ap/users/117476039616356918/statuses/\(id)",
         "url":"https://mastodon.localhost/@fediqo/\(id)","replies_count":0,"reblogs_count":0,"favourites_count":0,
         "edited_at":\(edited.map { "\"\($0)\"" } ?? "null"),"favourited":false,"reblogged":false,"bookmarked":false,
         "content":"\(content)","reblog":null,"application":{"name":"fediqo-servers-full","website":null},
         "account":{"id":"117476039616356918","username":"fediqo","acct":"fediqo","display_name":""},
         "media_attachments":[\(files.map { media($0.0, $0.1) }.joined(separator: ","))],"mentions":[],"emojis":[],
         "quote":null,"poll":\(poll)}
        """
    }
}
