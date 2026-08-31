import Foundation
import GRDB
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
    socialProtocol: SocialProtocol = .mastodon,
    authorId: String? = nil,
    text: String = "hello",
    audience: Audience? = nil,
    boostedBy: String? = nil,
    tags: [String] = [],
    media: [String] = []
) -> Post {
    Post(
        uri: uri,
        originURI: originURI,
        socialProtocol: socialProtocol,
        sourceURL: "https://\(host)",
        createdAt: Date(timeIntervalSince1970: seconds),
        authorId: authorId ?? "https://\(host)/users/someone",
        authorName: "someone",
        authorHandle: "@someone@\(host)",
        text: text,
        attachments: media.compactMap(URL.init(string:)).map(Attachment.unknown(displaying:)),
        audience: audience,
        tags: tags,
        boostedBy: boostedBy,
        boostedById: boostedBy.map { "https://booster.example/users/\($0)" },
        sources: [host]
    )
}

/// One number out of the store — a count, or any single-column, single-row answer.
func count(_ store: LocalStore, _ sql: String, _ arguments: StatementArguments = []) async throws -> Int {
    try await store.read { db in try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0 }
}

/// A fresh directory of its own, for a store that has to live in a file.
func scratchDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
