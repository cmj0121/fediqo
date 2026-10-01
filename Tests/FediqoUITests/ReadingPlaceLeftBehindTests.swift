import Foundation
@testable import FediqoCore
import Testing
@testable import FediqoUI

/// #273 against #221: nothing left behind may name a source the person removed, and the place
/// reading stopped at names posts by `host` and id. A source removed takes its posts out of the
/// place at once — what is kept, and what this session writes from then on — and the last source
/// removed leaves no place at all.
///
/// **A post let go by a limit or a span is not this.** Its row id names a host the person still
/// reads, so nothing of a removed source is left behind, and a place naming a post no longer
/// held is what the landing's own check is for (`ReadingPlaceLaunchTests`).
@Suite("A source removed is not named by the place kept")
@MainActor
struct ReadingPlaceLeftBehindTests {
    private static let stays = KeptDevice.microblog
    private static let goes = Source(host: "gone.example", kind: .mastodon)

    init() {
        L10n.language = .english
    }

    private static func note(_ id: String, from source: Source, at t: Double) -> Note {
        Note(id: id, source: source, author: "Ada", handle: "@ada@\(source.host)", body: id,
             postedAt: Date(timeIntervalSince1970: t), categories: [.public])
    }

    private static func row(_ id: String, from source: Source) -> String {
        NoteKey(host: source.host, id: id).rowID
    }

    /// A device reading two sources, launched on the place it kept.
    private func launched(
        sources: [Source] = [stays, goes], stoppedAt place: ReadingPlace
    ) async -> (device: KeptDevice, session: ShellSession) {
        let device = KeptDevice()
        var notes: [Note] = []
        if sources.contains(Self.stays) {
            notes += [Self.note("s1", from: Self.stays, at: 9), Self.note("s2", from: Self.stays, at: 7)]
        }
        if sources.contains(Self.goes) {
            notes += [Self.note("g1", from: Self.goes, at: 8), Self.note("g2", from: Self.goes, at: 6)]
        }
        await device.store.replace(sources: sources, notes: notes)
        device.keep(place)
        let session = device.session()
        _ = await device.launch(session)
        return (device, session)
    }

    /// What is kept, as text: the bytes a take-away would carry.
    private func kept(_ device: KeptDevice) -> String? {
        (device.defaults.object(forKey: "fediqo.place") as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    private let s1 = row("s1", from: stays)
    private let s2 = row("s2", from: stays)
    private let g1 = row("g1", from: goes)
    private let g2 = row("g2", from: goes)

    // MARK: A source the place names

    @Test("The source of the lamp and the conversation removed: what is kept no longer names it, at once, and keeps the rest")
    func namedSourceRemoved() async throws {
        let (device, session) = await launched(stoppedAt: ReadingPlace(timeline: .all, lamp: g1, top: s1, thread: g2))
        #expect(kept(device)?.contains("gone.example") == true)

        await session.remove(host: "gone.example")
        #expect(kept(device)?.contains("gone.example") == false)
        #expect(device.kept == ReadingPlace(timeline: .all, top: s1))
        #expect(session.readingPlace == ReadingPlace(timeline: .all, top: s1))
    }

    @Test("The source of the top row removed: the top row goes, and the lamp stays")
    func topRowOfTheSourceRemoved() async throws {
        let (device, session) = await launched(stoppedAt: ReadingPlace(timeline: .all, lamp: s2, top: g1))
        await session.remove(host: "gone.example")
        #expect(kept(device)?.contains("gone.example") == false)
        #expect(device.kept == ReadingPlace(timeline: .all, lamp: s2))
    }

    /// The root view is told nothing of a removal: its lamp and its walk go on naming the row.
    /// What it says of where it stands is not written down as it says it.
    @Test("The root still standing on a removed source's post does not put its name back")
    func theRootStillStandsOnIt() async throws {
        let (device, session) = await launched(stoppedAt: ReadingPlace(timeline: .all, lamp: g1, top: s1, thread: g1))
        await session.remove(host: "gone.example")

        session.stands(ReadingPlace.Standing(lamp: g2, thread: g2))
        session.scrolledTop = g2
        session.stands(ReadingPlace.Standing(lamp: g1))
        session.scrolledTop = s2
        #expect(kept(device)?.contains("gone.example") == false)
        #expect(device.kept == ReadingPlace(timeline: .all, top: s2))
        for written in device.defaults.sets.suffix(3).compactMap({ $0.value as? Data }) {
            #expect(String(data: written, encoding: .utf8)?.contains("gone.example") == false)
        }
    }

    @Test("Removed while the store is held still, the name is taken out all the same")
    func removedWhileHeldStill() async throws {
        let (device, session) = await launched(stoppedAt: ReadingPlace(timeline: .all, lamp: g1, top: s1))
        session.holdsStill = true
        await session.remove(host: "gone.example")
        #expect(kept(device)?.contains("gone.example") == false)
        #expect(device.kept == ReadingPlace(timeline: .all, top: s1))
    }

    @Test("Removed before the launch has landed, the name is taken out of what is kept all the same")
    func removedBeforeLanding() async throws {
        let device = KeptDevice()
        await device.store.replace(
            sources: [Self.stays, Self.goes],
            notes: [Self.note("s1", from: Self.stays, at: 9), Self.note("g1", from: Self.goes, at: 8)]
        )
        device.keep(ReadingPlace(timeline: .trends, lamp: g1, top: s1, thread: g1))
        let session = device.session()
        await session.reloadFromStore()
        #expect(!session.keepsPlace)

        await session.remove(host: "gone.example")
        #expect(device.kept == ReadingPlace(timeline: .trends, top: s1))
    }

    // MARK: The last source

    @Test("The last source removed: nothing is in front, and no place is kept", arguments: [false, true])
    func lastSourceRemoved(keepingPosts: Bool) async throws {
        let (device, session) = await launched(
            sources: [Self.goes], stoppedAt: ReadingPlace(timeline: .all, lamp: g1, top: g2, thread: g1)
        )
        await session.remove(host: "gone.example", keepingPosts: keepingPosts)
        #expect(session.timelineID == nil)
        #expect(device.defaults.object(forKey: "fediqo.place") == nil)

        // A source joined afterwards starts from All, and from no place.
        session.sources = [Self.stays]
        session.rebuildQueries()
        #expect(device.kept == ReadingPlace(timeline: .all))
    }

    // MARK: What is left alone

    @Test("A source the place does not name removed: what is kept is the same bytes, and nothing is written")
    func unnamedSourceRemoved() async throws {
        let (device, session) = await launched(stoppedAt: ReadingPlace(timeline: .all, lamp: s2, top: s1, thread: s2))
        let bytes = device.defaults.data(forKey: "fediqo.place")
        let writes = device.defaults.writes

        await session.remove(host: "gone.example")
        #expect(device.defaults.data(forKey: "fediqo.place") == bytes)
        #expect(device.defaults.writes == writes)
    }

    /// The person's standing choice (#250): the source goes and its posts stay, drawn and held.
    /// The store names them still, and so may the place.
    @Test("Removed with its posts kept: the place goes on naming the post it stands on")
    func removedKeepingPosts() async throws {
        let stopped = ReadingPlace(timeline: .all, lamp: g1, top: s1, thread: g1)
        let (device, session) = await launched(stoppedAt: stopped)
        await session.remove(host: "gone.example", keepingPosts: true)
        #expect(session.heldNote(g1) != nil)
        #expect(device.kept == stopped)
        session.stands(ReadingPlace.Standing(lamp: g2))
        #expect(device.kept == ReadingPlace(timeline: .all, lamp: g2, top: s1))
    }

    // MARK: Posts kept past their source, and let go later

    /// Nobody moves here. The posts of the removed source go by a press on Usage, and the place
    /// that named one of them is the one thing left naming that source.
    @Test("A removed source's kept posts let go by a span: what is kept stops naming the source at once, with no move by the reader")
    func keptPostsLetGoBySpan() async throws {
        let stopped = ReadingPlace(timeline: .all, lamp: g1, top: s1, thread: g2)
        let (device, session) = await launched(stoppedAt: stopped)
        await session.remove(host: "gone.example", keepingPosts: true)
        #expect(kept(device)?.contains("gone.example") == true)

        let span = Date(timeIntervalSince1970: 0) ..< Date(timeIntervalSince1970: 100)
        #expect(await session.letGo(span: span, host: "gone.example") == 2)
        #expect(session.heldNote(g1) == nil)
        #expect(kept(device)?.contains("gone.example") == false)
        #expect(device.kept == ReadingPlace(timeline: .all, top: s1))
    }

    @Test("Posts let go that the place does not name write nothing")
    func otherPostsLetGo() async throws {
        let (device, session) = await launched(stoppedAt: ReadingPlace(timeline: .all, lamp: s2, top: s1))
        session.stands(ReadingPlace.Standing(lamp: s1))
        let writes = device.defaults.writes

        let span = Date(timeIntervalSince1970: 0) ..< Date(timeIntervalSince1970: 100)
        #expect(await session.letGo(span: span, host: "gone.example") == 2)
        #expect(device.defaults.writes == writes)
    }

    // MARK: The same source joined again

    /// What was last handed over is the place with the lamp; removing the source takes the lamp
    /// out of what is kept underneath it. The root never moved, so with the source back the
    /// place is the one last handed over again — and taken for written, it would not be.
    @Test("Removed and joined again with the root still on the same post: the place is written again with its lamp")
    func joinedAgain() async throws {
        let (device, session) = await launched(stoppedAt: ReadingPlace(timeline: .all, top: s1))
        session.stands(ReadingPlace.Standing(lamp: g1))
        let stood = ReadingPlace(timeline: .all, lamp: g1, top: s1)
        #expect(device.kept == stood)

        await session.remove(host: "gone.example")
        #expect(device.kept == ReadingPlace(timeline: .all, top: s1))

        await device.store.replace(
            sources: [Self.stays, Self.goes],
            notes: [Self.note("s1", from: Self.stays, at: 9), Self.note("g1", from: Self.goes, at: 8)]
        )
        await session.reloadFromStore()
        #expect(session.readingPlace == stood)
        // The next thing that asks for the place to be written, with no move by the root.
        session.placeAfterLettingGo()
        #expect(device.kept == stood)
    }

    @Test("What is kept and cannot be read is not touched by a source removed, the last one included")
    func unreadableIsLeft() async throws {
        let (device, session) = await launched(stoppedAt: ReadingPlace(timeline: .all, lamp: g1))
        let newer = Data(#"{"version":2,"timeline":"all","lamp":"gone.example\u001eg1"}"#.utf8)
        device.defaults.set(newer, forKey: "fediqo.place")

        await session.remove(host: "gone.example")
        #expect(device.defaults.data(forKey: "fediqo.place") == newer)
        await session.remove(host: Self.stays.host)
        #expect(session.timelineID == nil)
        #expect(device.defaults.data(forKey: "fediqo.place") == newer)
    }

    // MARK: The store's own three acts

    @Test("Forgetting a host takes only the rows that are its, whatever its case, and writes only where one went")
    func forgetHost() {
        let defaults = CountingDefaults()
        let store = ReadingPlaceStore(defaults: defaults)
        store.save(ReadingPlace(timeline: .trends, lamp: g1, top: s1, thread: g2))
        let writes = defaults.writes

        store.forget(host: "other.example")
        #expect(defaults.writes == writes)
        store.forget(host: "GONE.example")
        #expect(store.load() == ReadingPlace(timeline: .trends, top: s1))
        #expect(defaults.writes == writes + 1)
        store.forget(host: "gone.example")
        #expect(defaults.writes == writes + 1)

        // Nothing kept: nothing to forget, and nothing written.
        let empty = CountingDefaults()
        ReadingPlaceStore(defaults: empty).forget(host: "gone.example")
        #expect(empty.writes == 0)
    }

    @Test("Removing takes a place that can be read, and discarding only one that cannot")
    func removeAndDiscard() {
        let defaults = CountingDefaults()
        let store = ReadingPlaceStore(defaults: defaults)
        let place = ReadingPlace(timeline: .all, lamp: s1)
        store.save(place)
        store.discardUnreadable()
        #expect(store.load() == place)
        store.remove()
        #expect(defaults.object(forKey: "fediqo.place") == nil)

        let newer = Data(#"{"version":2,"timeline":"all"}"#.utf8)
        defaults.set(newer, forKey: "fediqo.place")
        store.remove()
        store.forget(host: "gone.example")
        #expect(defaults.data(forKey: "fediqo.place") == newer)
        store.discardUnreadable()
        #expect(defaults.object(forKey: "fediqo.place") == nil)
    }

    // MARK: Larger than a place can be

    @Test("A blob larger than any place is not read, though its shape is this build's, and is not written over")
    func tooLargeIsUnreadable() throws {
        let defaults = CountingDefaults()
        let store = ReadingPlaceStore(defaults: defaults)
        let long = String(repeating: "x", count: ReadingPlaceStore.maxBytes)
        let huge = try JSONSerialization.data(withJSONObject: ["version": 1, "timeline": "all", "lamp": long])
        #expect(huge.count > ReadingPlaceStore.maxBytes)
        defaults.set(huge, forKey: "fediqo.place")
        #expect(store.load() == nil)
        #expect(!store.save(ReadingPlace(timeline: .all)))
        #expect(defaults.data(forKey: "fediqo.place") == huge)

        // At the bound it is still read.
        let pad = String(repeating: "x", count: 64)
        var fits = try JSONSerialization.data(withJSONObject: ["version": 1, "timeline": "all", "lamp": pad])
        let more = String(repeating: "x", count: 64 + ReadingPlaceStore.maxBytes - fits.count)
        fits = try JSONSerialization.data(withJSONObject: ["version": 1, "timeline": "all", "lamp": more])
        #expect(fits.count == ReadingPlaceStore.maxBytes)
        defaults.set(fits, forKey: "fediqo.place")
        #expect(store.load() == ReadingPlace(timeline: .all, lamp: more))
    }

    @Test("A place this build would write larger than it reads is not written at all")
    func tooLargeIsNotWritten() {
        let defaults = CountingDefaults()
        let store = ReadingPlaceStore(defaults: defaults)
        let kept = ReadingPlace(timeline: .all, lamp: s1)
        store.save(kept)
        store.save(ReadingPlace(timeline: .all, lamp: String(repeating: "x", count: ReadingPlaceStore.maxBytes)))
        #expect(store.load() == kept)
        #expect(defaults.writes == 1)
    }

    // MARK: Found unreadable once, not asked again

    @Test("Once the store has refused a place as unreadable it is not asked again for the moves that follow, until what is kept may have changed")
    func unreadableIsAskedOnce() async throws {
        let device = KeptDevice()
        await device.hold()
        let session = device.session()
        _ = await device.launch(session)
        let newer = Data(#"{"version":2,"timeline":"all"}"#.utf8)
        device.defaults.set(newer, forKey: "fediqo.place")

        // The first move asks, and is refused.
        var reads = device.defaults.reads
        session.scrolledTop = KeptDevice.row("p1")
        #expect(device.defaults.reads == reads + 1)

        // Every row that passes after it asks nothing.
        reads = device.defaults.reads
        session.scrolledTop = KeptDevice.row("p2")
        session.scrolledTop = KeptDevice.row("p3")
        session.stands(ReadingPlace.Standing(lamp: KeptDevice.row("p2")))
        session.timelineID = .trends
        #expect(device.defaults.reads == reads)
        #expect(device.defaults.data(forKey: "fediqo.place") == newer)

        // What is kept is replaced underneath, as a read back replaces it: the verdict goes with
        // the stop, and the next move is written.
        session.stopKeepingPlace()
        device.defaults.removeObject(forKey: "fediqo.place")
        session.keepPlaceFromHere()
        session.scrolledTop = KeptDevice.row("t1")
        #expect(device.kept == ReadingPlace(timeline: .trends, top: KeptDevice.row("t1")))
    }
}
