import Foundation
@testable import FediqoCore
import Testing
@testable import FediqoUI

/// What an earlier run left on a device, for a launch to come back to (#273): the posts in the
/// store, a timeline written for Ada, and the place kept — all in defaults that reach no disk.
///
/// All holds all six posts, Trends `t1`–`t3`, and Ada's timeline her three: `p1`, `p3`, `t3`.
@MainActor
struct KeptDevice {
    static let microblog = Source(host: "m.example", kind: .mastodon)

    let defaults = CountingDefaults()
    let store = ItemStore()

    static func note(_ id: String, _ author: String, _ categories: Set<FediqoCore.Category>, at t: Double) -> Note {
        Note(id: id, source: microblog, author: author, handle: "@\(author.lowercased())@m.example", body: id,
             postedAt: Date(timeIntervalSince1970: t), categories: categories)
    }

    static let notes: [Note] = [
        note("p1", "Ada", [.public], at: 9),
        note("p2", "Bob", [.public], at: 8),
        note("p3", "Ada", [.public], at: 7),
        note("t1", "Cy", [.trends], at: 6),
        note("t2", "Dee", [.trends], at: 5),
        note("t3", "Ada", [.trends], at: 4),
    ]

    /// The row a post is drawn as. One this device does not hold has a row id all the same.
    static func row(_ id: String) -> String {
        DummyItem(note(id, "Ada", [.public], at: 1)).id
    }

    /// The store as the earlier run left it.
    func hold(_ notes: [Note] = KeptDevice.notes) async {
        await store.replace(sources: [Self.microblog], notes: notes)
    }

    /// Ada's timeline, written by an earlier run into these defaults — and deleted by it again
    /// where `removed`, which leaves its id naming nothing.
    func writeTimeline(removed: Bool = false) throws -> TimelineQuery {
        let earlier = ShellSession(http: FixtureHTTP([:]), timelines: WrittenTimelineStore(defaults: defaults))
        earlier.sources = [Self.microblog]
        earlier.rebuildQueries()
        var draft = TimelineDraft(new: 1)
        draft.name = "Ada"
        draft.rules = [try #require(Rule.author("@ada@m.example", in: .every, sources: []))]
        earlier.commit(draft)
        let id = try #require(earlier.written.first).id
        if removed { earlier.removeTimeline(id) }
        return .written(id)
    }

    /// The place the earlier run stopped at.
    func keep(_ place: ReadingPlace) {
        ReadingPlaceStore(defaults: defaults).save(place)
    }

    /// What is kept, read the way a relaunch reads it.
    var kept: ReadingPlace? { ReadingPlaceStore(defaults: defaults).load() }

    /// A session as a launch makes it, before the store has said anything. Its pictures, its
    /// emoji, its sign-ins and its record of work are its own, so a read back adopted here
    /// (`adoptReadBack`) clears and rereads nothing another suite shares.
    func session() -> ShellSession {
        let session = ShellSession(
            http: FixtureHTTP([:]), store: store,
            pictures: ShellPictures(http: FixtureHTTP([:])),
            emojis: EmojiCache(http: FixtureHTTP([:])),
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: ActServer([:])),
            timelines: WrittenTimelineStore(defaults: defaults),
            place: ReadingPlaceStore(defaults: defaults)
        )
        session.work = SourceWork()
        return session
    }

    /// The launch as the root view runs it, without the view: the store adopted, the place come
    /// back to and stood on, and only then the writing started. What the root stands on is
    /// handed back.
    func launch(_ session: ShellSession) async -> ReadingPlace.Standing? {
        await session.reloadFromStore()
        session.landAtKeptPlace(latest: nil)
        let standing = session.takeLanding()
        session.keepPlaceFromHere()
        return standing
    }
}

/// #273: what to land on, given the place kept and what the device holds today — every fallback
/// as a row of one table, asked of the one function a launch and a read back both ask.
@Suite("What a place kept lands on")
struct ReadingPlaceLandingTests {
    private static let mine = TimelineQuery.written(UUID())
    private static let tabs: [TimelineQuery] = [.all, .trends, mine]

    /// What each timeline's list holds today.
    private static func rows(of query: TimelineQuery) -> [String] {
        switch query {
        case .all: ["a1", "a2", "a3", "m1"]
        case .trends: ["t1", "t2"]
        case .written: ["m1", "m2"]
        }
    }

    /// Every row a list draws, and one post held aside that none does.
    private static let held: Set<String> = ["a1", "a2", "a3", "m1", "m2", "t1", "t2", "aside-1"]

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let kept: ReadingPlace
        var tabs: [TimelineQuery] = ReadingPlaceLandingTests.tabs
        /// The place to put in front, or nothing where none is.
        let lands: ReadingPlace?
        /// Where the list drawn for it is then put: `TimelinePane.landing`'s answer.
        let scrolls: TimelinePane.Landing?

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "everything still there: the place as it was kept, and the list centred on the lamp",
            kept: ReadingPlace(timeline: mine, lamp: "m2", top: "m1", thread: "m2"),
            lands: ReadingPlace(timeline: mine, lamp: "m2", top: "m1", thread: "m2"),
            scrolls: .centred("m2")
        ),
        Case(
            name: "no lamp was lit: the top row, at the top again",
            kept: ReadingPlace(timeline: .trends, top: "t2"),
            lands: ReadingPlace(timeline: .trends, top: "t2"),
            scrolls: .top("t2")
        ),
        Case(
            name: "the written timeline deleted: All, with what All's own list still holds of the place",
            kept: ReadingPlace(timeline: mine, lamp: "m1", top: "m2", thread: "m1"),
            tabs: [.all, .trends],
            lands: ReadingPlace(timeline: .all, lamp: "m1", thread: "m1"),
            scrolls: .centred("m1")
        ),
        Case(
            name: "Trends no source offers any more: All, and Trends' rows are not All's",
            kept: ReadingPlace(timeline: .trends, lamp: "t1", top: "t2"),
            tabs: [.all, mine],
            lands: ReadingPlace(timeline: .all),
            scrolls: nil
        ),
        Case(
            name: "nothing joined: no place at all",
            kept: ReadingPlace(timeline: .all, lamp: "a2", top: "a1", thread: "a2"),
            tabs: [],
            lands: nil,
            scrolls: nil
        ),
        Case(
            name: "the lamp let go, the top row still there: no lamp, and the top row at the top",
            kept: ReadingPlace(timeline: .all, lamp: "gone", top: "a2"),
            lands: ReadingPlace(timeline: .all, top: "a2"),
            scrolls: .top("a2")
        ),
        Case(
            name: "the lamp and the top row both let go: the top of the timeline",
            kept: ReadingPlace(timeline: .all, lamp: "gone", top: "gone-too"),
            lands: ReadingPlace(timeline: .all),
            scrolls: nil
        ),
        Case(
            name: "the top row let go, the lamp still there: the lamp, and no top row",
            kept: ReadingPlace(timeline: .all, lamp: "a3", top: "gone"),
            lands: ReadingPlace(timeline: .all, lamp: "a3"),
            scrolls: .centred("a3")
        ),
        Case(
            name: "a lamp and a top row of another timeline, kept under this one: neither",
            kept: ReadingPlace(timeline: .trends, lamp: "a1", top: "a2"),
            lands: ReadingPlace(timeline: .trends),
            scrolls: nil
        ),
        Case(
            name: "the conversation's post not held any more: the place, and no conversation",
            kept: ReadingPlace(timeline: .all, lamp: "a2", top: "a1", thread: "gone"),
            lands: ReadingPlace(timeline: .all, lamp: "a2", top: "a1"),
            scrolls: .centred("a2")
        ),
        Case(
            name: "a conversation around a post held aside, in no list: still a conversation",
            kept: ReadingPlace(timeline: .all, lamp: "a2", thread: "aside-1"),
            lands: ReadingPlace(timeline: .all, lamp: "a2", thread: "aside-1"),
            scrolls: .centred("a2")
        ),
        Case(
            name: "the lamp let go, the conversation still held: the conversation, over no lamp",
            kept: ReadingPlace(timeline: mine, lamp: "gone", thread: "m2"),
            lands: ReadingPlace(timeline: mine, thread: "m2"),
            scrolls: nil
        ),
    ]

    @Test("Each part of the place is kept where this device still holds it, and dropped alone where it does not", arguments: cases)
    func landing(_ c: Case) {
        let landed = c.kept.landing(among: c.tabs, rows: Self.rows, holds: Self.held.contains)
        #expect(landed == c.lands)
        #expect(c.kept.timeline(among: c.tabs) == c.lands?.timeline)
        // What the pane makes of it: the lamp, else the top row, else nothing — the top.
        #expect(TimelinePane.landing(selected: landed?.lamp, top: landed?.top) == c.scrolls)
    }

    @Test("Only the list of the timeline landed on is asked for")
    func onlyTheListLandedOn() {
        var asked: [TimelineQuery] = []
        let rows: (TimelineQuery) -> [String] = { query in
            asked.append(query)
            return Self.rows(of: query)
        }
        let kept = ReadingPlace(timeline: Self.mine, lamp: "m1", top: "a1")
        #expect(kept.landing(among: [.all], rows: rows, holds: { _ in true }) == ReadingPlace(timeline: .all, lamp: "m1", top: "a1"))
        #expect(asked == [.all])
    }

    // MARK: The root's half: the step the place puts the walk on

    /// The root opens the conversation over the lamp as it was kept, which need not be the post
    /// the conversation is around. What it then tells the session has to be the place it was
    /// handed, or the telling would write the place over.
    @Test(
        "A conversation opened again over the kept lamp reads back as the same standing, and leaving gives the lamp back",
        arguments: [
            ReadingPlace.Standing(lamp: "a2", thread: "a2"),
            ReadingPlace.Standing(lamp: "a2", thread: "theirs-1"),
            ReadingPlace.Standing(lamp: nil, thread: "aside-1"),
        ]
    )
    func reopenedReadsBackTheSame(_ stopped: ReadingPlace.Standing) throws {
        var walk = ShellWalk()
        let lamp = FediqoRootView.land(stopped, on: &walk)
        // Inside the conversation the lamp is on its post, as a press leaves it.
        #expect(lamp == stopped.thread)
        #expect(walk.openedThread == stopped.thread)
        #expect(walk.depth == 1)
        #expect(ReadingPlace.standing(lamp: lamp, walk: walk, searching: false, parked: nil) == stopped)
        let left = walk.back()
        #expect(left?.lamp == stopped.lamp)
    }

    /// After a read back the walk still holds what was walked to on the store replaced.
    @Test("Steps taken before the landing are gone: the walk is the place's conversation, or nothing")
    func stepsBeforeAreGone() {
        var walk = ShellWalk()
        _ = walk.walk(to: .thread("old-1"), from: "old-1")
        _ = walk.walk(to: .thread("old-2"), from: "old-reply")
        let lamp = FediqoRootView.land(ReadingPlace.Standing(lamp: "a2", thread: "a3"), on: &walk)
        #expect(lamp == "a3")
        #expect(walk.depth == 1)
        #expect(ReadingPlace.standing(lamp: lamp, walk: walk, searching: false, parked: nil)
            == ReadingPlace.Standing(lamp: "a2", thread: "a3"))

        _ = walk.walk(to: .thread("old-2"), from: "old-reply")
        #expect(FediqoRootView.land(ReadingPlace.Standing(lamp: "a2"), on: &walk) == "a2")
        #expect(walk.isEmpty)
    }

    @Test("A place with no conversation takes no step: the lamp kept, or none")
    func noConversationNoStep() {
        for stopped in [ReadingPlace.Standing(lamp: "a2"), ReadingPlace.Standing()] {
            var walk = ShellWalk()
            let lamp = FediqoRootView.land(stopped, on: &walk)
            #expect(lamp == stopped.lamp)
            #expect(walk.isEmpty)
            #expect(ReadingPlace.standing(lamp: lamp, walk: walk, searching: false, parked: nil) == stopped)
        }
    }

    // MARK: The root's half: the timeline coming in front does not end that walk

    /// At a launch the timeline comes in front out of nothing, and the root may answer that
    /// change after it has opened the conversation kept. `timelineSwitched` is the root's answer.
    @Test("A timeline come in front where none was ends no walk, and files no place")
    func outOfNothingEndsNoWalk() {
        var walk = ShellWalk()
        var places = TimelinePlaces()
        places.leave(Self.mine, standingOn: "m2")
        _ = FediqoRootView.land(ReadingPlace.Standing(lamp: "m2", thread: "m1"), on: &walk)
        let before = (walk, places)

        let stays = FediqoRootView.timelineSwitched(
            on: &walk, places: &places, from: nil, to: Self.mine, shown: ["m1", "m2"], results: nil
        )
        #expect(stays == nil)
        #expect(walk == before.0)
        #expect(walk.openedThread == "m1")
        #expect(places == before.1)
    }

    @Test("A timeline switched for another ends the walk, as it always has")
    func aSwitchEndsTheWalk() {
        var walk = ShellWalk()
        var places = TimelinePlaces()
        _ = FediqoRootView.land(ReadingPlace.Standing(lamp: "m2", thread: "m1"), on: &walk)

        let stays = FediqoRootView.timelineSwitched(
            on: &walk, places: &places, from: Self.mine, to: .all, shown: ["a1"], results: nil
        )
        #expect(stays == nil)
        #expect(walk.isEmpty)
    }
}

/// #273: the launch comes back to the place kept. The session is launched as the root view
/// launches it — the store adopted, the place landed on, then the writing started — and asked
/// what it put in front and what it handed the root to stand on.
///
/// **Where the list is scrolled to is not asked here**, nor anywhere: it is `TimelinePane.landing`
/// over the lamp and the top row these tests read, which `ReadingPlaceLandingTests` asks as logic.
@Suite("A launch comes back to where reading stopped")
@MainActor
struct ReadingPlaceLaunchTests {
    init() {
        L10n.language = .english
    }

    private func row(_ id: String) -> String { KeptDevice.row(id) }

    // MARK: Acceptance: a place whose timeline and posts are all still there

    @Test("The timeline, the lamp, the top row and the conversation kept are all put in front, and nothing is written")
    func comesBack() async throws {
        let device = KeptDevice()
        await device.hold()
        let mine = try device.writeTimeline()
        let stopped = ReadingPlace(timeline: mine, lamp: row("p3"), top: row("p1"), thread: row("p3"))
        device.keep(stopped)
        let writes = device.defaults.writes

        let session = device.session()
        // The store says what is joined, and the timeline kept is the one that comes in front.
        await session.reloadFromStore()
        #expect(session.timelineID == mine)
        #expect(session.scrolledTop == nil)

        let standing = session.landAtKeptPlace(latest: nil)
        #expect(standing == ReadingPlace.Standing(lamp: row("p3"), thread: row("p3")))
        #expect(session.readingPlace == stopped)
        #expect(session.landings == 1)
        // The pane lights what is filed for a timeline as it comes in front (#100).
        let rows = session.timelineItems(latest: nil).map(\.id)
        #expect(rows == [row("p1"), row("p3"), row("t3")])
        #expect(session.timelinePlaces.arriving(at: mine, among: rows) == row("p3"))
        // And lands its list on the lamp.
        #expect(TimelinePane.landing(selected: standing?.lamp, top: session.listTop(found: nil)) == .centred(row("p3")))

        session.keepPlaceFromHere()
        // The root has not stood on the landing yet: what it says is where it stood before —
        // nothing — and is not taken, so the place come back to is not written over with it.
        session.stands(ReadingPlace.Standing())
        #expect(session.readingPlace == stopped)
        #expect(device.defaults.writes == writes)

        // The landing is handed over once; from there the root's word is taken again.
        #expect(session.takeLanding() == standing)
        #expect(session.takeLanding() == nil)
        session.stands(try #require(standing))
        #expect(device.defaults.writes == writes)
        #expect(device.kept == stopped)
        session.stands(ReadingPlace.Standing(lamp: row("p1")))
        #expect(device.kept == ReadingPlace(timeline: mine, lamp: row("p1"), top: row("p1")))
    }

    /// The root takes the conversation's step whichever page the rail is on (`FediqoRootView.land`
    /// asks nothing of it), so a reader who went to another page while the store was read still
    /// has the conversation under the timeline place — and what the root then tells the session
    /// is the place as kept. A step refused there would be told as no conversation, and written.
    @Test("Landed on while another page is in front, the conversation kept is still the place's, and nothing is written")
    func landedOnAnotherPage() async throws {
        let device = KeptDevice()
        await device.hold()
        // A conversation opened from somebody's page: around `t3`, over the stream's lamp `p2`.
        let stopped = ReadingPlace(timeline: .all, lamp: row("p2"), top: row("p1"), thread: row("t3"))
        device.keep(stopped)
        let writes = device.defaults.writes

        let session = device.session()
        // The launch rule would move to the timeline; the reader is on Preferences and stays.
        await session.reloadFromStore()
        var launch = ShellLaunch()
        let moved = launch.settle(session.availability, standingOn: .preferences)
        #expect(moved == nil)

        session.landAtKeptPlace(latest: nil)
        let standing = try #require(session.takeLanding())
        var walk = ShellWalk()
        let lamp = FediqoRootView.land(standing, on: &walk)
        session.keepPlaceFromHere()
        // What `KeepsReadingPlace` tells a tick later, from the root's lamp and walk.
        session.stands(ReadingPlace.standing(lamp: lamp, walk: walk, searching: false, parked: nil))
        #expect(walk.openedThread == row("t3"))
        #expect(session.readingPlace == stopped)
        #expect(device.defaults.writes == writes)
        #expect(device.kept == stopped)
    }

    /// The order inside the landing: the timeline forgets the top row and the standing as it
    /// changes, so they have to be set after it. With the kept timeline already in front the
    /// order would not show; here another is.
    @Test("With another timeline in front the place kept is still landed on whole, asked of its own list")
    func anotherTimelineInFront() async throws {
        let device = KeptDevice()
        await device.hold()
        let mine = try device.writeTimeline()
        let stopped = ReadingPlace(timeline: mine, lamp: row("p3"), top: row("p1"))
        device.keep(stopped)

        let session = device.session()
        await session.reloadFromStore()
        session.timelineID = .trends
        session.scrolledTop = row("t1")
        // Neither row is one of Trends': asked of the list in front there would be no lamp.
        #expect(session.timelineItems(latest: nil).map(\.id) == [row("t1"), row("t2"), row("t3")])
        #expect(session.rows(of: mine, latest: nil) == [row("p1"), row("p3"), row("t3")])

        #expect(session.landAtKeptPlace(latest: nil) == ReadingPlace.Standing(lamp: row("p3")))
        #expect(session.readingPlace == stopped)
        #expect(session.rows(of: mine, latest: nil) == session.timelineItems(latest: nil).map(\.id))
    }

    // MARK: Acceptance: nothing is marked read by coming back

    @Test("Coming back changes no post held, no mark on one, and no preference")
    func nothingHeldChanges() async throws {
        let device = KeptDevice()
        await device.hold()
        #expect(await device.store.markGone(KeptDevice.notes[1].key))
        let mine = try device.writeTimeline()
        device.keep(ReadingPlace(timeline: mine, lamp: row("p3"), top: row("p1"), thread: row("p3")))

        let before = await device.store.snapshot()
        let drawn = await device.store.drawn
        let aside = await device.store.asideRevision
        let gone = await device.store.goneCount()
        let settled = await device.store.settledCount()
        let writes = device.defaults.writes

        let session = device.session()
        #expect(await device.launch(session) != nil)
        // The store's own turn again, with the place in front.
        await session.reloadFromStore()

        let after = await device.store.snapshot()
        #expect(after.revision == before.revision)
        #expect(after.notes == before.notes)
        #expect(after.sources == before.sources)
        #expect(await device.store.drawn == drawn)
        #expect(await device.store.asideRevision == aside)
        #expect(await device.store.goneCount() == gone)
        #expect(await device.store.settledCount() == settled)
        #expect(device.defaults.writes == writes)
    }

    // MARK: Acceptance: the fallbacks, each against a device that holds less than was kept

    @Test("A place naming a written timeline since deleted lands on All, on the lamp and the top row All holds too")
    func deletedTimeline() async throws {
        let device = KeptDevice()
        await device.hold()
        let deleted = try device.writeTimeline(removed: true)
        let stopped = ReadingPlace(timeline: deleted, lamp: row("p3"), top: row("t3"))
        device.keep(stopped)
        let writes = device.defaults.writes

        let session = device.session()
        #expect(session.written.isEmpty)
        let standing = await device.launch(session)
        #expect(session.timelineID == .all)
        #expect(standing == ReadingPlace.Standing(lamp: row("p3")))
        #expect(session.readingPlace == ReadingPlace(timeline: .all, lamp: row("p3"), top: row("t3")))
        // Not written until the reader moves: what was kept is still what is kept.
        #expect(device.defaults.writes == writes)
        #expect(device.kept == stopped)
    }

    @Test("A place naming a timeline id this build does not know lands on All")
    func unknownTimeline() async throws {
        let device = KeptDevice()
        await device.hold()
        let board: [String: Any] = ["version": 1, "timeline": "board:42", "top": row("p2")]
        device.defaults.set(try JSONSerialization.data(withJSONObject: board), forKey: "fediqo.place")

        let session = device.session()
        #expect(await device.launch(session) == ReadingPlace.Standing())
        #expect(session.readingPlace == ReadingPlace(timeline: .all, top: row("p2")))
    }

    @Test("With nothing joined the launch lands on Account, and the place kept is neither landed on nor written over")
    func nothingJoined() async throws {
        let device = KeptDevice()
        let stopped = ReadingPlace(timeline: .trends, lamp: row("t2"), top: row("t1"), thread: row("t2"))
        device.keep(stopped)
        let writes = device.defaults.writes

        let session = device.session()
        #expect(await device.launch(session) == nil)
        #expect(session.timelineID == nil)
        #expect(session.readingPlace == nil)
        #expect(session.landings == 0)
        // The launch rule's own answer, unchanged: the place a source is added.
        var launch = ShellLaunch()
        #expect(session.availability.launchPlace == .account)
        let moved = launch.settle(session.availability, standingOn: .launch)
        #expect(moved == nil)
        #expect(device.defaults.writes == writes)
        #expect(device.kept == stopped)

        // A source added later in the run is read from All, as a first source always was: the
        // launch has landed, and the place kept is not half come back to. All in front is where
        // reading now stands, and is written as that — over the place kept, whole.
        session.sources = [KeptDevice.microblog]
        session.rebuildQueries()
        #expect(session.timelineID == .all)
        #expect(session.readingPlace == ReadingPlace(timeline: .all))
        #expect(session.landings == 0)
        #expect(device.kept == ReadingPlace(timeline: .all))
    }

    /// Mid-run the timeline kept may be one written for the source just let go, under which a
    /// new source's posts would not show at all.
    @Test("The last source let go and another joined in the same run: All is in front, not the timeline kept")
    func rejoinedMidRun() async throws {
        let device = KeptDevice()
        await device.hold()
        let mine = try device.writeTimeline()
        let stopped = ReadingPlace(timeline: mine, lamp: row("p3"), top: row("p1"))
        device.keep(stopped)

        let session = device.session()
        _ = await device.launch(session)
        #expect(session.timelineID == mine)

        session.sources = []
        session.rebuildQueries()
        #expect(session.timelineID == nil)
        #expect(device.kept == stopped)

        session.sources = [Source(host: "other.example", kind: .mastodon)]
        session.rebuildQueries()
        #expect(session.timelineID == .all)
        #expect(device.kept == ReadingPlace(timeline: .all))
    }

    @Test("A lamp let go since lands on no lamp, and the list on the top row kept")
    func lampLetGo() async throws {
        let device = KeptDevice()
        await device.hold()
        device.keep(ReadingPlace(timeline: .all, lamp: row("p9"), top: row("p2")))

        let session = device.session()
        let standing = await device.launch(session)
        #expect(standing == ReadingPlace.Standing())
        #expect(session.readingPlace == ReadingPlace(timeline: .all, top: row("p2")))
        #expect(TimelinePane.landing(selected: standing?.lamp, top: session.listTop(found: nil)) == .top(row("p2")))
        // Nothing is filed as All's post either: the pane lights nothing as All comes in front.
        #expect(session.timelinePlaces.arriving(at: .all, among: session.timelineItems(latest: nil).map(\.id)) == nil)
    }

    @Test("A lamp and a top row both let go land at the top of the timeline")
    func lampAndTopLetGo() async throws {
        let device = KeptDevice()
        await device.hold()
        device.keep(ReadingPlace(timeline: .trends, lamp: row("t9"), top: row("t8")))

        let session = device.session()
        let standing = await device.launch(session)
        #expect(session.readingPlace == ReadingPlace(timeline: .trends))
        #expect(TimelinePane.landing(selected: standing?.lamp, top: session.listTop(found: nil)) == nil)
    }

    /// What a switch can leave kept: a row the old and the new list both showed, told as the top
    /// before the new list reported its own.
    @Test("A lamp and a top row that are another timeline's are neither landed on")
    func rowsOfAnotherTimeline() async throws {
        let device = KeptDevice()
        await device.hold()
        device.keep(ReadingPlace(timeline: .trends, lamp: row("p1"), top: row("p2")))

        let session = device.session()
        #expect(await device.launch(session) == ReadingPlace.Standing())
        #expect(session.readingPlace == ReadingPlace(timeline: .trends))
    }

    @Test("A conversation whose post is not held any more is not opened; the rest of the place is landed on")
    func threadGone() async throws {
        let device = KeptDevice()
        await device.hold()
        device.keep(ReadingPlace(timeline: .all, lamp: row("p2"), top: row("p1"), thread: row("p9")))

        let session = device.session()
        #expect(await device.launch(session) == ReadingPlace.Standing(lamp: row("p2")))
        #expect(session.readingPlace == ReadingPlace(timeline: .all, lamp: row("p2"), top: row("p1")))
    }

    @Test("A session that keeps no place lands on All and hands the root nothing")
    func keepsNone() async {
        let device = KeptDevice()
        await device.hold()
        let session = ShellSession(http: FixtureHTTP([:]), store: device.store)
        await session.reloadFromStore()
        #expect(session.landAtKeptPlace(latest: nil) == nil)
        #expect(session.timelineID == .all)
    }

    // MARK: What the list first reports does not undo the landing

    @Test("Until the pane has landed its list, the rows it reports are not taken as the top row, nor written")
    func theTopRowIsOwed() async throws {
        let device = KeptDevice()
        await device.hold()
        let stopped = ReadingPlace(timeline: .all, top: row("p3"))
        device.keep(stopped)
        let writes = device.defaults.writes

        let session = device.session()
        _ = await device.launch(session)
        #expect(session.keepsPlace)
        #expect(session.topIsOwed)

        // The list as it is first drawn: its first row in view, before anything has scrolled.
        session.scrolled(to: row("p1"), found: nil)
        #expect(session.scrolledTop == row("p3"))
        #expect(session.listTop(found: nil) == row("p3"))
        #expect(device.defaults.writes == writes)
        #expect(device.kept == stopped)

        // A list that appeared before the landing read no place to scroll to; its tick coming
        // round now is not the list reaching the row kept.
        session.listLanded(for: session.landings - 1)
        #expect(session.topIsOwed)
        session.scrolled(to: row("p1"), found: nil)
        #expect(session.scrolledTop == row("p3"))
        #expect(device.defaults.writes == writes)

        // The pane has scrolled to the row kept, and the list says so: the place as it was.
        session.listLanded(for: session.landings)
        #expect(!session.topIsOwed)
        session.scrolled(to: row("p3"), found: nil)
        #expect(device.defaults.writes == writes)

        // From here a row that passes is the top row, as on any other day.
        session.scrolled(to: row("p2"), found: nil)
        #expect(device.kept == ReadingPlace(timeline: .all, top: row("p2")))
        #expect(device.defaults.writes == writes + 1)
    }

    @Test("A search's results reported meanwhile are still the search's own, and a timeline pressed owes nothing")
    func owedOnlyOfTheTimelineLandedOn() async throws {
        let device = KeptDevice()
        await device.hold()
        device.keep(ReadingPlace(timeline: .all, top: row("p3")))

        let session = device.session()
        _ = await device.launch(session)
        session.scrolled(to: row("p2"), found: "ada")
        #expect(session.listTop(found: "ada") == row("p2"))
        #expect(session.scrolledTop == row("p3"))
        #expect(session.topIsOwed)

        session.timelineID = .trends
        #expect(!session.topIsOwed)
        session.scrolled(to: row("t2"), found: nil)
        #expect(device.kept == ReadingPlace(timeline: .trends, top: row("t2")))
    }

    @Test("A place kept with no top row owes none: the first row reported is the top row")
    func noTopRowKept() async throws {
        let device = KeptDevice()
        await device.hold()
        device.keep(ReadingPlace(timeline: .all, lamp: row("p2"), top: row("p9")))

        let session = device.session()
        _ = await device.launch(session)
        #expect(!session.topIsOwed)
        session.scrolled(to: row("p1"), found: nil)
        #expect(device.kept == ReadingPlace(timeline: .all, lamp: row("p2"), top: row("p1")))
    }
}
