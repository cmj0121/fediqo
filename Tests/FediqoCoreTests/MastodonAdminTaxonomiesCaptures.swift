import Foundation

/// The hashtags a Mastodon knows and the sites its links come from (#419), **as a real server
/// sent them** — the Mastodon 4.6.6 image `servers/compose.yml` pins, seeded by
/// `servers/mastodon/seed.rb`: #384's two hashtags, and a hashtag and a site of #419's own, each
/// waiting to be reviewed. Fetched on 2026-10-29 as the seed's Admin; what was changed is put
/// back by seeding again.
///
/// **Whole, not trimmed.** Each body is every byte the server sent, and each `Link` header as it
/// came.
///
/// | Asked (`/api/v1/admin/…`)                         | Answered                                        |
/// | ------------------------------------------------- | ----------------------------------------------- |
/// | `tags`                                            | 200, every hashtag, newest first                |
/// | `tags?limit=1`                                    | 200, one, and a `next` while there are more     |
/// | `tags/:id`                                        | 200, the one                                    |
/// | `tags/:id`, `PUT`                                 | 200, the one as changed, reviewed               |
/// | `tags/:id` of none                                | `404 {"error":"Record not found"}`              |
/// | `trends/links/publishers`                         | 200, each site, its id a number                 |
/// | `…/publishers/:id/approve`, `…/reject`            | 200, the site as decided                        |
/// | `…/publishers/:id/reject` of none                 | `404 {"error":"Record not found"}`              |
/// | `trends/links/publishers`, by the writer          | `403 {"error":"This action is not allowed"}`    |
enum MastodonAdminTaxonomiesCaptures {
    static let host = "mastodon.localhost"

    /// `GET /api/v1/admin/tags`: #419's hashtag, waiting; #384's waiting one, never let rise;
    /// and #384's rising one.
    static let tags = #"""
    [{"id":"3","name":"Fediqo419","url":"https://mastodon.localhost/tags/fediqo419","history":[{"day":"1793232000","accounts":"0","uses":"0"},{"day":"1793145600","accounts":"0","uses":"0"},{"day":"1793059200","accounts":"0","uses":"0"},{"day":"1792972800","accounts":"0","uses":"0"},{"day":"1792886400","accounts":"0","uses":"0"},{"day":"1792800000","accounts":"0","uses":"0"},{"day":"1792713600","accounts":"0","uses":"0"}],"following":false,"featuring":false,"trendable":false,"usable":true,"requires_review":true,"listable":true},{"id":"2","name":"FediqoWaiting","url":"https://mastodon.localhost/tags/fediqowaiting","history":[{"day":"1793232000","accounts":"0","uses":"0"},{"day":"1793145600","accounts":"0","uses":"0"},{"day":"1793059200","accounts":"0","uses":"0"},{"day":"1792972800","accounts":"0","uses":"0"},{"day":"1792886400","accounts":"0","uses":"0"},{"day":"1792800000","accounts":"0","uses":"0"},{"day":"1792713600","accounts":"0","uses":"0"}],"following":false,"featuring":false,"trendable":false,"usable":true,"requires_review":true,"listable":true},{"id":"1","name":"FediqoRising","url":"https://mastodon.localhost/tags/fediqorising","history":[{"day":"1793232000","accounts":"12","uses":"12"},{"day":"1793145600","accounts":"3","uses":"3"},{"day":"1793059200","accounts":"0","uses":"0"},{"day":"1792972800","accounts":"0","uses":"0"},{"day":"1792886400","accounts":"0","uses":"0"},{"day":"1792800000","accounts":"0","uses":"0"},{"day":"1792713600","accounts":"0","uses":"0"}],"following":false,"featuring":false,"trendable":true,"usable":true,"requires_review":true,"listable":true}]
    """#

    /// Its `Link` header.
    static let tagsLink = #"""
    <https://mastodon.localhost/api/v1/admin/tags?min_id=3>; rel="prev"
    """#

    /// `GET …/tags?limit=1`, before #419's hashtag was seeded: the newest, and where the rest begin.
    static let tagsFirst = #"""
    [{"id":"2","name":"FediqoWaiting","url":"https://mastodon.localhost/tags/fediqowaiting","history":[{"day":"1793232000","accounts":"0","uses":"0"},{"day":"1793145600","accounts":"0","uses":"0"},{"day":"1793059200","accounts":"0","uses":"0"},{"day":"1792972800","accounts":"0","uses":"0"},{"day":"1792886400","accounts":"0","uses":"0"},{"day":"1792800000","accounts":"0","uses":"0"},{"day":"1792713600","accounts":"0","uses":"0"}],"following":false,"featuring":false,"trendable":false,"usable":true,"requires_review":true,"listable":true}]
    """#

    /// Its `Link` header.
    static let tagsFirstLink = #"""
    <https://mastodon.localhost/api/v1/admin/tags?limit=1&max_id=2>; rel="next", <https://mastodon.localhost/api/v1/admin/tags?limit=1&min_id=2>; rel="prev"
    """#

    /// `GET …/tags/3`.
    static let tag = #"""
    {"id":"3","name":"Fediqo419","url":"https://mastodon.localhost/tags/fediqo419","history":[{"day":"1793232000","accounts":"0","uses":"0"},{"day":"1793145600","accounts":"0","uses":"0"},{"day":"1793059200","accounts":"0","uses":"0"},{"day":"1792972800","accounts":"0","uses":"0"},{"day":"1792886400","accounts":"0","uses":"0"},{"day":"1792800000","accounts":"0","uses":"0"},{"day":"1792713600","accounts":"0","uses":"0"}],"following":false,"featuring":false,"trendable":false,"usable":true,"requires_review":true,"listable":true}
    """#

    /// `PUT …/tags/3`, `trendable=false&usable=false&listable=false`: kept back, unused, unlisted.
    static let tagKeptBack = #"""
    {"id":"3","name":"Fediqo419","url":"https://mastodon.localhost/tags/fediqo419","history":[{"day":"1793232000","accounts":"0","uses":"0"},{"day":"1793145600","accounts":"0","uses":"0"},{"day":"1793059200","accounts":"0","uses":"0"},{"day":"1792972800","accounts":"0","uses":"0"},{"day":"1792886400","accounts":"0","uses":"0"},{"day":"1792800000","accounts":"0","uses":"0"},{"day":"1792713600","accounts":"0","uses":"0"}],"following":false,"featuring":false,"trendable":false,"usable":false,"requires_review":false,"listable":false}
    """#

    /// `PUT …/tags/3`, `trendable=true&usable=true&listable=true`: let rise, used and listed.
    static let tagLetRise = #"""
    {"id":"3","name":"Fediqo419","url":"https://mastodon.localhost/tags/fediqo419","history":[{"day":"1793232000","accounts":"0","uses":"0"},{"day":"1793145600","accounts":"0","uses":"0"},{"day":"1793059200","accounts":"0","uses":"0"},{"day":"1792972800","accounts":"0","uses":"0"},{"day":"1792886400","accounts":"0","uses":"0"},{"day":"1792800000","accounts":"0","uses":"0"},{"day":"1792713600","accounts":"0","uses":"0"}],"following":false,"featuring":false,"trendable":true,"usable":true,"requires_review":false,"listable":true}
    """#

    /// `GET …/tags/99999`, which there is none of.
    static let noTag = #"""
    {"error":"Record not found"}
    """#

    /// `GET /api/v1/admin/trends/links/publishers`: #419's site, waiting, decided neither way.
    static let sites = #"""
    [{"id":1,"domain":"fediqo419.example","trendable":null,"reviewed_at":null,"requested_review_at":"2026-10-29T13:28:33.698Z","requires_review":true}]
    """#

    /// Its `Link` header.
    static let sitesLink = #"""
    <https://mastodon.localhost/api/v1/admin/trends/links/publishers?min_id=1>; rel="prev"
    """#

    /// `POST …/publishers/1/approve`.
    static let siteApproved = #"""
    {"id":1,"domain":"fediqo419.example","trendable":true,"reviewed_at":"2026-10-29T13:28:46.190Z","requested_review_at":"2026-10-29T13:28:33.698Z","requires_review":false}
    """#

    /// `POST …/publishers/1/reject`.
    static let siteRejected = #"""
    {"id":1,"domain":"fediqo419.example","trendable":false,"reviewed_at":"2026-10-29T13:28:46.320Z","requested_review_at":"2026-10-29T13:28:33.698Z","requires_review":false}
    """#

    /// `POST …/publishers/999/reject`, which there is none of.
    static let noSite = #"""
    {"error":"Record not found"}
    """#

    /// `GET …/trends/links/publishers`, asked by the writer, whose role answers for nothing: 403.
    static let writerSites = #"""
    {"error":"This action is not allowed"}
    """#
}
