import Foundation

/// What else a Mastodon keeps for the person (#340), **as a real server answered** — the Mastodon
/// 4.6.6 image `servers/compose.yml` pins, with its worker up — asked on 2026-10-27 as the seed's
/// writer (a sign-in of every word), as the writer's sign-in that only reads (`notices.reading`),
/// as one of `read:statuses` alone, and with no sign-in.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Mastodon 4.6.6 |
/// | ----- | -------------- |
/// | `GET /api/v2/instance` | `wrapstodon` `null`: only a year that may be **made** now (10–31 December); never whether one was |
/// | `GET /api/v1/annual_reports` | 200 `{"annual_reports":[],"accounts":[],"statuses":[]}` with none made; by a sign-in that only reads (`read:accounts`), the same; by one of `read:statuses` alone, 403 |
/// | `GET /api/v1/annual_reports/2025` with none / `…/2025/state` | 404 `Record not found` / 200 `{"state":"ineligible"}` |
/// | the same once one is made (`AnnualReport.new(account, 2025).generate`, by Rails) | the year whole — `year`, `data` (`archetype`, `time_series` by month, `top_hashtags`, `top_statuses` by id), `schema_version` 2, `share_url`, `account_id` — beside the accounts and posts it names: `years` below. `state` `available`; another year 404. Listed until read (`POST …/read`, an act, not done here) |
/// | `GET /api/v1/accounts/:id/collections`, no sign-in | 200 `{"collections":[…]}`: each its `id`, `name`, `description`, `item_count`, and `items` naming each account by id. One with none: `{"collections":[]}` |
/// | the same, by a sign-in that only reads | **403 `This action is outside the authorized scopes`**: a token must hold `read:collections`; none at all is let in |
/// | `GET /api/v1/collections/:id`, no sign-in | 200 `{"collection":{…},"accounts":[…]}` — the accounts its owner first, then each in it. A collection not there: 404 |
/// | `GET /api/v1/statuses/:id/context` of a post from another server, signed in, its answers not fetched in the last fifteen minutes | 200, and the header `Mastodon-Async-Refresh: id="…", retry=3, result_count=0` while the worker fetches; asked again two seconds later, no header — done. Unsigned: never |
/// | `GET /api/v1_alpha/async_refreshes/:id` by a sign-in that only reads | 403: it wants the whole of `read` — never asked here |
enum MastodonExtrasCaptures {
    /// `GET /api/v1/annual_reports`, one year made: verbatim.
    static let years = #"""
{"annual_reports":[{"year":2025,"data":{"archetype":"lurker","time_series":[{"month":12,"statuses":0,"followers":0}],"top_hashtags":[],"top_statuses":{"by_reblogs":null,"by_replies":null,"by_favourites":null}},"schema_version":2,"share_url":"https://mastodon.localhost/@fediqo/wrapstodon/2025/9280ce3f70d5df4a","account_id":"117510774052515322"}],"accounts":[{"id":"117510774052515322","username":"fediqo","acct":"fediqo","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-27T00:00:00.000Z","note":"","url":"https://mastodon.localhost/@fediqo","uri":"https://mastodon.localhost/ap/users/117510774052515322","avatar":"https://mastodon.localhost/avatars/original/missing.png","avatar_static":"https://mastodon.localhost/avatars/original/missing.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":1,"following_count":1,"statuses_count":54,"last_status_at":"2026-10-27","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"emojis":[],"roles":[],"fields":[]}],"statuses":[]}
"""#

    /// `GET /api/v1/accounts/:id/collections`, no sign-in: verbatim.
    static let collections = #"""
{"collections":[{"id":"117510778888932060","uri":"https://mastodon.localhost/ap/users/117510774478826484/collections/117510778888932060","name":"Friends of the fixture","description":"People worth reading","language":null,"account_id":"117510774478826484","local":true,"sensitive":false,"discoverable":true,"url":"https://mastodon.localhost/collections/117510778888932060","item_count":2,"created_at":"2026-10-27T03:36:27.668Z","updated_at":"2026-10-27T03:36:27.668Z","tag":null,"items":[{"id":"117510778888974228","state":"accepted","created_at":"2026-10-27T03:36:27.683Z","account_id":"117510774514744569"},{"id":"117510778888974229","state":"accepted","created_at":"2026-10-27T03:36:27.688Z","account_id":"117510774521396949"}]}]}
"""#

    /// `GET /api/v1/collections/:id`, no sign-in: the collection verbatim, its accounts cut to
    /// the fields read — the probe kept the two in it by their ids alone, so their names here are
    /// stand-ins of the same shape.
    static let collection = #"""
{"collection":{"id":"117510778888932060","uri":"https://mastodon.localhost/ap/users/117510774478826484/collections/117510778888932060","name":"Friends of the fixture","description":"People worth reading","language":null,"account_id":"117510774478826484","local":true,"sensitive":false,"discoverable":true,"url":"https://mastodon.localhost/collections/117510778888932060","item_count":2,"created_at":"2026-10-27T03:36:27.668Z","updated_at":"2026-10-27T03:36:27.668Z","tag":null,"items":[{"id":"117510778888974228","state":"accepted","created_at":"2026-10-27T03:36:27.683Z","account_id":"117510774514744569"},{"id":"117510778888974229","state":"accepted","created_at":"2026-10-27T03:36:27.688Z","account_id":"117510774521396949"}]},"accounts":[{"id":"117510774478826484","username":"fediqo_person","acct":"fediqo_person","display_name":"Per :fediqo_mark: Son"},{"id":"117510774514744569","username":"fan1","acct":"fan1","display_name":"Fan 1"},{"id":"117510774521396949","username":"fan2","acct":"fan2","display_name":"Fan 2"}]}
"""#

    /// The header the context of a post from another server was answered with.
    static let gathering = #"id="ImNvbnRleHQ6MTE3NTEwNzc0NjczMjEyNDY2OnJlZnJlc2gi--269bf5d15be3c7ddfb7e55784ef0ed6d61363a13", retry=3, result_count=0"#
}
