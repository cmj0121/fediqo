import Foundation

/// A post sent later (#333), **as a real server sent it** — the Mastodon 4.6.6 image
/// `servers/compose.yml` pins, with its worker up (`FEDIQO_SERVERS_WORKER=1 make servers`) —
/// asked with the seed's writer (`fediqo`) and its second person on 2026-10-21. Every waiting post
/// made for the asking was let go after it. `MastodonLaterSaysTests` asks the same again on every
/// servers-unlocked run; `MastodonWorkerSaysTests` (W0) asks that one goes out at its time.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Mastodon 4.6.6 |
/// | ----- | -------------- |
/// | `POST /statuses` with `scheduled_at` an hour ahead | 200, a `ScheduledStatus`: `id` (small, its own count, not a post's), `scheduled_at` (whole seconds), `params` as sent and kept — **`sensitive` the string `"true"`, poll `multiple`, `hide_totals`, `expires_in` strings, `in_reply_to_id` a bare JSON number too large for a double**, `media_ids` strings, `visibility`, `language`, `spoiler_text`; nulls where nothing was sent — and `media_attachments` whole, descriptions included. **`params` names two keys twice** (`quote_approval_policy`, a number then a word; `quoted_status_id`) |
/// | the same, four minutes ahead | 422 `Validation failed: Scheduled at date must be in the future` |
/// | the same, ten minutes **past**, or `next tuesday` | **200, a post published at once** — not refused |
/// | the same again under the same `Idempotency-Key` | **404** `Record not found` — no second waiting post, and not the first one back: read here as *may have been made*, and looked for among what waits |
/// | a second waiting post made with the first one's `media_ids` | 200: **the file moves** — the new one carries it, the first is listed with none |
/// | the first then let go | 200: the file stays on the second, and the file itself stays |
/// | any answer's `Date` header | the source's clock, to the second (`Wed, 21 Oct 2026 04:43:08 GMT`): what a time ahead is judged by here |
/// | the 26th for one day | 422 `Validation failed: You have exceeded the limit of 25 scheduled posts for today` — counted by the day it is set for; another day takes one |
/// | the 301st waiting at all | *doc — not asked*: 300 is the source's `TOTAL_LIMIT` |
/// | `GET /scheduled_statuses` | 200, newest made first (by id, not by time); `Link` `rel="next"` with `max_id` where cut (`limit`), `rel="prev"` always |
/// | the same, by a sign-in that only reads (`read:statuses`) | 200, the same list |
/// | `GET /scheduled_statuses/:id` of another person's | 404 `Record not found` |
/// | `PUT /scheduled_statuses/:id` `scheduled_at` | 200, the waiting post at its new time |
/// | the same with `status` beside it | 200, **the words unchanged**: only the time moves |
/// | the same, too near | 422 `Validation failed: Scheduled at date must be in the future` |
/// | the same, onto a day holding 25 | 422 `…limit of 25 scheduled posts for today` |
/// | the same, of another person's | 404; by a sign-in that only reads: 403 `This action is outside the authorized scopes` |
/// | `DELETE /scheduled_statuses/:id` | 200 `{}`; again: 404. **Not held to the thirty-in-half-an-hour a post's taking back is**: 27 in a row all 200 |
enum MastodonLaterCaptures {
    /// `POST /api/v1/statuses` with `scheduled_at`, a post carrying a file: the answer, verbatim
    /// but for the file's address.
    static let withMedia = #"""
    {"id":"1","scheduled_at":"2026-10-21T05:09:20.000Z","params":{"text":"later with media","quote_approval_policy":131072,"media_ids":["117476934325177381"],"sensitive":"true","spoiler_text":"cw","visibility":"unlisted","language":"de","scheduled_at":null,"poll":null,"allowed_mentions":null,"idempotency":null,"with_rate_limit":false,"in_reply_to_id":null,"application_id":3,"quoted_status_id":null,"quoted_status_id":null,"quote_approval_policy":"public"},"media_attachments":[{"id":"117476934325177381","type":"image","url":"https://mastodon.localhost/system/media_attachments/files/117/476/934/325/177/381/original/62a83222fd1c6166.png","preview_url":"https://mastodon.localhost/system/media_attachments/files/117/476/934/325/177/381/small/62a83222fd1c6166.png","remote_url":null,"preview_remote_url":null,"text_url":null,"meta":{"original":{"width":1,"height":1,"size":"1x1","aspect":1.0}},"description":"alt one","blurhash":"U20036fZfQfZfZfRfQfRfQfQfQfQfZfRfQfR"}]}
    """#

    /// The same, a post with a poll.
    static let withPoll = #"""
    {"id":"2","scheduled_at":"2026-10-21T05:10:20.000Z","params":{"text":"later with poll","quote_approval_policy":131072,"media_ids":null,"sensitive":null,"spoiler_text":null,"visibility":"private","language":null,"scheduled_at":null,"poll":{"multiple":"true","hide_totals":"false","expires_in":"3600","options":["A","B"]},"allowed_mentions":null,"idempotency":null,"with_rate_limit":false,"in_reply_to_id":null,"application_id":3,"quoted_status_id":null,"quoted_status_id":null,"quote_approval_policy":"public"},"media_attachments":[]}
    """#

    /// The same, an answer: its `in_reply_to_id` a bare number.
    static let answer = #"""
    {"id":"3","scheduled_at":"2026-10-21T05:11:20.000Z","params":{"text":"later answer","quote_approval_policy":131072,"media_ids":null,"sensitive":null,"spoiler_text":null,"visibility":"public","language":null,"scheduled_at":null,"poll":null,"allowed_mentions":null,"idempotency":null,"with_rate_limit":false,"in_reply_to_id":117476930889022363,"application_id":3,"quoted_status_id":null,"quoted_status_id":null,"quote_approval_policy":"public"},"media_attachments":[]}
    """#

    /// `GET /api/v1/scheduled_statuses?limit=2`'s `Link`.
    static let link = #"<https://mastodon.localhost/api/v1/scheduled_statuses?limit=2&max_id=2>; rel="next", <https://mastodon.localhost/api/v1/scheduled_statuses?limit=2&min_id=3>; rel="prev""#
    /// The same with nothing cut.
    static let linkWhole = #"<https://mastodon.localhost/api/v1/scheduled_statuses?min_id=3>; rel="prev""#

    static let tooSoon = #"{"error":"Validation failed: Scheduled at date must be in the future"}"#
    static let dayFull = #"{"error":"Validation failed: You have exceeded the limit of 25 scheduled posts for today"}"#
    static let notFound = #"{"error":"Record not found"}"#
}
