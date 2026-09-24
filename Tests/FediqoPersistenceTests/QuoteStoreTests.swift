import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// A post's quote, kept on this device with the row — #214.
@Suite("A quote kept with its row")
struct QuoteStoreTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let source = Source(host: "one.example", kind: .mastodon)

    private var quoted: QuotedPost {
        QuotedPost(
            id: "https://one.example/users/ada/statuses/1", statusID: "1", author: "Ada",
            handle: "@ada@one.example", body: "Under the cover", postedAt: origin,
            avatarURL: URL(string: "https://one.example/ada.png"),
            attachments: [Attachment(
                kind: .image, url: URL(string: "https://one.example/full.png"),
                previewURL: URL(string: "https://one.example/small.png"), alt: "A red square",
                width: 16, height: 16
            )],
            sensitive: true, spoiler: "A spoiler",
            emojis: [CustomEmoji(shortcode: "blob", url: URL(string: "https://one.example/blob.png")!)],
            url: URL(string: "https://one.example/@ada/1"), audience: .everyone,
            reply: Reply(handle: "@cyd@one.example", inReplyToId: "0"),
            quoting: NestedQuote(state: .accepted, statusID: "0")
        )
    }

    private func note(_ id: String, quote: Quote?) -> Note {
        Note(
            id: "https://one.example/users/bob/statuses/\(id)", source: source, author: "Bob",
            handle: "@bob@one.example", body: "Bob quotes", postedAt: origin.addingTimeInterval(60),
            categories: [.public], statusID: id, quote: quote
        )
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test("The quoted post, its cover, what it carries and its own quote come back after a relaunch")
    func survivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let accepted = Quote(state: .accepted, post: quoted)
        let revoked = Quote(state: .revoked)
        let held = quoted.note(through: source)
        try await StoreFile(at: dir).save(
            sources: [source],
            notes: [note("2", quote: accepted), note("3", quote: revoked), note("4", quote: nil), held]
        )
        let opened = StoreFile.open(at: dir)
        let byID = Dictionary(uniqueKeysWithValues: opened.notes.map { ($0.statusID, $0) })
        #expect(byID["2"]?.quote == accepted)
        #expect(byID["3"]?.quote == revoked)
        #expect(byID["4"]?.quote == nil)
        // The quoted post itself, held aside, opens with the network off.
        #expect(byID["1"]?.holding == .aside)
        #expect(byID["1"]?.body == "Under the cover")
        #expect(byID["1"]?.quote == Quote(state: .accepted, statusID: "0"))
    }
}
