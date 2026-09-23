import Foundation
import Testing
@testable import FediqoCore

/// What a source brings lands in the store first, and the store says so when it changed (#175).
@Suite("A landing goes through the store")
struct LandingTests {
    private let source = Source(host: "first.example", kind: .mastodon)
    private let other = Source(host: "second.example", kind: .mastodon)
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func note(_ id: String, body: String = "hello", categories: Set<FediqoCore.Category> = [.public]) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada@first.example", body: body,
            postedAt: origin, categories: categories
        )
    }

    // MARK: - What was already true, held from now on

    @Test("Two landings of one post leave one row, one after the other or both at once")
    func twoLandingsOneRow() async {
        let store = ItemStore(sources: [source], notes: [])
        await store.ingest([note("1")], ifSourceHere: source.host)
        await store.ingest([note("1", categories: [.trends])], ifSourceHere: source.host)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await store.ingest([note("2")], ifSourceHere: source.host) }
            }
        }
        #expect(await store.all().map(\.id) == ["1", "2"])
        #expect(await store.all().first?.categories == [.public, .trends], "the second landing widened the one row")
        #expect(await store.snapshot().notes.count == 2)
    }

    // MARK: - Nothing new, nothing written

    @Test("A landing that brings nothing new moves no revision, so nothing is written or renewed")
    func nothingNewMovesNothing() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        let before = await store.revision
        await store.ingest([note("1")], ifSourceHere: source.host)
        #expect(await store.revision == before, "the same page answered again")
        #expect(await !store.refresh([note("1")], ifSourceHere: source.host), "the same words read again")
        #expect(await store.revision == before)
        await store.hold([note("1")], ifSourceHere: source.host)
        #expect(await store.revision == before, "a row a timeline brought, found again by a search")

        #expect(await store.refresh([note("1", body: "edited")], ifSourceHere: source.host))
        #expect(await store.revision == before + 1, "an edit is a change")
    }

    @Test("The store tells a listener each time it really changed, and only then")
    func changesAreAnnounced() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        let changes = await store.changes()
        var heard = changes.makeAsyncIterator()

        await store.ingest([note("1")], ifSourceHere: source.host)
        await store.ingest([note("2")], ifSourceHere: source.host)
        let landed = await store.revision
        #expect(await heard.next() == landed, "the landing that brought something")
        #expect(landed == 1, "the landing that brought nothing moved nothing before it")

        await store.hold([note("3")], ifSourceHere: source.host)
        #expect(await heard.next() == landed + 1, "a row held aside is a change too: a save must write it")
    }

    // MARK: - Held, not arrived

    @Test("A post held aside is not in All nor Trends, and is still here to be read and written down")
    func asideIsHeldNotShown() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        await store.hold([note("found", categories: [.trends])], ifSourceHere: source.host)
        #expect(await store.all().map(\.id) == ["1"], "All did not grow because a search was made")
        #expect(await store.trends().isEmpty)
        let held = await store.note(NoteKey(host: source.host, id: "found"))
        #expect(held?.holding == .aside)
        #expect(await store.snapshot().notes.map(\.id) == ["1", "found"], "a save writes it")

        let snapshot = await store.snapshot()
        let relaunched = ItemStore(sources: snapshot.sources, notes: snapshot.notes)
        #expect(await relaunched.all().map(\.id) == ["1"], "and a relaunch still keeps it out of All")
    }

    @Test("Holding only widens: a post held aside that arrives joins All, and one that arrived stays")
    func holdingOnlyWidens() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        await store.hold([note("1"), note("2")], ifSourceHere: source.host)
        #expect(await store.all().map(\.id) == ["1"], "found again aside, it did not leave All")
        await store.ingest([note("2")], ifSourceHere: source.host)
        #expect(await store.all().map(\.id) == ["1", "2"], "arrived through a timeline, it is in All")
        #expect(await !store.refresh([note("2")], ifSourceHere: source.host))
        #expect(await store.note(NoteKey(host: source.host, id: "2"))?.holding == .arrived)
    }

    @Test("A post held aside and read again stays aside; only what is drawn moves the drawn count")
    func readAgainKeepsItAside() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        await store.hold([note("found")], ifSourceHere: source.host)
        #expect(await store.drawn == 0, "held aside: written down, drawn nowhere")
        #expect(await store.refresh([note("found", body: "edited")], ifSourceHere: source.host))
        #expect(await store.all().map(\.id) == ["1"], "a read again is not an arrival")
        #expect(await store.note(NoteKey(host: source.host, id: "found"))?.body == "edited")
        #expect(await store.drawn == 0)
        #expect(await store.revision == 2, "yet both are there for a save to write")
        #expect(await store.refresh([note("1", body: "edited")], ifSourceHere: source.host))
        #expect(await store.drawn == 1)
    }

    @Test("Nothing is held aside for a host that is not a source here")
    func asideNeedsASource() async {
        let store = ItemStore(sources: [source], notes: [])
        let stranger = Note(
            id: "x", source: other, author: "Bo", handle: "@bo@second.example", body: "hi",
            postedAt: origin, categories: []
        )
        await store.hold([stranger], ifSourceHere: other.host)
        #expect(await store.snapshot().notes.isEmpty)
        #expect(await store.revision == 0)
    }
}
