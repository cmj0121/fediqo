import Foundation

/// What a real Mastodon 4.6.6 answered about requests to follow the reader and about removing
/// a follower (#313), asked 2026-10-13 of the fixture with the writer locked for the length of
/// the asking. Kept as checks in `MastodonStandingSaysTests.requestsAreAnswered`.
///
/// **A stale row can only fail or do nothing.** Each act names the account by the id the
/// source gave, so it is never about somebody else; and what the source does where the state
/// changed elsewhere is in the table.
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | `GET /api/v1/follow_requests`, as a sign-in with `read:follows` | 200, a list of accounts as any list of people has them; `Link` with `since_id` for prev, and `max_id` for next where a `limit` cut it short — **the id is the request's, not a person's** |
/// | the same with the reading words alone · with no sign-in | 403 `"This action is outside the authorized scopes"` · 401 `"The access token is invalid"` |
/// | how many ask | said nowhere on the list. Only the account check says it: `source.follow_requests_count` in `accounts/verify_credentials` |
/// | `POST /api/v1/follow_requests/:id/authorize` of somebody who asked | 200, **the whole standing** (the sixteen things) with `followed_by: true` |
/// | `…/reject` of somebody who asked | 200, the whole standing with `followed_by: false` |
/// | either, **again**; of somebody whose request was already answered; of somebody who **took it back**; of somebody who never asked; of an id nobody has | **404** `"Record not found"`, and nothing changed |
/// | either as a sign-in that only sees who the reader follows · with none | 403, as any change · 401 |
/// | `POST /api/v1/accounts/:id/remove_from_followers` of a follower | 200, the whole standing with `followed_by: false` |
/// | the same **again**, of somebody who **already left**, of the reader themselves | 200, the standing as it stands: nothing to change |
/// | the same of somebody who has **only asked** | 200, and **the request stays**: `requested_by: true`, and they are still listed |
/// | the same of an id nobody has · as a sign-in that only sees · with none | 404 · 403 · 401 |
enum MastodonRequestsCaptures {
    static let host = "mastodon.localhost"
    /// Somebody who asked to follow the reader.
    static let asker = "117431914788449008"

    /// `POST /api/v1/follow_requests/117431914788449008/authorize`.
    static let authorized = #"{"id":"117431914788449008","following":true,"showing_reblogs":true,"notifying":false,"languages":null,"followed_by":true,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// `POST /api/v1/follow_requests/117431914788449008/reject`, and
    /// `POST /api/v1/accounts/117431914788449008/remove_from_followers`: the same body.
    static let refused = #"{"id":"117431914788449008","following":true,"showing_reblogs":true,"notifying":false,"languages":null,"followed_by":false,"blocking":false,"blocked_by":false,"muting":false,"muting_notifications":false,"muting_expires_at":null,"requested":false,"requested_by":false,"domain_blocking":false,"endorsed":false,"note":""}"#

    /// Either answer to a request that is not there.
    static let noSuchRequest = #"{"error":"Record not found"}"#
}
