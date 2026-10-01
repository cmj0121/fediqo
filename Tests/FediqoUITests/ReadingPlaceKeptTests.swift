import Foundation
@testable import FediqoCore
import Testing
@testable import FediqoUI

/// #273: where reading stands is written down as it moves — the timeline in front, its lamp, its
/// top row and the conversation open over it — and by nothing else.
///
/// The session is driven the way its two callers drive it: the pane writes `scrolledTop`, a tab
/// writes `timelineID`, and the root view says what its lamp and walk stand on (`stands`), which
/// `ReadingPlace.standing` works out and is asked here over a walk of its own.
@Suite("Where reading stands is written down as it moves")
@MainActor
struct ReadingPlaceKeptTests {
    private static let microblog = Source(host: "m.example", kind: .mastodon)

    init() {
        L10n.language = .english
    }

    /// A session and the defaults its place is kept in.
    private final class Desk {
        let defaults = CountingDefaults()
        let session: ShellSession

        @MainActor
        init(store: ItemStore = ItemStore()) {
            session = ShellSession(
                http: FixtureHTTP([:]), store: store,
                timelines: WrittenTimelineStore(defaults: defaults),
                place: ReadingPlaceStore(defaults: defaults)
            )
        }

        /// What is kept, read the way a relaunch reads it.
        var kept: ReadingPlace? { ReadingPlaceStore(defaults: defaults).load() }
    }

    /// A session with a microblog joined and All in front, landed: its moves are written.
    private func landed() -> Desk {
        let desk = Desk()
        desk.session.sources = [Self.microblog]
        desk.session.rebuildQueries()
        desk.session.keepPlaceFromHere()
        return desk
    }

    // MARK: Acceptance: every change leaves the place equal to the last state

    @Test("A timeline, a lamp, a top row and a conversation each write the place as it then stands")
    func eachMoveIsWritten() {
        let desk = landed()
        let session = desk.session
        #expect(desk.kept == nil)

        session.timelineID = .trends
        #expect(desk.kept == ReadingPlace(timeline: .trends))

        session.stands(ReadingPlace.Standing(lamp: "t2"))
        #expect(desk.kept == ReadingPlace(timeline: .trends, lamp: "t2"))

        session.scrolledTop = "t1"
        #expect(desk.kept == ReadingPlace(timeline: .trends, lamp: "t2", top: "t1"))

        // A conversation opened: the place still names its timeline, its lamp and its top row.
        session.stands(ReadingPlace.Standing(lamp: "t2", thread: "t2"))
        #expect(desk.kept == ReadingPlace(timeline: .trends, lamp: "t2", top: "t1", thread: "t2"))

        session.stands(ReadingPlace.Standing(lamp: "t2"))
        #expect(desk.kept == ReadingPlace(timeline: .trends, lamp: "t2", top: "t1"))

        session.scrolledTop = "t3"
        session.stands(ReadingPlace.Standing())
        #expect(desk.kept == ReadingPlace(timeline: .trends, top: "t3"))
        #expect(desk.kept == session.readingPlace)
        #expect(desk.defaults.writes == 7)
    }

    @Test("A timeline switched takes none of the one left: no lamp, no top row, no conversation")
    func aSwitchCarriesNothing() {
        let desk = landed()
        let session = desk.session
        session.stands(ReadingPlace.Standing(lamp: "a3", thread: "a3"))
        session.scrolledTop = "a2"
        #expect(desk.kept == ReadingPlace(timeline: .all, lamp: "a3", top: "a2", thread: "a3"))

        session.timelineID = .trends
        #expect(session.scrolledTop == nil)
        #expect(desk.kept == ReadingPlace(timeline: .trends))

        // The root then says what the timeline arrived at stands on — the same post, where both
        // hold it — and it is that timeline's.
        session.stands(ReadingPlace.Standing(lamp: "a3"))
        #expect(desk.kept == ReadingPlace(timeline: .trends, lamp: "a3"))
    }

    @Test("A written timeline put in front, and the tab to its left once it is removed, are each written")
    func writtenTimeline() throws {
        let desk = landed()
        let session = desk.session
        var draft = TimelineDraft(new: 1)
        draft.name = "Mine"
        draft.rules = [try #require(Rule.source("m.example"))]
        session.commit(draft)
        let mine = try #require(session.written.first).id
        #expect(desk.kept == ReadingPlace(timeline: .written(mine)))

        session.stands(ReadingPlace.Standing(lamp: "m1"))
        session.removeTimeline(mine)
        #expect(session.timelineID == .trends)
        #expect(desk.kept == ReadingPlace(timeline: .trends))
    }

    @Test("The place as it already stands is not written again")
    func unmovedIsNotWritten() {
        let desk = landed()
        let session = desk.session
        session.stands(ReadingPlace.Standing(lamp: "a3"))
        session.scrolledTop = "a1"
        #expect(desk.defaults.writes == 2)

        session.timelineID = .all
        session.stands(ReadingPlace.Standing(lamp: "a3"))
        session.scrolledTop = "a1"
        session.rebuildQueries()
        #expect(desk.defaults.writes == 2)
    }

    // MARK: A change of tab: what it does to the lamp

    /// **The acceptance proof is hosted** (`ReadingPlaceHostedTests.aTabChange`), where the pane
    /// is taken away and put back as a tab does it. Here is the one half of a tab change that
    /// moves the lamp: the search it closes at the root, which hands the lamp back to the post it
    /// parked. The pages it closes on the session are set as well, as a guard: nothing leads from
    /// them to the place today, and this says so if something ever does.
    @Test("A search closed by a change of tab hands the lamp back, and writes nothing")
    func aTabChangeWritesNothing() {
        let desk = landed()
        let session = desk.session
        session.stands(ReadingPlace.Standing(lamp: "a3"))
        session.scrolledTop = "a1"
        let kept = desk.kept
        let writes = desk.defaults.writes

        session.usageOpened = "m.example"
        session.usageOpened = nil
        session.preferencesOpened = nil

        // A search open over the timeline with a result lit, then closed by the tab: the lamp
        // goes from the result to the parked post, and the timeline's lamp was that post all along.
        let open = ReadingPlace.standing(lamp: "a2", walk: ShellWalk(), searching: true, parked: "a3")
        session.stands(open)
        let closed = ReadingPlace.standing(lamp: "a3", walk: ShellWalk(), searching: false, parked: nil)
        session.stands(closed)

        #expect(open == closed)
        #expect(desk.defaults.writes == writes)
        #expect(desk.kept == kept)
    }

    // MARK: Nothing to stand on, and nothing before the launch has landed

    @Test("With nothing joined there is no place, and nothing is written")
    func nothingJoined() {
        let desk = Desk()
        let session = desk.session
        session.rebuildQueries()
        session.keepPlaceFromHere()

        session.stands(ReadingPlace.Standing(lamp: "a3", thread: "a3"))
        session.scrolledTop = "a1"
        #expect(session.readingPlace == nil)
        #expect(desk.defaults.writes == 0)

        // The first source joined puts All in front, and that is a place.
        session.sources = [Self.microblog]
        session.rebuildQueries()
        #expect(desk.kept == ReadingPlace(timeline: .all))
    }

    /// The tabs rebuilt for nothing joined, which writes nothing by itself. The person's own
    /// act of removing the last source is `ShellSession.remove`, and that one takes the place
    /// kept away (`ReadingPlaceLeftBehindTests.lastSourceRemoved`).
    @Test("The tabs rebuilt with nothing joined write nothing: the place kept is as it was")
    func lastSourceRemoved() {
        let desk = landed()
        let session = desk.session
        session.timelineID = .trends
        session.stands(ReadingPlace.Standing(lamp: "t2"))
        let writes = desk.defaults.writes

        session.sources = []
        session.rebuildQueries()
        #expect(session.timelineID == nil)
        #expect(desk.kept == ReadingPlace(timeline: .trends, lamp: "t2"))
        #expect(desk.defaults.writes == writes)
    }

    /// The order a launch needs: a timeline comes in front as the store is adopted — the one
    /// kept, since #273's landing — before its lamp and top row have been come back to, and the
    /// place kept must still be there to read.
    @Test("Until the launch has landed nothing is written, and landing itself writes nothing")
    func nothingBeforeLanding() {
        let desk = Desk()
        let session = desk.session
        let stopped = ReadingPlace(timeline: .trends, lamp: "t2", top: "t1", thread: "t2")
        ReadingPlaceStore(defaults: desk.defaults).save(stopped)
        let writes = desk.defaults.writes

        session.sources = [Self.microblog]
        session.rebuildQueries()
        #expect(session.timelineID == .trends)
        session.scrolledTop = "a1"
        session.stands(ReadingPlace.Standing(lamp: "a3"))
        #expect(!session.keepsPlace)
        #expect(desk.kept == stopped)

        session.keepPlaceFromHere()
        #expect(desk.kept == stopped)
        #expect(desk.defaults.writes == writes)

        // The first move after it is written, with everything the session stood on before it.
        session.scrolledTop = "a2"
        #expect(desk.kept == ReadingPlace(timeline: .trends, lamp: "a3", top: "a2"))
    }

    @Test("A place this build cannot read is not written over by a move")
    func unreadableIsLeft() {
        let desk = landed()
        let newer = Data(#"{"version":2,"timeline":"all","lamp":"a3"}"#.utf8)
        desk.defaults.set(newer, forKey: "fediqo.place")

        desk.session.timelineID = .trends
        desk.session.scrolledTop = "t1"
        #expect(desk.defaults.data(forKey: "fediqo.place") == newer)
    }

    /// A guard and no proof: with no store there is nothing a wrong write could land in.
    @Test("A session that keeps no place still says where it stands")
    func keepsNone() {
        let session = ShellSession(http: FixtureHTTP([:]))
        session.sources = [Self.microblog]
        session.rebuildQueries()
        session.keepPlaceFromHere()
        session.timelineID = .trends
        session.scrolledTop = "t1"
        #expect(session.readingPlace == ReadingPlace(timeline: .trends, top: "t1"))
    }

    // MARK: Acceptance: nothing this device holds changes

    @Test("Writing the place changes no post held, no mark on one, and no other preference")
    func nothingHeldChanges() async throws {
        let store = ItemStore()
        let notes = (1 ... 4).map { n in
            Note(id: "p\(n)", source: Self.microblog, author: "Ada", handle: "@ada@m.example", body: "p\(n)",
                 postedAt: Date(timeIntervalSince1970: Double(n)), categories: n < 3 ? [.public] : [.trends])
        }
        await store.replace(sources: [Self.microblog], notes: notes)
        #expect(await store.markGone(notes[0].key))
        let desk = Desk(store: store)
        let session = desk.session
        // English said first: preferences read set the shell's language, which every suite shares.
        desk.defaults.set("en", forKey: "fediqo.dummy.language")
        let prefs = DummyPrefs(defaults: desk.defaults)
        prefs.latestDate = try #require(LatestDate(year: 2026, month: 9, day: 1))
        await session.reloadFromStore()
        session.keepPlaceFromHere()
        #expect(session.timelineID == .all)

        let before = await store.snapshot()
        let drawn = await store.drawn
        let aside = await store.asideRevision
        let gone = await store.goneCount()
        let settled = await store.settledCount()
        let held = session.notes
        let written = desk.defaults.writes

        session.stands(ReadingPlace.Standing(lamp: "p2"))
        session.scrolledTop = "p1"
        session.timelineID = .trends
        session.stands(ReadingPlace.Standing(lamp: "p4", thread: "p4"))
        session.scrolledTop = "p3"
        // The store's own turn to say what it holds, with the place where it now stands.
        await session.reloadFromStore()
        #expect(desk.kept == ReadingPlace(timeline: .trends, lamp: "p4", top: "p3", thread: "p4"))

        // **The proof is the last two lines**: every value set was the place, so nothing else in
        // the preferences moved. The lines over the store are a guard — the session writes the
        // place with no hand on the store today, and these say so if it is ever given one.
        let after = await store.snapshot()
        #expect(after.revision == before.revision)
        #expect(after.notes == before.notes)
        #expect(after.sources == before.sources)
        #expect(await store.drawn == drawn)
        #expect(await store.asideRevision == aside)
        #expect(await store.goneCount() == gone)
        #expect(await store.settledCount() == settled)
        #expect(session.notes == held)
        // Every value set since was the place, and the latest date reads as it was set.
        #expect(Set(desk.defaults.sets.dropFirst(written).map(\.key)) == ["fediqo.place"])
        #expect(DummyPrefs(defaults: desk.defaults).latestDate == prefs.latestDate)
    }

    // MARK: What is already written is not handed over again

    /// A switch away from a timeline with a top row asks to write twice — once as the top row
    /// is cleared, once for the switch — and both asks are the same place. A switch away from
    /// one with no top row asks once. The second ask of the first must cost what no ask costs.
    @Test("A place asked for twice is written once, and the second ask reads nothing")
    func handedOnce() {
        let desk = landed()
        let session = desk.session

        var reads = desk.defaults.reads
        var writes = desk.defaults.writes
        session.timelineID = .trends
        let asked = desk.defaults.reads - reads
        #expect(desk.defaults.writes - writes == 1)

        session.scrolledTop = "t1"
        reads = desk.defaults.reads
        writes = desk.defaults.writes
        session.timelineID = .all
        #expect(desk.defaults.reads - reads == asked)
        #expect(desk.defaults.writes - writes == 1)
        #expect(desk.kept == ReadingPlace(timeline: .all))
    }

    /// What is kept can be replaced underneath the session — a read back does it — and the place
    /// it last handed over is then no witness to what is kept.
    @Test("Stopped, nothing is written; started again, a place it handed over before is written again")
    func stoppedAndStartedAgain() {
        let desk = landed()
        let session = desk.session
        let stood = ReadingPlace(timeline: .all, lamp: "a3")
        session.stands(ReadingPlace.Standing(lamp: "a3"))
        #expect(desk.kept == stood)

        session.stopKeepingPlace()
        #expect(!session.keepsPlace)
        let readBack = ReadingPlace(timeline: .trends, lamp: "t2", top: "t1")
        desk.defaults.removeObject(forKey: "fediqo.place")
        ReadingPlaceStore(defaults: desk.defaults).save(readBack)
        session.stands(ReadingPlace.Standing(lamp: "a2"))
        session.scrolledTop = "a1"
        session.scrolledTop = nil
        #expect(desk.kept == readBack)

        session.keepPlaceFromHere()
        #expect(desk.kept == readBack)
        session.stands(ReadingPlace.Standing(lamp: "a3"))
        #expect(desk.kept == stood)
    }

    // MARK: The top row the pane reports

    private let allRows = ["a1", "a2", "a3", "a4"]

    @Test("The top row is the first row of this list that is in view, in the list's order")
    func firstOfThisListInView() {
        #expect(KeepsTopRow.top(visible: ["a2", "a3"], of: allRows, on: .all, inFront: .all) == "a2")
        // What is in view comes in no order.
        #expect(KeepsTopRow.top(visible: ["a4", "a2", "a3"], of: allRows, on: .all, inFront: .all) == "a2")
    }

    @Test("Rows of the timeline left are no top row: alone they say nothing, and mixed in they are passed over")
    func rowsOfTheTimelineLeft() {
        let trendRows = ["t1", "t2", "t3"]
        #expect(KeepsTopRow.top(visible: ["a3", "a1", "a2"], of: trendRows, on: .trends, inFront: .trends) == nil)
        #expect(KeepsTopRow.top(visible: ["a3", "t2", "a1", "t1"], of: trendRows, on: .trends, inFront: .trends) == "t1")
    }

    @Test("Nothing in view says nothing, and so does a list that is no longer the one in front")
    func nothingToSay() {
        #expect(KeepsTopRow.top(visible: [], of: allRows, on: .all, inFront: .all) == nil)
        #expect(KeepsTopRow.top(visible: ["a1"], of: [], on: .all, inFront: .all) == nil)
        #expect(KeepsTopRow.top(visible: ["a1", "a2"], of: allRows, on: .all, inFront: .trends) == nil)
    }

    @Test("The top row of a search's results is the results' own, and the timeline's top row stays as it was")
    func resultsKeepTheirOwnTop() {
        let desk = landed()
        let session = desk.session
        session.scrolled(to: "a2", found: nil)
        #expect(desk.kept == ReadingPlace(timeline: .all, top: "a2"))
        let writes = desk.defaults.writes

        session.scrolled(to: "result-7", found: "swift")
        #expect(session.scrolledTop == "a2")
        #expect(session.listTop(found: "swift") == "result-7")
        #expect(session.listTop(found: nil) == "a2")
        #expect(desk.defaults.writes == writes)
        #expect(desk.kept == ReadingPlace(timeline: .all, top: "a2"))
    }

    @Test("Another search's results, and another timeline's, are another list with no top row yet")
    func resultsOfAnotherSearch() {
        let session = landed().session
        session.scrolled(to: "result-7", found: "swift")
        #expect(session.listTop(found: "rust") == nil)
        // The first search again, as it was left.
        #expect(session.listTop(found: "swift") == "result-7")

        session.scrolled(to: "result-2", found: "rust")
        #expect(session.listTop(found: "swift") == nil)

        session.timelineID = .trends
        #expect(session.listTop(found: "rust") == nil)
    }

    /// The search field open with nothing typed in it still draws the timeline, so what the pane
    /// asks — `searched`, the question it picks its rows by — says these are no results, and the
    /// row scrolled to is the timeline's and is written.
    @Test("A search open with nothing typed finds nothing, and the row scrolled to is the timeline's own")
    func openWithNothingTyped() async {
        let desk = landed()
        let session = desk.session
        session.notes = [
            Note(id: "p1", source: Self.microblog, author: "Ada", handle: "@ada@m.example", body: "swift",
                 postedAt: Date(timeIntervalSince1970: 1), categories: [.public]),
        ]
        let search = ShellSearch()
        search.open(from: nil, over: session.notes)
        await search.indexed()
        #expect(search.isOpen)
        #expect(session.searched(search, latest: nil) == nil)

        session.scrolled(to: "a2", found: session.searched(search, latest: nil) == nil ? nil : search.pattern)
        #expect(session.scrolledTop == "a2")
        #expect(desk.kept == ReadingPlace(timeline: .all, top: "a2"))

        // Typed and settled, the list is its results, and their top row is theirs.
        search.text = "swift"
        search.settle("swift")
        #expect(session.searched(search, latest: nil) != nil)
        session.scrolled(to: "p1", found: session.searched(search, latest: nil) == nil ? nil : search.pattern)
        #expect(session.scrolledTop == "a2")
        #expect(session.listTop(found: "swift") == "p1")
        #expect(desk.kept == ReadingPlace(timeline: .all, top: "a2"))
    }

    // MARK: The root's half: the timeline's own lamp, and the conversation in front

    private let page = URL(string: "https://m.example/page")!

    private func person(_ name: String) throws -> DummyPerson {
        let note = Note(id: name, source: Self.microblog, author: name, handle: "@\(name.lowercased())@m.example",
                        body: name, postedAt: Date(timeIntervalSince1970: 1), categories: [.public])
        return try #require(DummyPerson(DummyItem(note)))
    }

    @Test("On the stream the lamp is the timeline's, and no conversation is open")
    func onTheStream() {
        let walk = ShellWalk()
        #expect(ReadingPlace.standing(lamp: "a3", walk: walk, searching: false, parked: nil)
            == ReadingPlace.Standing(lamp: "a3"))
        #expect(ReadingPlace.standing(lamp: nil, walk: walk, searching: false, parked: nil)
            == ReadingPlace.Standing())
    }

    @Test("Inside a conversation the lamp named is the row it was opened from, wherever the lamp has gone since")
    func insideAConversation() {
        var walk = ShellWalk()
        _ = walk.walk(to: .thread("a3"), from: "a3")
        // `j` inside the conversation: the lamp is on a reply.
        #expect(ReadingPlace.standing(lamp: "reply-9", walk: walk, searching: false, parked: nil)
            == ReadingPlace.Standing(lamp: "a3", thread: "a3"))

        // A page read out of it stands over it, and the conversation is still the one open.
        _ = walk.walk(to: .link(page), from: "reply-9")
        #expect(ReadingPlace.standing(lamp: "reply-9", walk: walk, searching: false, parked: nil)
            == ReadingPlace.Standing(lamp: "a3", thread: "a3"))

        // Back out of both: the stream, and its lamp is the lamp again.
        _ = walk.back()
        _ = walk.back()
        #expect(ReadingPlace.standing(lamp: "a3", walk: walk, searching: false, parked: nil)
            == ReadingPlace.Standing(lamp: "a3"))
    }

    @Test("A person's page or a tag's is no conversation; one opened from it is, over the stream's own lamp")
    func otherPages() throws {
        var walk = ShellWalk()
        _ = walk.walk(to: .person(try person("Ada")), from: "a2")
        #expect(ReadingPlace.standing(lamp: "theirs-1", walk: walk, searching: false, parked: nil)
            == ReadingPlace.Standing(lamp: "a2"))

        _ = walk.walk(to: .thread("theirs-1"), from: "theirs-1")
        #expect(ReadingPlace.standing(lamp: "theirs-1", walk: walk, searching: false, parked: nil)
            == ReadingPlace.Standing(lamp: "a2", thread: "theirs-1"))

        // Their face pressed inside that conversation: somebody is in front, so no conversation.
        _ = walk.walk(to: .person(try person("Bob")), from: "theirs-1")
        #expect(ReadingPlace.standing(lamp: nil, walk: walk, searching: false, parked: nil)
            == ReadingPlace.Standing(lamp: "a2"))

        var tagged = ShellWalk()
        _ = tagged.walk(to: .tag(try #require(PostTag("#swift"))), from: nil)
        #expect(ReadingPlace.standing(lamp: "tagged-1", walk: tagged, searching: false, parked: nil)
            == ReadingPlace.Standing())
    }

    @Test("Under a search the lamp named is the post it parked, and a conversation opened from a result is named")
    func underASearch() {
        var walk = ShellWalk()
        #expect(ReadingPlace.standing(lamp: "result-1", walk: walk, searching: true, parked: "a3")
            == ReadingPlace.Standing(lamp: "a3"))
        #expect(ReadingPlace.standing(lamp: "result-1", walk: walk, searching: true, parked: nil)
            == ReadingPlace.Standing())

        _ = walk.walk(to: .thread("result-1"), from: "result-1")
        #expect(ReadingPlace.standing(lamp: "reply-2", walk: walk, searching: true, parked: "a3")
            == ReadingPlace.Standing(lamp: "a3", thread: "result-1"))
    }
}
