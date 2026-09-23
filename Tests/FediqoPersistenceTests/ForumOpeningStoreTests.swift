import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// A forum row's opening post, kept on this device with the row — #154.
@Suite("A forum post's words kept with its row")
struct ForumOpeningStoreTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let forum = Source(host: "bbs.example", kind: .discuz)

    private func thread(_ tid: Int, opening: ForumOpening? = nil) -> Note {
        Note(
            id: "discuz:bbs.example:\(tid)", source: forum, author: "小北", handle: "@小北@bbs.example",
            body: "", title: "旧插座", board: "家居", postedAt: origin, categories: [.board(id: "7")],
            opening: opening
        )
    }

    private let opening = ForumOpening(
        words: "旧插座该换了。",
        quoted: [DiscuzQuotation(words: "上次说的", quoting: [DiscuzQuotation(words: "更早的一句")])],
        avatarURL: URL(string: "https://bbs.example/uc_server/avatar.php?uid=71")
    )

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test("The words, every level of what they quoted, and the face come back after a relaunch")
    func theOpeningSurvivesARelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await StoreFile(at: dir).save(
            sources: [forum], notes: [thread(1, opening: opening), thread(2)]
        )
        let opened = StoreFile.open(at: dir)
        #expect(!opened.storeIsNewer)
        #expect(opened.notes.first { $0.id == "discuz:bbs.example:1" }?.opening == opening)
        #expect(opened.notes.first { $0.id == "discuz:bbs.example:2" }?.opening == nil,
                "a row nobody reached came back with words")
        // A post with no words is an answer too, and is kept as one.
        try await StoreFile(at: dir).save(
            sources: [forum], notes: [thread(3, opening: ForumOpening(words: ""))]
        )
        #expect(StoreFile.open(at: dir).notes.first?.opening == ForumOpening(words: ""))
    }

    /// The two compatibility lines of the acceptance, asked of the file itself.
    @Test("The opening adds no migration of its own, and an earlier build's reading of a row still decodes it")
    func bothWaysRoundTheVersions() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await StoreFile(at: dir).save(sources: [forum], notes: [thread(1, opening: opening), thread(2)])
        let index = dir.appendingPathComponent("index.sqlite")
        var readOnly = Configuration()
        readOnly.readonly = true
        let queue = try DatabaseQueue(path: index.path, configuration: readOnly)
        let (migrations, facts) = try await queue.read { db in
            (
                try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"),
                try String.fetchAll(db, sql: "SELECT facts FROM note ORDER BY id")
            )
        }
        // No migration id of its own is written, so a build that knows the rest finds nothing
        // it does not know and opens the store rather than setting it aside as a newer build's.
        // `v3-holding` is #175's, which does mean an older build to refuse it.
        #expect(migrations == ["v1-index", "v2-categories", "v3-holding"])
        #expect(facts[0].contains(#""opening""#))
        #expect(!facts[1].contains(#""opening""#), "a row nobody reached is written as before")
        // What an earlier build decodes a row into: the facts it knew, and nothing else.
        for json in facts {
            let earlier = try JSONDecoder().decode(EarlierFacts.self, from: Data(json.utf8))
            #expect(earlier.author == "小北" && earlier.title == "旧插座")
        }
    }
}

/// The facts a row carried before #154, as the build before it decodes them: every field it
/// required, no `opening`.
private struct EarlierFacts: Decodable {
    var author: String
    var handle: String
    var body: String
    var title: String?
    var board: String?
    var attachments: [EarlierAttachment]
    var emojis: [EarlierEmoji]
    var statusID: String?
    var boosted: Bool?
    var favourited: Bool?

    struct EarlierAttachment: Decodable {}
    struct EarlierEmoji: Decodable {}
}
