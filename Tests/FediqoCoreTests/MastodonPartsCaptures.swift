import Foundation

/// What a Mastodon says to a body of several parts as this app makes one (#312), **as a real
/// server sent it**: the Mastodon 4.6.6 image `servers/compose.yml` pins, the web process
/// alone, as `servers/mastodon/seed.rb` left it. Asked on 2026-10-11 by
/// `MastodonPartsSaysTests` itself — the bodies made by `MultipartBody`, sent through the
/// signed-in door as the seeded second person, **asking in English** where asked plainly. The
/// server was thrown away afterwards.
///
/// **Whole, not trimmed.** Each body is every byte the server sent. No token and nobody real
/// is in here.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | `PATCH /api/v1/accounts/update_credentials` with a `note` field of several scripts, a quote, an `&` and a line end, and an `avatar` file part of a one-pixel PNG whose name is not ASCII and holds a space and quotes (sent as `%XX`) | 200, the account whole (`taken`): `source.note` the text exactly as sent, `note` the same as the server's own HTML, `avatar` an address of the server's own making — the file's name is used nowhere |
/// | the same address, an `avatar` part said to be `image/png` whose bytes are no picture | **422** (`noPicture`): a sentence, and beside it `details` naming the part and a word for why. Nothing of the account changes |
/// | the account check after each | the same bytes the change answered with: the two say an account the same way |
/// | a `note` field with nothing in it, then `DELETE /api/v1/profile/avatar` | 200 each, and the account check then answers byte for byte what it did before anything was sent — an empty field is a field, and sets the note to nothing |
///
/// So a body this app makes is read as it was meant: a field's UTF-8 as text, a file's bytes
/// as the file, with no worker running — the picture is taken in while the request waits.
enum MastodonPartsCaptures {
    /// The note sent: more than one script, what HTML would escape, and a line end.
    static let note = "Fediqo 寫的 — \"quoted\" & café\nsecond line"

    /// A PNG of one pixel, in base64: the picture sent.
    static let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    /// The answer to the note and the picture. **Of that day's seed**: the id, and so the
    /// picture's address, are made anew by every `make servers`, so no check holds this whole.
    static let taken = #"{"id":"117419563845369311","username":"fediqo_other","acct":"fediqo_other","display_name":"","locked":false,"bot":false,"discoverable":null,"indexable":false,"group":false,"created_at":"2026-10-11T00:00:00.000Z","note":"<p>Fediqo 寫的 — &quot;quoted&quot; &amp; café<br />second line</p>","url":"https://mastodon.localhost/@fediqo_other","uri":"https://mastodon.localhost/ap/users/117419563845369311","avatar":"https://mastodon.localhost/system/accounts/avatars/117/419/563/845/369/311/original/e956f8d85d609ba7.png","avatar_static":"https://mastodon.localhost/system/accounts/avatars/117/419/563/845/369/311/original/e956f8d85d609ba7.png","avatar_description":"","header":"https://mastodon.localhost/headers/original/missing.png","header_static":"https://mastodon.localhost/headers/original/missing.png","header_description":"","followers_count":2,"following_count":0,"statuses_count":8,"last_status_at":"2026-10-11","hide_collections":null,"show_media":true,"show_media_replies":true,"show_featured":true,"noindex":false,"feature_approval":{"automatic":[],"manual":[],"current_user":"denied"},"source":{"privacy":"public","sensitive":false,"language":null,"note":"Fediqo 寫的 — \"quoted\" & café\nsecond line","fields":[],"follow_requests_count":0,"hide_collections":null,"discoverable":null,"indexable":false,"attribution_domains":[],"quote_policy":"public"},"emojis":[],"roles":[],"fields":[],"role":{"id":"-99","name":"","permissions":"65536","color":"","highlighted":false,"collection_limit":10}}"#

    /// The answer to bytes that are no picture, sent as one.
    static let noPicture = #"{"error":"Validation failed: Avatar has contents that are not what they are reported to be","details":{"avatar":[{"error":"ERR_SPOOFED_MEDIA_TYPE","description":"has contents that are not what they are reported to be"}]}}"#
}
