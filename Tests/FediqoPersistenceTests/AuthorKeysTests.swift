import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// #314: the file names every row one person made through one source — or everybody of one
/// server — that a mute or a block lets go, read or not, kept rows aside.
@Suite("The file's rows of whom the person muted or blocked")
struct AuthorKeysTests {
    private static let alpha = Source(host: "alpha.test", kind: .mastodon)
    private static let beta = Source(host: "beta.test", kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private static func note(_ id: String, by handle: String, from source: Source = alpha, kept: Bool = false) -> Note {
        var note = Note(
            id: id, source: source, author: "Somebody", handle: handle, body: "hello",
            postedAt: origin.addingTimeInterval(60), categories: [.public]
        )
        note.kept = kept
        return note
    }

    @Test("By handle whatever its case, through the one source; by the server a handle names; never a kept row, and never a row with no handle")
    func keys() async throws {
        let file = try StoreFile(database: DatabaseQueue())
        let notes = [
            Self.note("a1", by: "@ada@alpha.test"), Self.note("a2", by: "@ADA@alpha.test"), Self.note("a3", by: "@ada@alpha.test", kept: true),
            Self.note("b1", by: "@bea@far.example"), Self.note("b2", by: "@cy@far.example"), Self.note("c1", by: "@cy@notfar.example"),
            Self.note("n1", by: ""), Self.note("x1", by: "@ada@alpha.test", from: Self.beta),
        ]
        try await file.save(sources: [Self.alpha, Self.beta], notes: notes, said: [])
        let person = try file.keys(.authors(.person("@ada@alpha.test", at: Self.alpha.host)))
        #expect(Set(person.map(\.id)) == ["a1", "a2"] && person.allSatisfy { $0.host == Self.alpha.host })
        let server = try file.keys(.authors(.server("far.example", at: Self.alpha.host)))
        #expect(Set(server.map(\.id)) == ["b1", "b2"])
        #expect(try file.keys(.authors(.server("far.example", at: Self.beta.host))).isEmpty)
    }
}
