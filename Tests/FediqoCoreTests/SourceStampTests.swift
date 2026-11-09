import Foundation
import Testing
@testable import FediqoCore

/// U3: every local source change stamps — add, a boards edit, a removal (a tombstone) — and a
/// change to lists, what a source said, or a sign-in does not (D3, D4). A merge's entries lay in
/// as they came and make no stamp of their own.
@Suite("Source stamps and tombstones")
struct SourceStampTests {
    private static let one = Source(host: "one.example", kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 1, name: "One")])

    /// A clock whose wall stands still at `ms`, so stamps differ only by counter.
    private static func clock(_ device: String = "here", ms: Int64 = 1_000) -> SyncClock {
        SyncClock(device: device) { Date(timeIntervalSince1970: Double(ms) / 1000) }
    }

    private static func stamp(_ ms: Int64, _ device: String = "there") -> SyncStamp {
        SyncStamp(ms: ms, counter: 0, device: device)
    }

    @Test("Adding a source stamps it now; adding a host already here stamps nothing")
    func addStamps() async {
        let store = ItemStore()
        await store.stamp(with: Self.clock())
        await store.add(Self.one)
        let first = await store.sourceSync().stamps[Self.one.host]
        #expect(first?.device == "here")
        #expect(first?.ms == 1_000)
        await store.add(Source(host: Self.one.host, kind: .discuz))
        #expect(await store.sourceSync().stamps[Self.one.host] == first)
    }

    @Test("A clock handed to the init stamps from the first change, later than every stamp held")
    func clockAtInit() async {
        let store = ItemStore(
            sources: [], notes: [], sync: SourceSync(gone: ["old.example": Self.stamp(9_000)]), clock: Self.clock(ms: 1_000)
        )
        await store.add(Self.one)
        let made = await store.sourceSync().stamps[Self.one.host]
        #expect(made?.device == "here")
        #expect(made.map { $0 > Self.stamp(9_000) } == true)
    }

    @Test("A boards edit stamps; the same boards again do not")
    func boardsStamp() async {
        let store = ItemStore(sources: [Self.forum], notes: [])
        await store.stamp(with: Self.clock())
        #expect(await store.sourceSync().stamps.isEmpty, "a source read without a stamp is .zero")
        await store.subscribe(host: Self.forum.host, to: Self.forum.boards)
        #expect(await store.sourceSync().stamps.isEmpty)
        await store.subscribe(host: Self.forum.host, to: [BoardSubscription(fid: 2, name: "Two")])
        #expect(await store.sourceSync().stamps[Self.forum.host]?.device == "here")
    }

    @Test("Lists, a relabel and what a source said stamp nothing")
    func listsDoNotStamp() async {
        let store = ItemStore(sources: [Self.one], notes: [])
        await store.stamp(with: Self.clock())
        await store.subscribe(host: Self.one.host, toLists: [ListSubscription(id: "7", name: "Seven")])
        await store.relabel(host: Self.one.host, lists: ["7": "Renamed"])
        await store.said(
            SourceProfile(
                host: Self.one.host, kind: .mastodon, title: "One", summary: nil, thumbnail: nil, activeMonth: nil,
                statusLimit: nil, people: nil, posts: nil, registration: nil, readsWithoutAccount: nil, rules: [],
                asOf: nil
            )
        )
        #expect(await store.sourceSync() == SourceSync())
    }

    @Test("A removal leaves a tombstone; adding it again takes the tombstone away")
    func removeTombstones() async {
        let store = ItemStore(sources: [Self.one], notes: [], sync: SourceSync(stamps: [Self.one.host: Self.stamp(5)]))
        await store.stamp(with: Self.clock())
        await store.remove(host: Self.one.host)
        var sync = await store.sourceSync()
        #expect(sync.stamps[Self.one.host] == nil)
        #expect(sync.gone[Self.one.host]?.device == "here")
        await store.remove(host: "never.example")
        #expect(await store.sourceSync().gone["never.example"] == nil, "a host never here leaves no tombstone")
        await store.add(Self.one)
        sync = await store.sourceSync()
        #expect(sync.gone.isEmpty)
        #expect(sync.stamps[Self.one.host]?.device == "here")
    }

    @Test("A merged removal or addition keeps the stamp it arrived at")
    func stampedAs() async {
        let store = ItemStore(sources: [Self.one], notes: [])
        await store.stamp(with: Self.clock())
        await store.remove(host: Self.one.host, stampedAs: Self.stamp(42))
        #expect(await store.sourceSync().gone[Self.one.host] == Self.stamp(42))
        await store.add(Self.forum, stampedAs: Self.stamp(43))
        #expect(await store.sourceSync().stamps[Self.forum.host] == Self.stamp(43))
    }

    @Test("The clock is told every stamp held: a change made here is later than each")
    func clockWitnesses() async {
        let store = ItemStore(sources: [Self.one], notes: [], sync: SourceSync(gone: ["two.example": Self.stamp(9_000)]))
        await store.stamp(with: Self.clock(ms: 1_000))
        await store.add(Self.forum)
        let made = await store.sourceSync().stamps[Self.forum.host]
        #expect(made.map { $0 > Self.stamp(9_000) } == true)
    }

    @Test("A store keeps only stamps of its sources and tombstones of hosts not here")
    func heldAsRead() async {
        let store = ItemStore(
            sources: [Self.one], notes: [],
            sync: SourceSync(
                stamps: [Self.one.host: Self.stamp(3), "gone.example": Self.stamp(4)],
                gone: [Self.one.host: Self.stamp(2), "old.example": Self.stamp(1)]
            )
        )
        #expect(await store.sourceSync() == SourceSync(stamps: [Self.one.host: Self.stamp(3)], gone: ["old.example": Self.stamp(1)]))
    }

    @Test("A save takes the stamps where any moved, and not again until one does")
    func takeChanges() async {
        let store = ItemStore(sources: [Self.one], notes: [], readFromDisk: true)
        await store.stamp(with: Self.clock())
        #expect(await store.takeChanges().changes.sourceSync == nil)
        await store.remove(host: Self.one.host)
        let taken = await store.takeChanges().changes
        #expect(taken.sourceSync?.gone[Self.one.host] != nil)
        #expect(await store.takeChanges().changes.sourceSync == nil)
        await store.putBack(taken)
        #expect(await store.takeChanges().changes.sourceSync?.gone[Self.one.host] != nil)
    }

    @Test("A merge lays in what wins, keeps lists, hands a removal back, and stamps nothing")
    func settle() async {
        let listed = Source(host: Self.one.host, kind: .mastodon, lists: [ListSubscription(id: "1", name: "L")])
        let store = ItemStore(
            sources: [listed, Self.forum], notes: [],
            sync: SourceSync(stamps: [Self.one.host: Self.stamp(10, "here"), Self.forum.host: Self.stamp(10, "here")])
        )
        await store.stamp(with: Self.clock())
        let boards = [BoardSubscription(fid: 9, name: "Nine")]
        let settled = await store.settle(arrived: [
            // Newer: restated, its lists kept.
            Self.one.host: Stamped(SyncSource(host: Self.one.host, kind: .mastodon, boards: boards), at: Self.stamp(20)),
            // Older than what is here: left as it is.
            Self.forum.host: Stamped(nil, at: Self.stamp(5)),
            "new.example": Stamped(SyncSource(host: "new.example", kind: .misskey, boards: []), at: Self.stamp(30)),
            "elsewhere.example": Stamped(nil, at: Self.stamp(31)),
        ])
        #expect(settled.added == ["new.example"])
        #expect(settled.restated == [Self.one.host])
        #expect(settled.toRemove.isEmpty)
        let sources = await store.sources()
        #expect(sources.first { $0.host == Self.one.host } == Source(host: Self.one.host, kind: .mastodon, boards: boards, lists: listed.lists))
        #expect(sources.contains(Self.forum))
        #expect(sources.last == Source(host: "new.example", kind: .misskey))
        let sync = await store.sourceSync()
        #expect(sync.stamps[Self.one.host] == Self.stamp(20))
        #expect(sync.stamps["new.example"] == Self.stamp(30))
        #expect(sync.gone == ["elsewhere.example": Self.stamp(31)])

        let removal = await store.settle(arrived: [Self.forum.host: Stamped(nil, at: Self.stamp(40))])
        #expect(removal.toRemove == [Self.forum.host: Self.stamp(40)])
        #expect(await store.sources().contains(Self.forum), "a removal goes by the person's own path")
    }

    @Test("A read back's stamps and tombstones replace the store's whole")
    func replaceCarries() async {
        let store = ItemStore(sources: [Self.one], notes: [], sync: SourceSync(gone: ["mine.example": Self.stamp(99, "here")]))
        let arriving = SourceSync(stamps: [Self.forum.host: Self.stamp(7)], gone: ["theirs.example": Self.stamp(8)])
        await store.replace(sources: [Self.forum], notes: [], sync: arriving)
        #expect(await store.sourceSync() == arriving)
        #expect(await store.snapshot().sync == arriving)
    }

    @Test("A stamp read from disk is held within what the clock carries on from")
    func bounded() {
        let wild = SyncStamp.bounded(ms: .max, counter: -3, device: "x")
        #expect(wild.ms == SyncStamp.latestMs)
        #expect(wild.counter == 0)
        #expect(SyncStamp.bounded(ms: -1, counter: Int64(UInt32.max) + 5, device: "x") == SyncStamp(ms: 0, counter: .max, device: "x"))
        let clock = SyncClock(device: "x")
        clock.witness(SyncStamp(ms: SyncStamp.latestMs, counter: .max, device: "x"))
        #expect(clock.now() > SyncStamp(ms: SyncStamp.latestMs, counter: .max, device: "x"))
    }
}
