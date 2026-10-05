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
        await store.ingest([note("1")], ifSourceHere: source.host)
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

        await store.ingest([note("3")], ifSourceHere: source.host)
        #expect(await heard.next() == landed + 1, "what a search brings is a change too: a save must write it")
    }

    // MARK: - One way of holding (#296)

    @Test("A post a search brought is an item like any other: in All at once and after a relaunch, written down, and in no category's timeline it did not arrive through")
    func whatASearchBringsStandsInAll() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        await store.ingest([note("found", categories: [])], ifSourceHere: source.host)
        #expect(Set(await store.all().map(\.id)) == ["1", "found"], "All grows by what a search brought")
        #expect(await store.trends().isEmpty, "it arrived through no category")
        #expect(await store.note(NoteKey(host: source.host, id: "found"))?.categories.isEmpty == true)
        #expect(await store.snapshot().notes.map(\.id) == ["1", "found"], "a save writes it")

        let snapshot = await store.snapshot()
        let relaunched = ItemStore(sources: snapshot.sources, notes: snapshot.notes)
        #expect(Set(await relaunched.all().map(\.id)) == ["1", "found"], "and a relaunch finds it there")
    }

    @Test("A post a search brought that a timeline then brings is one row, with the timeline's category added")
    func foundThenArrived() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        await store.ingest([note("1"), note("2", categories: [])], ifSourceHere: source.host)
        #expect(Set(await store.all().map(\.id)) == ["1", "2"])
        await store.ingest([note("2", categories: [.home])], ifSourceHere: source.host)
        #expect(await store.all().count == 2)
        #expect(await store.note(NoteKey(host: source.host, id: "2"))?.categories == [.home])
        #expect(await !store.refresh([note("2", categories: [.home])], ifSourceHere: source.host))
    }

    @Test("A post a search brought is drawn as it lands and again as it is read again, like any other")
    func aFindIsDrawnAndDrawnAgain() async {
        let store = ItemStore(sources: [source], notes: [note("1")])
        await store.ingest([note("found")], ifSourceHere: source.host)
        #expect(await store.drawn == 1, "an item: written down, and drawn")
        #expect(await store.refresh([note("found", body: "edited")], ifSourceHere: source.host))
        #expect(Set(await store.all().map(\.id)) == ["1", "found"])
        #expect(await store.note(NoteKey(host: source.host, id: "found"))?.body == "edited")
        #expect(await store.drawn == 2)
        #expect(await store.revision == 2, "and both are there for a save to write")
        #expect(await store.refresh([note("1", body: "edited")], ifSourceHere: source.host))
        #expect(await store.drawn == 3)
    }

    @Test("Nothing is held for a host that is not a source here")
    func asideNeedsASource() async {
        let store = ItemStore(sources: [source], notes: [])
        let stranger = Note(
            id: "x", source: other, author: "Bo", handle: "@bo@second.example", body: "hi",
            postedAt: origin, categories: []
        )
        await store.ingest([stranger], ifSourceHere: other.host)
        #expect(await store.snapshot().notes.isEmpty)
        #expect(await store.revision == 0)
    }
}
