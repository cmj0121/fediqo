import Foundation
@testable import FediqoCore

/// A post with only the fields a test cares about filled in. Shared so two suites cannot
/// drift into two subtly different ideas of what a post looks like.
func makePost(
    uri: String,
    at seconds: TimeInterval,
    from host: String = "one.example",
    boostedBy: String? = nil,
    media: [String] = []
) -> Post {
    Post(
        uri: uri,
        createdAt: Date(timeIntervalSince1970: seconds),
        authorName: "someone",
        authorHandle: "@someone@\(host)",
        text: "hello",
        mediaURLs: media.compactMap(URL.init(string:)),
        boostedBy: boostedBy,
        sources: [host]
    )
}
