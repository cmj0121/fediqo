import FediqoCore
import Foundation
import Testing

@testable import FediqoUI

/// Letting go of a source leaves the rows that came through the others (#115).
///
/// **Through the session's own Remove**, not the store's: the reader presses Remove on a server
/// and reads the timeline that is left, and "needs no relaunch to be right" is a claim about what
/// the session draws straight after that press. Every figure below is read from
/// `timelineItems(latest:)`, the list the stream draws, so a drawn list kept from before the
/// press would be caught.
@MainActor
@Suite("Letting go of a source")
struct LettingGoTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let first = Source(host: "first.example", kind: .mastodon)
    private let second = Source(host: "second.example", kind: .mastodon)
    private let third = Source(host: "third.example", kind: .pleroma)
    private let shared = "https://origin.example/users/ada/statuses/1"
    private let onlySecond = "https://second.example/users/bob/statuses/2"

    @Test("Removing the copy a merged row was drawn as leaves the row, drawn as the other")
    func removingTheDrawnCopy() async {
        let session = await joined()
        let before = session.timelineItems(latest: nil).first { $0.noteID == shared }
        #expect(before?.source.host == "first.example", "the first to arrive is the one drawn")

        await session.remove(host: "first.example")

        let after = session.timelineItems(latest: nil).first { $0.noteID == shared }
        #expect(after?.source.host == "second.example")
        #expect(after?.body == "as second carried it")
        #expect(after?.sources.map(\.host) == ["second.example"])
        #expect(after?.otherCopies.isEmpty == true)
    }

    @Test("Removing the other copy leaves the row as it was drawn, naming one source")
    func removingTheOtherCopy() async {
        let session = await joined()

        await session.remove(host: "second.example")

        let after = session.timelineItems(latest: nil).first { $0.noteID == shared }
        #expect(after?.source.host == "first.example")
        #expect(after?.body == "as first carried it")
        #expect(after.map { DummyItemRow.drawnSource($0, language: .english) } == "first.example")
    }

    @Test("Removing a source takes the rows only it carried, and nothing else")
    func removingTakesOnlyItsOwn() async {
        let session = await joined()
        #expect(Set(session.timelineItems(latest: nil).map(\.noteID)) == [shared, onlySecond])

        await session.remove(host: "second.example")

        #expect(session.timelineItems(latest: nil).map(\.noteID) == [shared])
        // Underneath, exactly that server's copies went: the other's copy of the shared post
        // is the one thing left, stamped with its own host.
        let held = await session.store.snapshot().notes
        #expect(held.map(\.key) == [NoteKey(host: "first.example", id: shared)])
    }

    @Test("The copies stay separate underneath while they are drawn as one")
    func aMergeHoldsNothingLess() async {
        let session = await joined()
        #expect(session.timelineItems(latest: nil).count == 2)
        #expect(await session.store.snapshot().notes.count == 3)
    }

    @Test("Joining a third merges its copy into a row already merged from two")
    func aThirdJoins() async {
        let session = await joined()

        await take(session, source: third, notes: [copy(from: third, body: "as third carried it")])

        let row = session.timelineItems(latest: nil).first { $0.noteID == shared }
        #expect(row?.sources.map(\.host) == ["first.example", "second.example", "third.example"])
        #expect(row?.copies.map(\.body) == ["as first carried it", "as second carried it", "as third carried it"])
    }

    @Test("Joining a source back merges again, with nothing lost in between")
    func joiningBack() async {
        let session = await joined()
        await session.remove(host: "first.example")

        await take(session, source: first, notes: [copy(from: first, body: "as first carried it")])

        let row = session.timelineItems(latest: nil).first { $0.noteID == shared }
        // Both copies again. The one that stayed is now the one that arrived first.
        #expect(row?.sources.map(\.host) == ["second.example", "first.example"])
        #expect(row?.body == "as second carried it")
        #expect(Set(session.timelineItems(latest: nil).map(\.noteID)) == [shared, onlySecond])
    }

    @Test("Nothing a merge did survives the removal of both sources behind it")
    func removingBoth() async {
        let session = await joined()

        await session.remove(host: "first.example")
        await session.remove(host: "second.example")

        #expect(session.timelineItems(latest: nil).isEmpty)
        #expect(await session.store.snapshot().notes.isEmpty)
        // And joining one of them back is a post from one source, not a merge remembered.
        await take(session, source: second, notes: [copy(from: second, body: "as second carried it")])
        let row = session.timelineItems(latest: nil).first { $0.noteID == shared }
        #expect(row?.sources.map(\.host) == ["second.example"])
    }

    /// Two sources carrying one post, `first`'s copy taken in first, and a post only `second`
    /// carried — drawn once, so the list the stream holds is a list that was already drawn.
    private func joined() async -> ShellSession {
        let session = ShellSession(http: FixtureHTTP(), pictures: ShellPictures(http: FixtureHTTP()))
        await take(session, source: first, notes: [copy(from: first, body: "as first carried it")])
        await take(session, source: second, notes: [
            copy(from: second, body: "as second carried it"),
            Note(
                id: onlySecond, source: second, author: "Bob", handle: "@bob@second.example",
                body: "only here", postedAt: origin.addingTimeInterval(-60), categories: [.public]
            ),
        ])
        return session
    }

    /// A join as the session finishes one: the store filled, then the session brought level with
    /// it — the lines `adopt()` runs — and the stream drawn once, as a reader would see it.
    private func take(_ session: ShellSession, source: Source, notes: [Note]) async {
        await session.store.add(source)
        await session.store.ingest(notes)
        session.sources = await session.store.sources()
        session.notes = await session.store.all()
        session.rebuildQueries()
        _ = session.timelineItems(latest: nil)
    }

    private func copy(from source: Source, body: String) -> Note {
        Note(
            id: shared, source: source, author: "Ada", handle: "@ada@origin.example", body: body,
            postedAt: origin, categories: [.public]
        )
    }
}
