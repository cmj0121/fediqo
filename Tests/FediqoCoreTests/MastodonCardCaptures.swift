import Foundation

/// #335: what a real Mastodon says of the preview of a page a post links to — written down from the
/// one this checkout brings up with its worker (`FEDIQO_SERVERS_WORKER=1 make servers`, Mastodon
/// 4.6.6), 2026-10-21, and held against it on every run that has the worker (`MastodonCardSaysTests`,
/// and W0's `MastodonWorkerSaysTests`).
///
/// | Asked | Answered |
/// | ----- | -------- |
/// | the post, as it is taken | `"card": null` — the worker fetches the page after |
/// | the post, a moment later | the card: `url` as linked, `title`, `description`, `provider_name`, `author_name: ""`, `authors: []`, `missing_attribution: false`, `language`, `type: "link"`, `width`/`height` of the picture, `image` kept on the server's own host, `blurhash` |
/// | the page linked | `http://card.example.com/`, served by the fixture to the worker alone — **an `http` address**, which this app follows no link to |
///
/// The card below is that answer, byte for byte but for its line breaks.
enum MastodonCardCaptures {
    static let card = #"""
    {"url":"http://card.example.com/","title":"A page with a preview",
     "description":"A page this machine serves, for a post to link to and gain a card.","language":"en","type":"link",
     "author_name":"","author_url":"","provider_name":"Fediqo fixture","provider_url":"","html":"","width":64,"height":32,
     "image":"https://mastodon.localhost/system/cache/preview_cards/images/000/000/002/original/3ae146e878f57d7e.png",
     "image_description":"","embed_url":"","blurhash":"U14p@Bp1fQp1pMfkfQfkfQfQfQfQpMfkfQfk","published_at":null,
     "missing_attribution":false,"authors":[]}
    """#
}
