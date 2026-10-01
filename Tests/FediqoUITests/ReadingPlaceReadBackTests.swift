import Foundation
@testable import FediqoCore
import Testing
@testable import FediqoUI

/// #273: a read back brings the place reading stopped at on the device it was taken from, and the
/// session adopts it — the timeline, the lamp, the top row and the conversation, each asked of
/// what was read back — without the rail moving. What is kept stays the read back's own bytes
/// until the reader moves.
///
/// **The read back is done by hand here**, the way the carrier leaves a device: the store holding
/// the package's posts, and the two keys this work reads off the preferences — the place and the
/// written timelines — removed and set to the package's, or left removed where it carried none.
/// That the package carries them, byte for byte, is `StorePackagerTests`'.
///
/// **The root view is a value here** (`Root`): the front it last answered, its lamp and its walk,
/// answering the session's front through the statics the root answers through, in
/// `ShellFront.answers(after:)`'s order, and then telling the session where it stands as
/// `KeepsReadingPlace` does. The root's own wiring is run by no test.
@Suite("A read back is adopted at the place it brought")
@MainActor
struct ReadingPlaceReadBackTests {
    init() {
        L10n.language = .english
    }

    private func row(_ id: String) -> String { KeptDevice.row(id) }

    /// What the device read back from held: two of this device's posts and two of its own.
    private static let theirs: [Note] = [
        KeptDevice.note("r1", "Ada", [.public], at: 9),
        KeptDevice.note("p2", "Bob", [.public], at: 8),
        KeptDevice.note("p3", "Ada", [.public], at: 7),
        KeptDevice.note("r4", "Cy", [.trends], at: 6),
    ]

    /// The root view's share, without the view.
    private struct Root {
        var front: ShellFront
        var selected: String?
        var walk = ShellWalk()
        /// The page the rail is on. Nothing below writes it: the adoption has no word for it.
        let place: ShellPlace = .preferences

        @MainActor
        init(_ session: ShellSession, standing: ReadingPlace.Standing?) {
            front = ShellFront(timeline: session.timelineID, landings: session.landings)
            if let standing { selected = FediqoRootView.land(standing, on: &walk) }
        }

        /// One pass of the root: the session's front answered, then — a tick later, as
        /// `KeepsReadingPlace` does it — the session told where the root stands.
        @MainActor
        mutating func answer(_ session: ShellSession) -> [ShellFront.Answer] {
            let arrived = ShellFront(timeline: session.timelineID, landings: session.landings)
            let answers = arrived.answers(after: front)
            for answer in answers {
                switch answer {
                case .switched(let left, let arrived):
                    _ = FediqoRootView.timelineSwitched(
                        on: &walk, places: &session.timelinePlaces, from: left, to: arrived,
                        shown: session.timelineItems(latest: nil).map(\.id), results: nil
                    )
                case .landed:
                    if let stopped = session.takeLanding() { selected = FediqoRootView.land(stopped, on: &walk) }
                }
            }
            front = arrived
            session.stands(ReadingPlace.standing(lamp: selected, walk: walk, searching: false, parked: nil))
            return answers
        }
    }

    /// A device launched on the place it kept, with the reader gone to Preferences.
    private struct Here {
        let device: KeptDevice
        let session: ShellSession
        let prefs: DummyPrefs
        var root: Root

        /// The bytes kept under the place's key, or nothing where none are.
        @MainActor
        var bytes: Data? { device.defaults.object(forKey: "fediqo.place") as? Data }
    }

    private func here(stoppedAt place: (KeptDevice) throws -> ReadingPlace) async throws -> Here {
        let device = KeptDevice()
        await device.hold()
        // English said first: preferences read set the shell's language, which every suite shares.
        device.defaults.set("en", forKey: "fediqo.dummy.language")
        device.keep(try place(device))
        let session = device.session()
        let standing = await device.launch(session)
        let root = Root(session, standing: standing)
        return Here(device: device, session: session, prefs: DummyPrefs(defaults: device.defaults), root: root)
    }

    /// What the carrier leaves: the store replaced, and the settings replaced whole — a key the
    /// package did not carry is gone.
    private func readBack(_ package: KeptDevice, onto here: Here, posts: [Note] = ReadingPlaceReadBackTests.theirs) async {
        await here.device.store.replace(sources: [KeptDevice.microblog], notes: posts)
        for key in ["fediqo.place", "fediqo.timelines", "fediqo.dummy.latestDate"] {
            here.device.defaults.removeObject(forKey: key)
            if let value = package.defaults.object(forKey: key) { here.device.defaults.set(value, forKey: key) }
        }
    }

    // MARK: Acceptance: the place read back is held, the rail stays, and what is kept stays the read back's

    @Test("Adopted on Preferences: the session holds the place read back, on its own written timeline, and the bytes kept are still the package's after a change of tab")
    func adoptsThePlace() async throws {
        var here = try await here { _ in ReadingPlace(timeline: .trends, lamp: row("t2"), top: row("t1"), thread: row("t2")) }
        let session = here.session
        #expect(here.root.walk.openedThread == row("t2"))

        // The device the package was taken from: its own timeline for Ada, and where it stopped.
        let package = KeptDevice()
        let theirTimeline = try package.writeTimeline()
        let stopped = ReadingPlace(timeline: theirTimeline, lamp: row("r1"), top: row("p3"), thread: row("p2"))
        package.keep(stopped)
        await readBack(package, onto: here)
        let bytes = try #require(here.bytes)
        let writes = here.device.defaults.writes

        await session.adoptReadBack(prefs: here.prefs)
        // The timeline is the package's own, which only the package's timelines can name.
        #expect(session.written.map(\.id).map(TimelineQuery.written) == [theirTimeline])
        #expect(session.timelineID == theirTimeline)
        #expect(session.readingPlace == stopped)
        #expect(session.keepsPlace)
        #expect(here.bytes == bytes)

        // The root answers: the switch ends the conversation it had open, and the landing opens
        // the one read back — in that order — and what it then tells the session is the place.
        let answers = here.root.answer(session)
        #expect(answers == [.switched(from: .trends, to: theirTimeline), .landed])
        #expect(here.root.walk.openedThread == row("p2"))
        #expect(here.root.walk.depth == 1)
        #expect(here.root.selected == row("p2"))
        #expect(session.readingPlace == stopped)
        #expect(here.bytes == bytes)

        // The rail was on Preferences throughout, and is allowed to stay: nothing here moved it.
        #expect(session.availability.placing(here.root.place, as: here.root.place) == .preferences)
        // A change of tab — the pages it closes on the session, and the root's pass again.
        session.usageOpened = nil
        session.preferencesOpened = nil
        #expect(here.root.answer(session).isEmpty)
        #expect(here.bytes == bytes)
        #expect(here.device.defaults.writes == writes)

        // The timeline place shown again lands its list on what was read back.
        #expect(TimelinePane.landing(selected: session.readingPlace?.lamp, top: session.listTop(found: nil)) == .centred(row("r1")))
        #expect(session.topIsOwed)

        // And from here a move is written, as on any other day.
        _ = here.root.walk.back()
        here.root.selected = row("p3")
        _ = here.root.answer(session)
        #expect(here.device.kept == ReadingPlace(timeline: theirTimeline, lamp: row("p3"), top: row("p3")))
    }

    /// No `timelineID` change at all, so nothing but the landing says there is anything to adopt.
    @Test("The timeline read back is the one already in front: the lamp, the top row and the conversation are adopted all the same")
    func sameTimeline() async throws {
        var here = try await here { _ in ReadingPlace(timeline: .all, lamp: row("p1"), top: row("p1"), thread: row("p1")) }
        let session = here.session

        let package = KeptDevice()
        let stopped = ReadingPlace(timeline: .all, lamp: row("r4"), top: row("p2"))
        package.keep(stopped)
        await readBack(package, onto: here)
        let bytes = try #require(here.bytes)
        let writes = here.device.defaults.writes

        await session.adoptReadBack(prefs: here.prefs)
        #expect(session.timelineID == .all)
        #expect(session.readingPlace == stopped)

        #expect(here.root.answer(session) == [.landed])
        // The conversation it had open was around a post of the store replaced, and is gone.
        #expect(here.root.walk.isEmpty)
        #expect(here.root.selected == row("r4"))
        #expect(session.readingPlace == stopped)
        #expect(here.bytes == bytes)
        #expect(here.device.defaults.writes == writes)
    }

    @Test("Each part of the place read back is asked of what was read back: a post it does not hold is no lamp, no top row, no conversation")
    func validatedAgainstWhatWasReadBack() async throws {
        var here = try await here { _ in ReadingPlace(timeline: .all, lamp: row("p1")) }
        let session = here.session

        // `p1` and `t3` are this device's and were not read back; `r1` was.
        let package = KeptDevice()
        package.keep(ReadingPlace(timeline: .all, lamp: row("p1"), top: row("r1"), thread: row("t3")))
        await readBack(package, onto: here)
        let bytes = try #require(here.bytes)

        await session.adoptReadBack(prefs: here.prefs)
        #expect(session.readingPlace == ReadingPlace(timeline: .all, top: row("r1")))
        #expect(here.root.answer(session) == [.landed])
        #expect(here.root.selected == nil)
        #expect(here.root.walk.isEmpty)
        // What is kept is still what the package brought, until the reader moves.
        #expect(here.bytes == bytes)
    }

    /// The latest date is one of the choices read back, and decides which posts the list holds.
    @Test("The list the place is asked of stops at the latest date read back with it")
    func latestDateReadBack() async throws {
        var here = try await here { _ in ReadingPlace(timeline: .all) }
        let session = here.session
        #expect(here.prefs.latestDate == nil)

        let late = Note(
            id: "late", source: KeptDevice.microblog, author: "Ada", handle: "@ada@m.example", body: "late",
            postedAt: Date(timeIntervalSince1970: 1_800_000_000), categories: [.public]
        )
        let package = KeptDevice()
        let stopsAt = try #require(LatestDate(year: 2026, month: 9, day: 1))
        package.defaults.set(stopsAt.text, forKey: "fediqo.dummy.latestDate")
        package.keep(ReadingPlace(timeline: .all, lamp: row("late"), top: row("r1")))
        await readBack(package, onto: here, posts: Self.theirs + [late])

        await session.adoptReadBack(prefs: here.prefs)
        #expect(here.prefs.latestDate == stopsAt)
        #expect(session.heldNote(row("late")) != nil)
        #expect(session.readingPlace == ReadingPlace(timeline: .all, top: row("r1")))
        _ = here.root.answer(session)
        #expect(here.root.selected == nil)
    }

    // MARK: A package that brought no place, or one this build cannot read

    /// A package taken away by a build that kept no place. The settings are replaced whole, so
    /// the key is gone — and the place this device stood on, which was about the store replaced,
    /// goes with it rather than being written back as the first thing the session says.
    @Test("No place in the package: All with nothing lit, nothing kept, and the next move writes a fresh place")
    func noPlaceInThePackage() async throws {
        // Trends is a tab before and after, so nothing but the adoption takes the reader off it.
        var here = try await here { _ in ReadingPlace(timeline: .trends, lamp: row("t2"), top: row("t1"), thread: row("t2")) }
        let session = here.session
        // This run left All and a tab beside it each standing on a post, and the store read
        // back happens to hold a post under each of those ids.
        session.timelinePlaces.leave(.all, standingOn: row("p2"))
        session.timelinePlaces.leave(.trends, standingOn: row("r4"))

        await readBack(KeptDevice(), onto: here)
        #expect(here.bytes == nil)
        let writes = here.device.defaults.writes

        await session.adoptReadBack(prefs: here.prefs)
        #expect(session.timelineID == .all)
        #expect(session.readingPlace == ReadingPlace(timeline: .all))
        #expect(!session.topIsOwed)
        // What this run stood on in each timeline was the replaced store's, and is forgotten.
        #expect(session.timelinePlaces.arriving(at: .all, among: session.rows(of: .all, latest: nil)) == nil)
        #expect(session.rows(of: .trends, latest: nil) == [row("r4")])
        #expect(session.timelinePlaces.arriving(at: .trends, among: session.rows(of: .trends, latest: nil)) == nil)

        #expect(here.root.answer(session) == [.switched(from: .trends, to: .all), .landed])
        #expect(here.root.selected == nil)
        #expect(here.root.walk.isEmpty)
        #expect(session.readingPlace == ReadingPlace(timeline: .all))
        #expect(here.device.defaults.object(forKey: "fediqo.place") == nil)
        #expect(here.device.defaults.writes == writes)

        here.root.selected = row("r1")
        _ = here.root.answer(session)
        #expect(here.device.kept == ReadingPlace(timeline: .all, lamp: row("r1")))
    }

    /// A newer build's shape. **What the reader sees**: All from the top with nothing lit and no
    /// conversation, as with no place at all — and from then on this build keeps no place on
    /// this device, since what is kept is never written over; the build that can read it lands
    /// on it.
    @Test("A place in the package this build cannot read: All with nothing lit, and the bytes are never written over")
    func unreadablePlace() async throws {
        var here = try await here { _ in ReadingPlace(timeline: .trends, lamp: row("t2"), thread: row("t2")) }
        let session = here.session

        let package = KeptDevice()
        let newer = Data(#"{"version":2,"timeline":"trends","lamp":"x","pane":"left"}"#.utf8)
        package.defaults.set(newer, forKey: "fediqo.place")
        await readBack(package, onto: here)

        await session.adoptReadBack(prefs: here.prefs)
        #expect(session.readingPlace == ReadingPlace(timeline: .all))
        _ = here.root.answer(session)
        #expect(here.root.selected == nil)
        #expect(here.root.walk.isEmpty)
        #expect(here.bytes == newer)

        // A lamp lit and a timeline pressed, each of which is written on any other day.
        here.root.selected = row("r1")
        _ = here.root.answer(session)
        #expect(session.readingPlace == ReadingPlace(timeline: .all, lamp: row("r1")))
        session.timelineID = .trends
        _ = here.root.answer(session)
        #expect(session.timelineID == .trends)
        #expect(here.bytes == newer)
    }

    @Test("A read back that holds no source: nothing is in front, the root lets go of what it stood on, and the place read back is left as it is")
    func nothingJoinedAfterReadBack() async throws {
        var here = try await here { _ in ReadingPlace(timeline: .all, lamp: row("p1"), thread: row("p1")) }
        let session = here.session

        let package = KeptDevice()
        package.keep(ReadingPlace(timeline: .all, lamp: row("r1")))
        await here.device.store.replace(sources: [], notes: [])
        here.device.defaults.removeObject(forKey: "fediqo.place")
        here.device.defaults.set(try #require(package.defaults.object(forKey: "fediqo.place")), forKey: "fediqo.place")
        let bytes = try #require(here.bytes)

        await session.adoptReadBack(prefs: here.prefs)
        #expect(session.timelineID == nil)
        #expect(here.root.answer(session) == [.switched(from: .all, to: nil), .landed])
        #expect(here.root.selected == nil)
        #expect(here.root.walk.isEmpty)
        #expect(here.bytes == bytes)
    }

    // MARK: Nothing is written on the way, and nothing held changes

    /// The carrier holds the store still from its first byte, and the session's own follow of
    /// the store runs meanwhile: the tabs rebuilt for what was read back can force another
    /// timeline in front before the adoption begins.
    @Test("While the store is held still nothing is written: a timeline forced in front before the adoption does not write over the place read back")
    func heldStill() async throws {
        var here = try await here { _ in ReadingPlace(timeline: .trends, lamp: row("t2")) }
        let session = here.session

        let package = KeptDevice()
        let stopped = ReadingPlace(timeline: .all, lamp: row("r1"), top: row("p2"))
        package.keep(stopped)
        session.holdsStill = true
        await readBack(package, onto: here)
        let bytes = try #require(here.bytes)
        let writes = here.device.defaults.writes

        // Before the adoption: the store followed, and the root's pass on what that did.
        session.timelineID = .all
        _ = here.root.answer(session)
        #expect(here.bytes == bytes)

        await session.adoptReadBack(prefs: here.prefs)
        _ = here.root.answer(session)
        session.holdsStill = false
        #expect(session.readingPlace == stopped)
        #expect(here.root.selected == row("r1"))
        #expect(here.bytes == bytes)
        #expect(here.device.defaults.writes == writes)
    }

    /// A take-away holds the store too, and can be long: a reader who moves meanwhile and
    /// quits after it must not find the place a step behind.
    @Test("A move made while the store is held still is written as it is let go, and a hold with no move writes nothing")
    func aMoveWhileHeld() async throws {
        let here = try await here { _ in ReadingPlace(timeline: .all, lamp: row("p1")) }
        let session = here.session
        let writes = here.device.defaults.writes

        session.holdsStill = true
        session.stands(ReadingPlace.Standing(lamp: row("p2")))
        session.stands(ReadingPlace.Standing(lamp: row("p3")))
        #expect(here.device.defaults.writes == writes)
        #expect(here.device.kept == ReadingPlace(timeline: .all, lamp: row("p1")))

        session.holdsStill = false
        #expect(here.device.kept == ReadingPlace(timeline: .all, lamp: row("p3")))
        #expect(here.device.defaults.writes == writes + 1)

        session.holdsStill = true
        session.holdsStill = false
        #expect(here.device.defaults.writes == writes + 1)
    }

    /// The place read back names a post the store read back does not hold, so where the session
    /// stands differs from the bytes kept. Letting the store go is no move, and must not write
    /// the one over the other.
    @Test("The store let go after an adoption writes nothing, though a part of the place read back was not held")
    func letGoAfterAdoption() async throws {
        var here = try await here { _ in ReadingPlace(timeline: .trends, lamp: row("t2")) }
        let session = here.session

        let package = KeptDevice()
        package.keep(ReadingPlace(timeline: .all, lamp: row("p1"), top: row("r1"), thread: row("t3")))
        session.holdsStill = true
        await readBack(package, onto: here)
        let bytes = try #require(here.bytes)
        let writes = here.device.defaults.writes

        await session.adoptReadBack(prefs: here.prefs)
        #expect(session.readingPlace == ReadingPlace(timeline: .all, top: row("r1")))
        session.holdsStill = false
        #expect(here.bytes == bytes)
        _ = here.root.answer(session)
        #expect(here.bytes == bytes)
        #expect(here.device.defaults.writes == writes)

        // A move is still a move.
        here.root.selected = row("r1")
        _ = here.root.answer(session)
        #expect(here.device.kept == ReadingPlace(timeline: .all, lamp: row("r1"), top: row("r1")))
    }

    // MARK: A move of sign-ins only

    /// Neither the store nor the settings were replaced, so there is no place to come back to
    /// and nothing of where the reader stands to forget.
    @Test("Adopted with only sign-ins moved, where the reader stands is left as it is, and what they did meanwhile is written")
    func signInsOnly() async throws {
        var here = try await here { _ in ReadingPlace(timeline: .trends, lamp: row("t2"), top: row("t1"), thread: row("t2")) }
        let session = here.session
        session.timelinePlaces.leave(.all, standingOn: row("p2"))
        let landings = session.landings
        let writes = here.device.defaults.writes

        // The move holds the store still; the reader lights another post meanwhile.
        session.holdsStill = true
        here.root.walk = ShellWalk()
        here.root.selected = row("t3")
        _ = here.root.answer(session)
        #expect(here.device.defaults.writes == writes)

        await session.adoptReadBack(prefs: here.prefs, placeToo: false)
        #expect(session.landings == landings)
        #expect(session.takeLanding() == nil)
        #expect(session.keepsPlace)
        #expect(session.readingPlace == ReadingPlace(timeline: .trends, lamp: row("t3"), top: row("t1")))
        #expect(session.timelinePlaces.arriving(at: .all, among: session.rows(of: .all, latest: nil)) == row("p2"))
        #expect(here.root.answer(session).isEmpty)
        #expect(here.root.selected == row("t3"))

        session.holdsStill = false
        #expect(here.device.kept == ReadingPlace(timeline: .trends, lamp: row("t3"), top: row("t1")))
    }

    @Test("Only a move done with sign-ins alone leaves the store where it was")
    func whichMovesReplaceTheStore() {
        func summary(_ contents: PackageSummary.Contents) -> PackageSummary {
            PackageSummary(
                contents: contents, sources: [], posts: 0, timelines: 0, takenAt: Date(timeIntervalSince1970: 0),
                withPictures: false, bytes: 0, hasSecrets: true, device: "a laptop", appVersion: "1.0.0", entryCount: 1
            )
        }
        #expect(ShellNearby.Step.done(summary(.whole), peer: "a laptop").movedStore)
        #expect(!ShellNearby.Step.done(summary(.signInsOnly), peer: "a laptop").movedStore)
        #expect(ShellNearby.Step.holding(code: "1234").movedStore)
    }

    @Test("Adopting the place changes no post read back, no mark on one, and no preference")
    func nothingHeldChanges() async throws {
        var here = try await here { _ in ReadingPlace(timeline: .trends, lamp: row("t2"), thread: row("t2")) }
        let session = here.session

        let package = KeptDevice()
        let theirTimeline = try package.writeTimeline()
        package.keep(ReadingPlace(timeline: theirTimeline, lamp: row("r1"), top: row("p3"), thread: row("p2")))
        await readBack(package, onto: here)
        let store = here.device.store
        #expect(await store.markGone(Self.theirs[1].key))

        let before = await store.snapshot()
        let drawn = await store.drawn
        let aside = await store.asideRevision
        let gone = await store.goneCount()
        let settled = await store.settledCount()
        let writes = here.device.defaults.writes

        await session.adoptReadBack(prefs: here.prefs)
        _ = here.root.answer(session)

        let after = await store.snapshot()
        #expect(after.revision == before.revision)
        #expect(after.notes == before.notes)
        #expect(after.sources == before.sources)
        #expect(await store.drawn == drawn)
        #expect(await store.asideRevision == aside)
        #expect(await store.goneCount() == gone)
        #expect(await store.settledCount() == settled)
        #expect(here.device.defaults.writes == writes)
    }

    @Test("A session whose launch has not landed yet adopts the place and still writes nothing until it has")
    func beforeTheLaunchHasLanded() async throws {
        let device = KeptDevice()
        await device.hold(Self.theirs)
        device.defaults.set("en", forKey: "fediqo.dummy.language")
        let stopped = ReadingPlace(timeline: .all, lamp: row("r1"))
        device.keep(stopped)
        let session = device.session()
        await session.reloadFromStore()

        await session.adoptReadBack(prefs: DummyPrefs(defaults: device.defaults))
        #expect(!session.keepsPlace)
        #expect(session.readingPlace == stopped)
    }

    // MARK: The order the root answers in

    @Test("A switch and a landing in one pass are answered switch first; each alone is answered alone; nothing moved, nothing")
    func theOrderOfAnswers() {
        let before = ShellFront(timeline: .trends, landings: 1)
        #expect(ShellFront(timeline: .all, landings: 2).answers(after: before) == [.switched(from: .trends, to: .all), .landed])
        #expect(ShellFront(timeline: .trends, landings: 2).answers(after: before) == [.landed])
        #expect(ShellFront(timeline: nil, landings: 1).answers(after: before) == [.switched(from: .trends, to: nil)])
        #expect(ShellFront(timeline: .trends, landings: 1).answers(after: before).isEmpty)
    }

    /// Why the order: the same two answers the other way round.
    @Test("Answered landing first, the switch would end the conversation just come back to")
    func theOtherOrderLosesTheConversation() {
        var walk = ShellWalk()
        var places = TimelinePlaces()
        _ = FediqoRootView.land(ReadingPlace.Standing(lamp: "a2", thread: "a3"), on: &walk)
        _ = FediqoRootView.timelineSwitched(
            on: &walk, places: &places, from: .trends, to: .all, shown: ["a2", "a3"], results: nil
        )
        #expect(walk.isEmpty)
    }
}
