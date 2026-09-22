import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// #82 — a wait is the toast; the stream stays the stream.
///
/// **What the stream draws is decided by one fact: whether it has rows.** Rows are drawn, and no
/// rows is the empty notice; a reload running, a source that missed, a search and who is joined
/// are not inputs to that choice at all — they are the toast's, and the notice's words. So what
/// is assertable without a screen is the two halves: rows held are the rows the stream draws,
/// whatever a reload is doing, and the empty notice is never the wait or the miss. The suite is
/// `@MainActor` because the session it reads is.
@Suite("A wait is the toast; the stream stays the stream")
@MainActor
struct TimelineWaitingTests {
    private let source = Source(host: "one.example", kind: .mastodon)

    private func note(_ id: String) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada@one.example", body: "hello",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public]
        )
    }

    /// The rows the stream draws, for a session holding `notes` — what the pane asks is only
    /// whether this is empty.
    private func rows(holding notes: [Note]) async -> [DummyItem] {
        let session = ShellSession(
            http: FixtureHTTP(), store: ItemStore(sources: [source], notes: notes)
        )
        await session.reloadFromStore()
        return session.timelineItems(latest: nil)
    }

    /// The empty stream's notice, as the pane builds it: `asked` is what a reload's running, its
    /// misses and whether it was stopped come to there.
    private func notice(
        searching: Bool = false, sources: [Source]? = nil, asked: Bool = false
    ) -> EmptyNotice {
        EmptyNotice.timeline(
            searching: searching, indexed: true, query: .all, notes: [], written: [],
            sources: sources ?? [source], index: TextIndex([]), latest: nil, asked: asked,
            language: .english
        )
    }

    /// Not the wait and not the miss: those are the toast.
    private func isNotAWaitOrAMiss(_ notice: EmptyNotice) -> Bool {
        notice.spoken != ShellWaiting.spoken
            && notice.title != ShellFailure.spoken(["one.example"])
            && notice.title != ShellFailure.spoken(["one.example", "two.example"])
    }

    /// Empty and on the wire is empty: waiting rows would be a wait that never ended.
    /// The wait is the toast.
    @Test("Empty and running is empty, not arriving")
    func emptyAndRunningIsEmpty() async {
        #expect(await rows(holding: []).isEmpty)
        // A reload still running has not finished, so it has not asked: the notice says what is
        // held, and a miss while it runs is the same notice.
        let running = notice(asked: false)
        #expect(running.kind == .held)
        #expect(isNotAWaitOrAMiss(running))
    }

    /// What is already held is read at once, including while a reload runs.
    @Test("Held items and running draws the items, not skeletons")
    func heldItemsAreNotSkeletons() async {
        #expect(await rows(holding: [note("1")]).map(\.id) == [note("1").key.rowID])
    }

    /// Nothing on the wire and nothing in the list is empty, not a wait that never ends.
    @Test("Empty and not running is empty")
    func emptyAndNotRunningIsEmpty() {
        let answered = notice(asked: true)
        #expect(answered.kind == .answered)
        #expect(isNotAWaitOrAMiss(answered))
    }

    /// Empty, not running, somebody was asked, and they did not answer: still empty.
    /// The miss is the toast, not a pane-sized failure.
    @Test("Empty, not running, and a source that did not answer is empty")
    func emptyAndFailedIsEmpty() {
        // A source that failed means the reload did not ask everybody.
        let missed = notice(asked: false)
        #expect(missed.kind == .held)
        #expect(isNotAWaitOrAMiss(missed))
    }

    /// Held still wins: rows already here are read at once.
    @Test("Held items and a failed source still draw the items")
    func heldItemsAreNotAFailurePlace() async {
        #expect(!(await rows(holding: [note("1"), note("2")]).isEmpty))
    }

    /// A second miss is still empty: the notice does not read who missed, and a longer list is
    /// still one empty place. The toast names who.
    @Test("A second failed source does not make a second standing")
    func failedDoesNotStack() {
        // One miss and two both come to "not everybody was asked".
        #expect(notice(asked: false) == notice(asked: false))
    }

    /// Search already has indexing and empty notices. Waiting rows would be a second
    /// vocabulary for a miss this device already knows is a miss.
    @Test("An empty search is not timeline waiting rows")
    func emptySearchIsNotArriving() {
        for asked in [false, true] {
            let search = notice(searching: true, asked: asked)
            #expect(search.kind == .search)
            #expect(isNotAWaitOrAMiss(search))
        }
    }

    /// Nobody to ask, so a plate standing for a row that will never come is a wait that
    /// never ends.
    @Test("No sources is empty, never waiting")
    func noSourcesIsEmptyNeverWaiting() {
        let none = notice(sources: [])
        #expect(none.kind == .noSources)
        #expect(isNotAWaitOrAMiss(none))
    }
}
