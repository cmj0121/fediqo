import Foundation
@testable import FediqoCore

/// A post with only the fields a test cares about filled in. Shared so two suites cannot
/// drift into two subtly different ideas of what a post looks like.
///
/// A booster is named once: the display name the row shows, and an actor URI derived from
/// it for the key — so "someone else" on two servers is the same someone else.
func makePost(
    uri: String,
    originURI: String? = nil,
    at seconds: TimeInterval,
    from host: String = "one.example",
    boostedBy: String? = nil,
    tags: [String] = [],
    media: [String] = []
) -> Post {
    Post(
        uri: uri,
        originURI: originURI,
        socialProtocol: .mastodon,
        sourceURL: "https://\(host)",
        createdAt: Date(timeIntervalSince1970: seconds),
        authorId: "https://\(host)/users/someone",
        authorName: "someone",
        authorHandle: "@someone@\(host)",
        text: "hello",
        mediaURLs: media.compactMap(URL.init(string:)),
        tags: tags,
        boostedBy: boostedBy,
        boostedById: boostedBy.map { "https://booster.example/users/\($0)" },
        sources: [host]
    )
}
