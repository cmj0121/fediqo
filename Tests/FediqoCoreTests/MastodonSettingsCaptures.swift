import Foundation

/// What somebody set at a Mastodon for the posts they write there (#321), **as a real server
/// sent it**: the Mastodon 4.6.6 image `servers/compose.yml` pins, the web process alone, as
/// `servers/mastodon/seed.rb` left it. Fetched with `curl`, **asking in English**
/// (`Accept-Language: en`), on 2026-10-11 with no sign-in, with a
/// token that is none, with a sign-in that may do everything, with this app's reading sign-in
/// as the seed makes it, and with three tokens made inside the server for one word each; the
/// writer's settings were then changed from inside the server and asked again. The server was
/// thrown away afterwards.
///
/// **Whole, not trimmed.** Each body is every byte the server sent. No token and nobody real
/// is in here.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | what the person set (`/api/v1/preferences`), with no sign-in, or a token that is none | **401** `{"error":"The access token is invalid"}` — a sentence in the language asked in: asked with no language named, from a machine not set to English, the bytes were others |
/// | the same, signed in with everything | 200, one flat list of seven settings named by the server: `posting:default:visibility`, `posting:default:sensitive`, `posting:default:language`, `posting:default:quote_policy`, `reading:expand:media`, `reading:expand:spoilers`, `reading:autoplay:gifs` |
/// | the same, with **this app's reading sign-in** (`read:statuses read:lists read:accounts read:search`), and with the seed's first, older one | 200, the same bytes: the reading sign-in is given it |
/// | with a token for `read:accounts` alone | 200, the same bytes — that is the one word it wants |
/// | with a token for `read:statuses` alone, or `read:lists` alone | **403** `{"error":"This action is outside the authorized scopes"}`, the header naming what is missing — a refusal of that sign-in, which goes on being honoured for what it holds |
/// | somebody who never set anything | `"public"`, `false`, and **`"en"`** — a language standing where the person set none, never `null` here. **It is not known to be theirs**: asked again with no language named, from a machine not set to English, the answer was not these bytes. So the language is the source's word, and not a thing the person is known to have chosen |
/// | set to unlisted, covered, `zh-TW` | `"unlisted"`, `true`, `"zh-TW"` — the language a tag, with its region where one was set |
/// | set to followers only, `zh` | `"private"`, `false`, `"zh"` |
/// | set to mentioned people only | refused inside the server: a new post's reach is one of `public`, `unlisted`, `private`. So `direct` is never answered here — and is read all the same, as any word is |
/// | the directory switched off, or anything else of the host | no difference: these are the person's, not the host's, and no switch for them was found |
///
/// So the three are read signed in, through the one signed-in door, with the words every
/// sign-in this app makes already holds; a 403 is said as a sign-in that was not given this,
/// and the four other settings are left for the units that read by them.
enum MastodonSettingsCaptures {
    static let host = "mastodon.localhost"

    /// `GET /api/v1/preferences`, of somebody who never set anything.
    static let untouched = #"{"posting:default:visibility":"public","posting:default:sensitive":false,"posting:default:language":"en","posting:default:quote_policy":"public","reading:expand:media":"default","reading:expand:spoilers":false,"reading:autoplay:gifs":false}"#

    /// The same, set to unlisted, covered, and Chinese as written in Taiwan.
    static let unlistedCovered = #"{"posting:default:visibility":"unlisted","posting:default:sensitive":true,"posting:default:language":"zh-TW","posting:default:quote_policy":"public","reading:expand:media":"default","reading:expand:spoilers":false,"reading:autoplay:gifs":false}"#

    /// The same, set to followers only and Chinese.
    static let followersOnly = #"{"posting:default:visibility":"private","posting:default:sensitive":false,"posting:default:language":"zh","posting:default:quote_policy":"public","reading:expand:media":"default","reading:expand:spoilers":false,"reading:autoplay:gifs":false}"#

    /// With no sign-in, or a token that is none: 401 and this.
    static let noSignIn = #"{"error":"The access token is invalid"}"#

    /// With a sign-in that lacks the word for reading the person's own account: 403 and this.
    static let notGiven = #"{"error":"This action is outside the authorized scopes"}"#
}
