import Foundation
import Testing
@testable import FediqoCore

/// #314: what this device holds of somebody muted or blocked — or of everybody of a server — is
/// let go where the person chose it: exactly their rows through that source, and never a post the
/// person keeps.
@Suite("Letting go of what is held of whom the person muted or blocked")
struct HeldAuthorsTests {
    private static let alpha = Source(host: "alpha.test", kind: .mastodon)
    private static let beta = Source(host: "beta.test", kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private static func note(_ id: String, by handle: String, from source: Source = alpha, kept: Bool = false) -> Note {
        var note = Note(
            id: id, source: source, author: "Somebody", handle: handle, body: "hello",
            postedAt: origin.addingTimeInterval(Double(id.count) * 60), categories: [.public]
        )
        note.kept = kept
        return note
    }

    private static func held() -> ItemStore {
        ItemStore(sources: [alpha, beta], notes: [
            note("a1", by: "@ada@alpha.test"), note("a2", by: "@Ada@alpha.test"), note("a3", by: "@ada@alpha.test", kept: true),
            note("b1", by: "@bea@far.example"), note("b2", by: "@cy@far.example"), note("c1", by: "@cy@near.example"),
            note("x1", by: "@ada@alpha.test", from: beta), note("x2", by: "@bea@far.example", from: beta),
        ])
    }

    @Test("One person's rows through one source go, whatever the case of their handle; a post the person keeps stays, and nobody else's, nor theirs through another source, moves")
    func onePerson() async {
        let store = Self.held()
        let revision = await store.revision
        #expect(await store.letGo(by: .person("@ada@alpha.test", at: "Alpha.Test")) == 2)
        #expect(await store.all().map(\.id).sorted() == ["a3", "b1", "b2", "c1", "x1", "x2"])
        #expect(await store.revision > revision, "a save follows")
        #expect(await store.sources() == [Self.alpha, Self.beta], "every source stays joined")
    }

    @Test("Everybody of one server goes through one source, by the server their handle names and by no other; nothing of another server or another source moves")
    func aWholeServer() async {
        let store = Self.held()
        #expect(await store.letGo(by: .server("Far.Example", at: Self.alpha.host)) == 2)
        #expect(await store.all().map(\.id).sorted() == ["a1", "a2", "a3", "c1", "x1", "x2"])
    }

    @Test("Nobody's rows held, and nothing changes and nothing is saved")
    func nothingHeld() async {
        let store = Self.held()
        let revision = await store.revision
        #expect(await store.letGo(by: .person("@nobody@alpha.test", at: Self.alpha.host)) == 0)
        #expect(await store.letGo(by: .server("none.example", at: Self.alpha.host)) == 0)
        #expect(await store.revision == revision)
    }

    @Test("Whose a row is, is what made it says: a handle the same but for case, a server named by the last part alone, and a row with no handle is nobody's")
    func whoseARowIs() {
        let person = HeldAuthors.person("@ada@alpha.test", at: "ALPHA.test")
        #expect(person.wrote(Self.note("1", by: "@ADA@alpha.test")))
        #expect(!person.wrote(Self.note("1", by: "@ada@alpha.test", from: Self.beta)))
        #expect(!person.wrote(Self.note("1", by: "@adam@alpha.test")))
        let server = HeldAuthors.server("far.example", at: "alpha.test")
        #expect(server.wrote(Self.note("1", by: "@x@far.example")))
        #expect(!server.wrote(Self.note("1", by: "@x@notfar.example")) && !server.wrote(Self.note("1", by: "@far.example@else.example")))
        #expect(!server.wrote(Self.note("1", by: "")) && !person.wrote(Self.note("1", by: "")))
    }
}
