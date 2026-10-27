import Foundation

/// The person's filters at a Mastodon (#338), **as a real server answered** — the Mastodon 4.6.6
/// image `servers/compose.yml` pins, with its worker up — asked on 2026-10-27 as the seed's writer
/// (`fediqo`, a sign-in holding every word) and as the writer's sign-in of `read:statuses` alone,
/// while the second person posted the words the filters name. Every filter made was removed after.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Mastodon 4.6.6 |
/// | ----- | -------------- |
/// | `GET /api/v2/filters` | 200 `[]`; by the sign-in of `read:statuses` alone, 403 `This action is outside the authorized scopes` — and so `POST` |
/// | `POST /api/v2/filters` `title`, `context[]`, `filter_action` `warn` / `hide` / `blur`, `keywords_attributes[][keyword]` and `[whole_word]`, `expires_in` | 200, the filter: `id`, `title`, `context` as sent, `expires_at` (now and `expires_in`, to the millisecond) or `null`, `filter_action`, `keywords` (`id`, `keyword`, `whole_word` — `true` where none was sent), `statuses` `[]` |
/// | the same with `title` empty / no `context` / `filter_action` `explode` / `context[]` `nowhere` | 422 `Validation failed: Title can't be blank` / `Context can't be blank, Context None or invalid context supplied` / `Action is not included in the list` / `Context None or invalid context supplied` |
/// | a post that names a word a filter keeps, read in Home, in the public timeline, alone, by **either** sign-in | the post **is sent**, every action alike — `hide` included — with `filtered` naming each filter that caught it: `filter` (`id`, `title`, `context`, `expires_at`, `filter_action`; no keywords), `keyword_matches`, `status_matches` `null`. **Every filter, whatever its context**: the client weighs where it applies. A post no filter caught: `filtered` `[]` |
/// | `POST /api/v2/filters/:id/statuses` `status_id` | 200 `{"id","status_id"}`; the post then reads `filtered` with `keyword_matches` `null` and `status_matches` its own id. A post that does not exist: 422 `Validation failed: Status must exist` |
/// | `PUT /api/v2/filters/:id` with `keywords_attributes[]` — one kept, one `_destroy`, one new after it | 200, **the new one gone too**: written as `[]`, a new keyword folds into the one before it, removed with it |
/// | the same, each keyword at its place (`keywords_attributes[0][id]`, `[1][_destroy]`, `[2][keyword]`) | 200: the kept one changed, the removed one gone, the new one made with an id of its own |
/// | `PUT` `expires_in` empty | 200, `expires_at` `null`: for good |
/// | `DELETE /api/v2/filters/:id` | 200 `{}`; again 404 `Record not found` |
enum MastodonFilterCaptures {
    /// `POST /api/v2/filters`, a warning for a day: the answer, verbatim.
    static let made = #"""
    {"id":"1","title":"Fruit warned","context":["home","public","thread"],"expires_at":"2026-10-28T02:31:36.021Z","filter_action":"warn","keywords":[{"id":"1","keyword":"apple","whole_word":true},{"id":"2","keyword":"pear","whole_word":false}],"statuses":[]}
    """#

    /// `GET /api/v2/filters/:id` of the same, changed and with a post put in it by itself.
    static let changed = #"""
    {"id":"1","title":"Fruit, warned","context":["home"],"expires_at":null,"filter_action":"warn","keywords":[{"id":"1","keyword":"apple","whole_word":true}],"statuses":[{"id":"1","status_id":"117510523903991265"}]}
    """#

    /// `filtered` on three posts of Home, as read by the sign-in of `read:statuses` alone: one
    /// each caught by a warning, a hiding and a blurring filter.
    static let warned = #"""
    [{"filter":{"id":"1","title":"Fruit warned","context":["home","public","thread"],"expires_at":"2026-10-28T02:31:36.021Z","filter_action":"warn"},"keyword_matches":["apple"],"status_matches":null}]
    """#
    static let hidden = #"""
    [{"filter":{"id":"2","title":"Fruit hidden","context":["home","public"],"expires_at":null,"filter_action":"hide"},"keyword_matches":["banana"],"status_matches":null}]
    """#
    static let blurred = #"""
    [{"filter":{"id":"3","title":"Fruit blurred","context":["home","public"],"expires_at":null,"filter_action":"blur"},"keyword_matches":["cherry"],"status_matches":null}]
    """#
}
