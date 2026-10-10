import Foundation

/// The hashtags and the links rising on a Mastodon (#320), **as a real server sent them** — the
/// Mastodon 4.6.6 image `servers/compose.yml` pins, the web process alone. Fetched with `curl`
/// on 2026-10-11, with no sign-in and with a sign-in that may do everything: first as a new
/// server answers; then with one hashtag and one link made to be rising from inside the server,
/// as `servers/mastodon/seed.rb` now makes them; then with what is rising switched off, and
/// switched back. The server was thrown away afterwards.
///
/// **Whole, not trimmed.** Each body is every byte the server sent. No token and nobody real
/// is in here: the hashtag and the link are the seed's, the host it leads to `elsewhere.example`.
///
/// ## What was asked, and what the server answered
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | the hashtags rising (`/api/v1/trends/tags`) on a new server | `200 []`, to anyone |
/// | the links rising (`/api/v1/trends/links`) on a new server | `200 []`, to anyone |
/// | the hashtags, with one made to be rising | 200, a list: `name` **as the hashtag was first written** (`FediqoRising`, while its `url` ends in the folded `fediqorising`), an `id`, and `history` — seven days, newest first, each `{"day","accounts","uses"}` and **every one of the three a string**, the day a moment in seconds at that day's midnight. Signed in, each entry also says `following` and `featuring` |
/// | the links, with one made to be rising | 200, a list: `url`, and what the server holds of the page — `title` and `description` **as plain words, not markup** (a title with `<b>` and `&` in it comes back with them as written), `author_name`, `provider_name`, `language`, `type`, `image` (`null`: none was read), `width`, `height`, `html`, `embed_url`, `blurhash`, `published_at`, `authors` — and the same seven days of `history`. Signed in, also `missing_attribution` |
/// | either, with what is rising switched off by whoever runs the server | **`200 []`** — exactly what a new server answers. Nothing in the answer, and nothing in the server's document, says which |
/// | either, switched back on | what it answered before, to the byte |
/// | either, as often as wanted | `cache-control: max-age=15, public`, and counted against the 300 asks in five minutes an address is given |
///
/// So what is rising can never be told absent: an empty answer is the source giving none.
enum MastodonRisingCaptures {
    static let host = "mastodon.localhost"

    /// Either address on a new server, and either with what is rising switched off.
    static let none = "[]"

    /// `GET /api/v1/trends/tags`, no sign-in.
    static let tags = #"""
    [{"id":"1","name":"FediqoRising","url":"https://mastodon.localhost/tags/fediqorising","history":[{"day":"1791590400","accounts":"12","uses":"12"},{"day":"1791504000","accounts":"3","uses":"3"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"},{"day":"1791072000","accounts":"0","uses":"0"}]}]
    """#

    /// The same, signed in.
    static let tagsSignedIn = #"""
    [{"id":"1","name":"FediqoRising","url":"https://mastodon.localhost/tags/fediqorising","history":[{"day":"1791590400","accounts":"12","uses":"12"},{"day":"1791504000","accounts":"3","uses":"3"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"},{"day":"1791072000","accounts":"0","uses":"0"}],"following":false,"featuring":false}]
    """#

    /// `GET /api/v1/trends/links`, no sign-in.
    static let links = #"""
    [{"url":"https://elsewhere.example/stories/rising","title":"A story <b>rising</b> & more","description":"What the page says of itself.","language":"en","type":"link","author_name":"Somebody","author_url":"https://elsewhere.example/somebody","provider_name":"Elsewhere","provider_url":"https://elsewhere.example","html":"","width":0,"height":0,"image":null,"image_description":"","embed_url":"","blurhash":null,"published_at":null,"history":[{"day":"1791590400","accounts":"20","uses":"20"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"},{"day":"1791072000","accounts":"0","uses":"0"}],"authors":[{"name":"Somebody","url":"https://elsewhere.example/somebody","account":null}]}]
    """#

    /// The same, signed in.
    static let linksSignedIn = #"""
    [{"url":"https://elsewhere.example/stories/rising","title":"A story <b>rising</b> & more","description":"What the page says of itself.","language":"en","type":"link","author_name":"Somebody","author_url":"https://elsewhere.example/somebody","provider_name":"Elsewhere","provider_url":"https://elsewhere.example","html":"","width":0,"height":0,"image":null,"image_description":"","embed_url":"","blurhash":null,"published_at":null,"missing_attribution":false,"history":[{"day":"1791590400","accounts":"20","uses":"20"},{"day":"1791504000","accounts":"0","uses":"0"},{"day":"1791417600","accounts":"0","uses":"0"},{"day":"1791331200","accounts":"0","uses":"0"},{"day":"1791244800","accounts":"0","uses":"0"},{"day":"1791158400","accounts":"0","uses":"0"},{"day":"1791072000","accounts":"0","uses":"0"}],"authors":[{"name":"Somebody","url":"https://elsewhere.example/somebody","account":null}]}]
    """#
}
