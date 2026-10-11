import Foundation

/// What a Mastodon says of itself beyond its one document (#321) — its longer account of
/// itself, the servers it knows, how busy it has been — **as a real server sent it**: the
/// Mastodon 4.6.6 image `servers/compose.yml` pins, as `servers/mastodon/seed.rb` leaves it, the
/// web process alone. Fetched with `curl` with no sign-in on 2026-10-11, in the window
/// `MastodonHostCaptures` was taken in, and again later that day in a window of this unit's
/// own, where a longer account was written from inside the server, the two that have a switch
/// were switched off, and they were switched back; the server was thrown away after each.
///
/// **Whole, not trimmed.** Each body is every byte the server sent. No token and nobody real
/// is in here: the one server named is the seed's `elsewhere.example`.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | its longer account (`/api/v1/instance/extended_description`), never written | `200 {"updated_at":null,"content":""}` — present, and empty. To anyone: the same bytes signed in |
/// | the same, once an administrator has written one | 200, `updated_at` the moment it was written and `content` **markup**: what was written as Markdown comes back as HTML — a heading, paragraphs, a list, a link with its `href`, `&amp;` for an ampersand — with a line break between blocks. The same bytes signed in |
/// | the servers it knows (`/api/v1/instance/peers`) | `200 ["elsewhere.example"]` — a list of bare names and nothing else: no count, no way on, nothing about any of them. To anyone |
/// | how busy it has been (`/api/v1/instance/activity`) | 200, twelve weeks, newest first, each `{"week","statuses","logins","registrations"}` and **every one of the four a string** — the week a moment in seconds, not a date. To anyone |
/// | the servers it knows and how busy it has been, switched off by whoever runs it | **404, `text/html`, no body at all** — the not-found of a thing kept from strangers (`MastodonHostCaptures`), which is a word about the address |
/// | the longer account, with those two switched off | as before: it has no switch that was found |
/// | all three, as often as wanted | each says `cache-control: max-age=300, public`, and counts against the 300 asks in five minutes an address is given |
enum MastodonHostMoreCaptures {
    static let host = "mastodon.localhost"

    /// `GET /api/v1/instance/extended_description`, never written.
    static let unwritten = #"{"updated_at":null,"content":""}"#

    /// `GET /api/v1/instance/extended_description`, once written.
    static let written = #"""
    {"updated_at":"2026-10-10T20:36:34Z","content":"<h1>About this server</h1>\n\n<p>Run by <strong>friends</strong> &amp; neighbours, for <a href=\"https://elsewhere.example/reading\">reading</a>.</p>\n\n<ul>\n<li>one rule</li>\n<li>another</li>\n</ul>\n\n<p>Since 2017.</p>\n"}
    """#

    /// The words of `written`, as they are read out of its markup.
    static let writtenWords = [
        "About this server", "Run by friends & neighbours, for reading.", "one rule", "another", "Since 2017.",
    ]

    /// `GET /api/v1/instance/peers`.
    static let servers = #"["elsewhere.example"]"#

    /// `GET /api/v1/instance/activity`.
    static let activity = #"""
    [{"week":"1791661624","statuses":"74","logins":"24","registrations":"24"},{"week":"1791056824","statuses":"0","logins":"0","registrations":"0"},{"week":"1790452024","statuses":"0","logins":"0","registrations":"0"},{"week":"1789847224","statuses":"0","logins":"0","registrations":"0"},{"week":"1789242424","statuses":"0","logins":"0","registrations":"0"},{"week":"1788637624","statuses":"0","logins":"0","registrations":"0"},{"week":"1788032824","statuses":"0","logins":"0","registrations":"0"},{"week":"1787428024","statuses":"0","logins":"0","registrations":"0"},{"week":"1786823224","statuses":"0","logins":"0","registrations":"0"},{"week":"1786218424","statuses":"0","logins":"0","registrations":"0"},{"week":"1785613624","statuses":"0","logins":"0","registrations":"0"},{"week":"1785008824","statuses":"0","logins":"0","registrations":"0"}]
    """#

    /// What the two with a switch answered, switched off: 404 and this — nothing.
    static let switchedOff = ""
}
