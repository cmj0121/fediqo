import Foundation

/// How a Mastodon tells those who answer for it it is doing, beyond its few figures (#418), **as
/// a real server sent it** — the Mastodon 4.6.6 image `servers/compose.yml` pins, seeded by
/// `servers/mastodon/seed.rb`. Fetched on 2026-10-29 as the seed's Admin, over the week ending
/// that day, and who stayed over the three months ending in it. Nothing asked here changes
/// anything the server holds.
///
/// **Whole, not trimmed.** Each body is every byte the server sent.
///
/// | Asked (`/api/v1/admin/…`)                         | Answered                                         |
/// | ------------------------------------------------- | ------------------------------------------------ |
/// | `dimensions`, the five keys                       | 200, each key with its lines, in the asked order |
/// | `dimensions`, only `languages`, as the Moderator  | 200, the one key, given with no lines            |
/// | `retention`, by month                             | 200, a cohort a month, each month after it       |
/// | `retention`, by a role without it                 | `403 {"error":"This action is not allowed"}`     |
enum MastodonAdminDashboardCaptures {
    static let host = "mastodon.localhost"

    /// `POST /api/v1/admin/dimensions`, `keys[]` of the five, `start_at=2026-10-23`,
    /// `end_at=2026-10-30`, `limit=10`: no languages among those active — the seed's people chose
    /// none — and each of the others.
    static let dimensions = #"""
    [{"key":"languages","data":[]},{"key":"servers","data":[{"key":"mastodon.localhost","human_key":"mastodon.localhost","value":"85"},{"key":"elsewhere.example","human_key":"elsewhere.example","value":"3"}]},{"key":"software_versions","data":[{"key":"mastodon","human_key":"Mastodon","value":"4.6.6","human_value":"4.6.6"},{"key":"ruby","human_key":"Ruby","value":"ruby 4.0.5 (2026-05-20 revision 64336ffd0e) +YJIT +PRISM [aarch64-linux]","human_value":"4.0.5p0"},{"key":"postgresql","human_key":"PostgreSQL","value":"16.15","human_value":"16.15"},{"key":"redis","human_key":"Redis","value":"7.4.10","human_value":"7.4.10"},{"key":"libvips","human_key":"libvips","value":"8.18.3","human_value":"8.18.3"},{"key":"ffmpeg","human_key":"FFmpeg","value":"8.1.2","human_value":"8.1.2"}]},{"key":"sources","data":[{"key":"web","human_key":"Website","value":"37"}]},{"key":"space_usage","data":[{"key":"postgresql","human_key":"PostgreSQL","value":"16415767","unit":"bytes","human_value":"15.7 MB"},{"key":"redis","human_key":"Redis","value":"2211080","unit":"bytes","human_value":"2.11 MB"},{"key":"media","human_key":"Media storage","value":"140","unit":"bytes","human_value":"140 Bytes"}]}]
    """#

    /// `POST …/dimensions`, `keys[]=languages` only, as the Moderator: the one key, and nothing
    /// in it — the answer of a server that gives no other.
    static let languagesOnly = #"""
    [{"key":"languages","data":[]}]
    """#

    /// `POST …/retention`, `start_at=2026-08-01`, `end_at=2026-10-29`, `frequency=month`: a
    /// cohort for each month, each with that month and every month after. Nobody joined before
    /// October; of October's, three were seen.
    static let retention = #"""
    [{"period":"2026-08-01T00:00:00+00:00","frequency":"month","data":[{"date":"2026-08-01T00:00:00+00:00","rate":0.0,"value":"0"},{"date":"2026-09-01T00:00:00+00:00","rate":0.0,"value":"0"},{"date":"2026-10-01T00:00:00+00:00","rate":0.0,"value":"0"}]},{"period":"2026-09-01T00:00:00+00:00","frequency":"month","data":[{"date":"2026-09-01T00:00:00+00:00","rate":0.0,"value":"0"},{"date":"2026-10-01T00:00:00+00:00","rate":0.0,"value":"0"}]},{"period":"2026-10-01T00:00:00+00:00","frequency":"month","data":[{"date":"2026-10-01T00:00:00+00:00","rate":0.08108108108108109,"value":"3"}]}]
    """#

    /// `POST …/retention`, asked by the writer, whose role answers for nothing: 403.
    static let writerRetention = #"""
    {"error":"This action is not allowed"}
    """#
}
