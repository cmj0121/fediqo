import Foundation
import Synchronization
import Testing
@testable import FediqoCore

/// Merging two devices' sources and written timelines (D2, D3, D4, D8).
@Suite("SyncMerge")
struct SyncMergeTests {
    // MARK: the laws, over many random snapshots

    @Test("Merge is commutative, associative and idempotent, tombstones and zero ties included")
    func laws() {
        var rng = SplitMix(seed: 0x5EED)
        for _ in 0..<400 {
            let a = Self.randomSnapshot(&rng)
            let b = Self.randomSnapshot(&rng)
            let c = Self.randomSnapshot(&rng)
            #expect(SyncMerge.merge(a, b) == SyncMerge.merge(b, a))
            #expect(SyncMerge.merge(SyncMerge.merge(a, b), c) == SyncMerge.merge(a, SyncMerge.merge(b, c)))
            #expect(SyncMerge.merge(a, a) == a)
            #expect(SyncMerge.merge(SyncMerge.merge(a, b), b) == SyncMerge.merge(a, b))
            #expect(SyncMerge.merge(a, .empty) == a)
        }
    }

    @Test("Both sides' plans agree: each applies its changes and ends at the same merged snapshot")
    func plansAgree() {
        var rng = SplitMix(seed: 0xD1CE)
        for _ in 0..<300 {
            let local = Self.randomSnapshot(&rng)
            let remote = Self.randomSnapshot(&rng)
            let here = SyncMerge.plan(local: local, remote: remote)
            let there = SyncMerge.plan(local: remote, remote: local)
            #expect(here.merged == there.merged)
            #expect(here.here == there.there)
            #expect(here.there == there.here)
            #expect(Self.apply(here.here, to: local) == here.merged)
            #expect(Self.apply(here.there, to: remote) == here.merged)
            #expect(SyncMerge.plan(local: here.merged, remote: remote).here.isEmpty)
        }
    }

    // MARK: who wins

    @Test("The greater stamp wins, whatever the value or whether it is a tombstone")
    func greaterStampWins() {
        let older = Stamped(Self.source("a.example", .mastodon), at: Self.stamp(10, "B"))
        let newerGone = Stamped<SyncSource>(nil, at: Self.stamp(11, "A"))
        #expect(SyncMerge.wins(newerGone, over: older))
        #expect(!SyncMerge.wins(older, over: newerGone))
    }

    @Test("At an equal ms and counter, the greater device id wins")
    func deviceBreaksTies() {
        let fromA = Stamped(Self.source("a.example", .mastodon), at: Self.stamp(10, "A"))
        let fromB = Stamped(Self.source("a.example", .lemmy), at: Self.stamp(10, "B"))
        #expect(SyncMerge.wins(fromB, over: fromA))
        let merged = SyncMerge.merge(Self.snapshot(sources: [fromA]), Self.snapshot(sources: [fromB]))
        #expect(merged.sources["a.example"] == fromB)
    }

    @Test("At zero, a live value beats a tombstone and then the greater canonical bytes win")
    func zeroSettlesByContent() {
        let live = Stamped(Self.source("a.example", .mastodon), at: .zero)
        let gone = Stamped<SyncSource>(nil, at: .zero)
        #expect(SyncMerge.wins(live, over: gone))
        #expect(!SyncMerge.wins(gone, over: live))
        #expect(!SyncMerge.wins(gone, over: gone))
        #expect(!SyncMerge.wins(live, over: live))

        let lemmy = Stamped(Self.source("a.example", .lemmy), at: .zero)
        #expect(SyncMerge.wins(live, over: lemmy) != SyncMerge.wins(lemmy, over: live))
        // {"boards":[],"host":"a.example","kind":"mastodon"} > …"lemmy"
        #expect(SyncMerge.wins(live, over: lemmy))
    }

    @Test("A tombstone is never dropped by a merge: an older live record does not bring the host back")
    func tombstonesStay() {
        let gone = Stamped<SyncSource>(nil, at: Self.stamp(20, "A"))
        let stale = Stamped(Self.source("a.example", .mastodon), at: Self.stamp(5, "B"))
        let merged = SyncMerge.merge(Self.snapshot(sources: [stale]), Self.snapshot(gone: ["a.example": gone]))
        #expect(merged.sources["a.example"] == gone)
        let again = SyncMerge.merge(merged, Self.snapshot(sources: [stale]))
        #expect(again.sources["a.example"]?.isGone == true)
    }

    // MARK: what changes on each side

    @Test("Plan says what each side applies and how a person is told it")
    func planSaysEachSide() {
        let t1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let t2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let t3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let local = SyncSnapshot(
            sources: [
                "keep.example": Stamped(Self.source("keep.example", .mastodon), at: Self.stamp(1, "L")),
                "edit.example": Stamped(Self.source("edit.example", .discuz), at: Self.stamp(1, "L")),
                "drop.example": Stamped(Self.source("drop.example", .lemmy), at: Self.stamp(1, "L")),
            ],
            timelines: [
                t1: Stamped(Self.timeline(t1, "Reading", "a"), at: Self.stamp(5, "L")),
                t3: Stamped(nil, at: Self.stamp(9, "L")),
            ])
        let remote = SyncSnapshot(
            sources: [
                "edit.example": Stamped(
                    Self.source("edit.example", .discuz, boards: [BoardSubscription(fid: 2, name: "Two")]),
                    at: Self.stamp(3, "R")),
                "drop.example": Stamped(nil, at: Self.stamp(2, "R")),
                "new.example": Stamped(Self.source("new.example", .misskey), at: Self.stamp(2, "R")),
            ],
            timelines: [
                t1: Stamped(Self.timeline(t1, "Reading", "a"), at: Self.stamp(2, "R")),
                t2: Stamped(Self.timeline(t2, "Art", "b"), at: Self.stamp(2, "R")),
                t3: Stamped(Self.timeline(t3, "Old", "c"), at: Self.stamp(4, "R")),
            ])

        let plan = SyncMerge.plan(local: local, remote: remote)
        #expect(plan.here.summary == SyncSummary(
            addedSources: ["new.example"], replacedSources: ["edit.example"], removedSources: ["drop.example"],
            addedTimelines: ["Art"]))
        #expect(plan.here.sources.keys.sorted() == ["drop.example", "edit.example", "new.example"])
        #expect(Set(plan.here.timelines.keys) == [t2])
        #expect(plan.there.summary == SyncSummary(
            addedSources: ["keep.example"], removedTimelines: ["Old"]))
        #expect(Set(plan.there.timelines.keys) == [t1, t3])
        #expect(plan.preview == SyncPreview(here: plan.here.summary, there: plan.there.summary))
        #expect(!plan.preview.isEmpty)
    }

    @Test("A stamp that moves under an equal value, or a tombstone that moves, changes the record but says nothing")
    func silentChanges() {
        let local = SyncSnapshot(sources: [
            "a.example": Stamped(Self.source("a.example", .mastodon), at: .zero),
            "b.example": Stamped(nil, at: Self.stamp(1, "L")),
        ])
        let remote = SyncSnapshot(sources: [
            "a.example": Stamped(Self.source("a.example", .mastodon), at: Self.stamp(4, "R")),
            "b.example": Stamped(nil, at: Self.stamp(3, "R")),
            "c.example": Stamped(nil, at: Self.stamp(3, "R")),
        ])
        let plan = SyncMerge.plan(local: local, remote: remote)
        #expect(plan.here.sources.keys.sorted() == ["a.example", "b.example", "c.example"])
        #expect(plan.here.summary.isEmpty)
        #expect(plan.there.isEmpty)
        #expect(plan.preview.isEmpty)
    }

    @Test("The first merge of two migrated stores previews the content tie, not a silent pick")
    func firstMergePreview() {
        let local = SyncSnapshot(sources: ["a.example": Stamped(Self.source("a.example", .mastodon), at: .zero)])
        let remote = SyncSnapshot(sources: ["a.example": Stamped(Self.source("a.example", .lemmy), at: .zero)])
        let preview = SyncMerge.plan(local: local, remote: remote).preview
        #expect(preview.here.isEmpty)
        #expect(preview.there.replacedSources == ["a.example"])
        #expect(SyncMerge.plan(local: remote, remote: local).preview == SyncPreview(here: preview.there, there: preview.here))
    }

    @Test("Empty against empty changes nothing and asks nothing")
    func emptyPlan() {
        let plan = SyncMerge.plan(local: .empty, remote: .empty)
        #expect(plan.merged == .empty)
        #expect(plan.here.isEmpty && plan.there.isEmpty && plan.preview.isEmpty)
    }

    // MARK: a clock run ahead

    @Test("A snapshot with a stamp more than the allowance past now runs ahead")
    func runsAhead() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: Duration = .seconds(86_400)
        let edge = Int64(1_000_000 + 86_400) * 1000
        let at = SyncSnapshot(sources: ["a.example": Stamped(nil, at: Self.stamp(edge, "R"))])
        let past = SyncSnapshot(timelines: [UUID(): Stamped(nil, at: Self.stamp(edge + 1, "R"))])
        #expect(!SyncMerge.runsAhead(at, now: now, mostAhead: day))
        #expect(SyncMerge.runsAhead(past, now: now, mostAhead: day))
        #expect(!SyncMerge.runsAhead(.empty, now: now, mostAhead: day))
    }

    @Test("A session allows a peer's clock ten minutes ahead, no more")
    func tenMinutesAhead() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let edge = Int64(1_000_000 + 600) * 1000
        let allowance = SyncTiming.standard.mostAhead
        #expect(allowance == .seconds(600))
        #expect(!SyncMerge.runsAhead(SyncSnapshot(timelines: [UUID(): Stamped(nil, at: Self.stamp(edge, "R"))]), now: now, mostAhead: allowance))
        #expect(SyncMerge.runsAhead(SyncSnapshot(timelines: [UUID(): Stamped(nil, at: Self.stamp(edge + 1, "R"))]), now: now, mostAhead: allowance))
    }

    // MARK: helpers

    static func stamp(_ ms: Int64, _ device: String, _ counter: UInt32 = 0) -> SyncStamp {
        SyncStamp(ms: ms, counter: counter, device: device)
    }

    static func source(_ host: String, _ kind: ProtocolKind, boards: [BoardSubscription] = []) -> SyncSource {
        SyncSource(host: host, kind: kind, boards: boards)
    }

    static func timeline(_ id: UUID, _ name: String, _ body: String) -> SyncTimeline {
        SyncTimeline(id: id, name: name, body: Data(body.utf8))
    }

    static func snapshot(
        sources: [Stamped<SyncSource>] = [], gone: [String: Stamped<SyncSource>] = [:]
    ) -> SyncSnapshot {
        var entries = gone
        for entry in sources { entries[entry.value!.host] = entry }
        return SyncSnapshot(sources: entries)
    }

    static func apply(_ changes: SyncChanges, to side: SyncSnapshot) -> SyncSnapshot {
        var side = side
        side.sources.merge(changes.sources) { $1 }
        side.timelines.merge(changes.timelines) { $1 }
        return side
    }

    private static let hosts = ["a.example", "b.example", "c.example", "d.example"]
    private static let kinds: [ProtocolKind] = [.mastodon, .lemmy, .discuz]
    private static let ids = (1...4).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }

    /// Few hosts, ids, stamps and values, so keys collide and equal stamps (zero above all) are common.
    static func randomSnapshot(_ rng: inout SplitMix) -> SyncSnapshot {
        func stamp(_ rng: inout SplitMix) -> SyncStamp {
            rng.next(4) == 0
                ? .zero
                : SyncStamp(ms: Int64(rng.next(3)), counter: UInt32(rng.next(2)), device: ["A", "B"][rng.next(2)])
        }
        var snapshot = SyncSnapshot()
        for host in hosts where rng.next(3) != 0 {
            let value: SyncSource? = rng.next(3) == 0
                ? nil
                : SyncSource(
                    host: host, kind: kinds[rng.next(kinds.count)],
                    boards: rng.next(2) == 0 ? [] : [BoardSubscription(fid: rng.next(2), name: "b")])
            snapshot.sources[host] = Stamped(value, at: stamp(&rng))
        }
        for id in ids where rng.next(3) != 0 {
            let value: SyncTimeline? = rng.next(3) == 0
                ? nil
                : SyncTimeline(id: id, name: ["One", "Two"][rng.next(2)], body: Data([UInt8(rng.next(3))]))
            snapshot.timelines[id] = Stamped(value, at: stamp(&rng))
        }
        return snapshot
    }
}

/// A seeded generator, so a failing law names the same snapshots every run.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}

/// The clock every change is stamped by, and the records' wire shapes.
@Suite("SyncStamp")
struct SyncStampTests {
    @Test("Stamps order by ms, then counter, then device")
    func order() {
        #expect(SyncStamp(ms: 1, counter: 9, device: "Z") < SyncStamp(ms: 2, counter: 0, device: ""))
        #expect(SyncStamp(ms: 2, counter: 0, device: "Z") < SyncStamp(ms: 2, counter: 1, device: "A"))
        #expect(SyncStamp(ms: 2, counter: 1, device: "A") < SyncStamp(ms: 2, counter: 1, device: "B"))
        #expect(SyncStamp.zero == SyncStamp(ms: 0, counter: 0, device: ""))
    }

    @Test("A stamp is spelled ms, n, by")
    func spelling() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let stamp = SyncStamp(ms: 12, counter: 3, device: "dev")
        let json = String(decoding: try encoder.encode(stamp), as: UTF8.self)
        #expect(json == #"{"by":"dev","ms":12,"n":3}"#)
        #expect(try JSONDecoder().decode(SyncStamp.self, from: Data(json.utf8)) == stamp)
    }

    @Test("now() follows the wall, counts within one ms, and never goes back when the wall does")
    func clockNow() {
        let wall = Mutex(Date(timeIntervalSince1970: 10))
        let clock = SyncClock(device: "D", wall: { wall.withLock { $0 } })
        #expect(clock.now() == SyncStamp(ms: 10_000, counter: 0, device: "D"))
        #expect(clock.now() == SyncStamp(ms: 10_000, counter: 1, device: "D"))
        wall.withLock { $0 = Date(timeIntervalSince1970: 5) }
        #expect(clock.now() == SyncStamp(ms: 10_000, counter: 2, device: "D"))
        wall.withLock { $0 = Date(timeIntervalSince1970: 11) }
        #expect(clock.now() == SyncStamp(ms: 11_000, counter: 0, device: "D"))
    }

    @Test("After witnessing a stamp, now() is greater than it, whichever device wrote it")
    func clockWitness() {
        let clock = SyncClock(device: "A", wall: { Date(timeIntervalSince1970: 1) })
        let arrived = SyncStamp(ms: 50_000, counter: 7, device: "Z")
        clock.witness(arrived)
        let next = clock.now()
        #expect(next > arrived)
        #expect(next == SyncStamp(ms: 50_000, counter: 8, device: "A"))
        clock.witness(SyncStamp(ms: 1, counter: 0, device: "Z"))
        #expect(clock.now() > next)
    }

    @Test("A clock that witnessed the greatest stamp saturates instead of trapping")
    func clockSaturates() {
        let clock = SyncClock(device: "A", wall: { Date(timeIntervalSince1970: 1) })
        clock.witness(SyncStamp(ms: .max, counter: .max - 1, device: "Z"))
        #expect(clock.now() == SyncStamp(ms: .max, counter: .max, device: "A"))
        #expect(clock.now() == SyncStamp(ms: .max, counter: .max, device: "A"))
    }

    @Test("A clock on a wall at zero still stamps above zero")
    func clockAtZero() {
        let clock = SyncClock(device: "", wall: { Date(timeIntervalSince1970: 0) })
        #expect(clock.now() > .zero)
        #expect(SyncClock.unpaired.device == "")
    }

    @Test("A snapshot round-trips as sorted entries, a tombstone without a value, and its source without lists")
    func snapshotShape() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let source = Source(
            host: "Forum.Example", kind: .discuz, boards: [BoardSubscription(fid: 3, name: "Three")],
            lists: [ListSubscription(id: "9", name: "L")])
        let snapshot = SyncSnapshot(
            sources: [
                "forum.example": Stamped(SyncSource(source), at: SyncStamp(ms: 1, counter: 0, device: "A")),
                "b.example": Stamped(nil, at: SyncStamp(ms: 2, counter: 0, device: "A")),
            ],
            timelines: [id: Stamped(SyncTimeline(id: id, name: "N", body: Data("{}".utf8)), at: .zero)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
        #expect(json == #"{"sources":[{"host":"b.example","stamp":{"by":"A","ms":2,"n":0}},"#
            + #"{"host":"forum.example","stamp":{"by":"A","ms":1,"n":0},"#
            + #""value":{"boards":[{"fid":3,"name":"Three"}],"host":"forum.example","kind":"discuz"}}],"#
            + #""timelines":[{"id":"00000000-0000-0000-0000-000000000001","stamp":{"by":"","ms":0,"n":0},"#
            + #""value":{"body":"e30=","id":"00000000-0000-0000-0000-000000000001","name":"N"}}]}"#)
        #expect(try JSONDecoder().decode(SyncSnapshot.self, from: Data(json.utf8)) == snapshot)
        #expect(snapshot.newest == SyncStamp(ms: 2, counter: 0, device: "A"))
        #expect(SyncSnapshot.empty.newest == .zero)
    }

    @Test("A kind this build cannot name refuses as peer-newer, never reads as unknown")
    func unknownKindRefuses() {
        let json = #"{"host":"a.example","kind":"bluesky","boards":[]}"#
        #expect(throws: SyncRefusal.peerNewer) {
            try JSONDecoder().decode(SyncSource.self, from: Data(json.utf8))
        }
    }

    @Test("A repeated or misnamed entry is malformed")
    func malformedEntries() {
        let repeated = #"{"sources":[{"host":"a","stamp":{"by":"","ms":0,"n":0}},"#
            + #"{"host":"a","stamp":{"by":"","ms":1,"n":0}}],"timelines":[]}"#
        let misnamed = #"{"sources":[{"host":"a","stamp":{"by":"","ms":0,"n":0},"#
            + #""value":{"host":"b","kind":"mastodon","boards":[]}}],"timelines":[]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SyncSnapshot.self, from: Data(repeated.utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SyncSnapshot.self, from: Data(misnamed.utf8)) }
    }

    @Test("A source host empty or not lowercase is malformed, live or tombstone")
    func nonCanonicalHosts() {
        for host in ["", "A.example"] {
            let gone = #"{"sources":[{"host":""# + host + #"","stamp":{"by":"","ms":0,"n":0}}],"timelines":[]}"#
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(SyncSnapshot.self, from: Data(gone.utf8)) }
        }
        let live = #"{"host":"A.example","kind":"mastodon","boards":[]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SyncSource.self, from: Data(live.utf8)) }
    }

    @Test("A source host not as adding a source keeps it is malformed, live or tombstone")
    func hostsNotAsKept() {
        for host in [" a.example", "https://a.example", "a.example/p", "a.example?q", "a.example#f", "u@a.example", "a.example:8443", "::", "[::1]:443"] {
            let gone = #"{"sources":[{"host":"\#(host)","stamp":{"by":"","ms":0,"n":0}}],"timelines":[]}"#
            #expect(throws: DecodingError.self, "\(host)") { try JSONDecoder().decode(SyncSnapshot.self, from: Data(gone.utf8)) }
            let live = #"{"host":"\#(host)","kind":"mastodon","boards":[]}"#
            #expect(throws: DecodingError.self, "\(host)") { try JSONDecoder().decode(SyncSource.self, from: Data(live.utf8)) }
        }
    }

    @Test("A source on this device or its link is read past and left out, live or tombstone; the rest still merges")
    func localHostsSkipped() throws {
        let local = [
            "localhost", "localhost.", "x.localhost.", "mastodon.localhost", "127.0.0.1", "127.0.0.1.", "127.1", "2130706433",
            "0", "0.0.0.0", "169.254.169.254", "[::]", "[::1]", "[fe80::1]", "[febf::1]", "[::ffff:127.0.0.1]",
            "[::ffff:169.254.1.1]", "[localhost:8443]", "[127.0.0.1:8443]",
        ]
        let kept = ["a.example", "a", "10.0.0.2", "8.8.8.8", "[2001:db8::1]", "[fec0::1]", "[a.example:8443]", "b.example."]
        for host in local + kept { #expect((try? Host.parse(host)) == host, "\(host)") }
        for host in local {
            #expect(host.isLocalHost, "\(host)")
            let json = #"{"sources":[{"host":"\#(host)","stamp":{"by":"","ms":0,"n":0}},"#
                + #"{"host":"a.example","stamp":{"by":"","ms":1,"n":0},"value":{"host":"a.example","kind":"mastodon","boards":[]}}],"timelines":[]}"#
            let gone = try JSONDecoder().decode(SyncSnapshot.self, from: Data(json.utf8))
            #expect(Set(gone.sources.keys) == ["a.example"], "\(host)")
            let live = #"{"sources":[{"host":"\#(host)","stamp":{"by":"","ms":0,"n":0},"value":{"host":"\#(host)","kind":"mastodon","boards":[]}}],"timelines":[]}"#
            #expect(try JSONDecoder().decode(SyncSnapshot.self, from: Data(live.utf8)).sources.isEmpty, "\(host)")
        }
        for host in kept {
            #expect(!host.isLocalHost, "\(host)")
            let live = #"{"host":"\#(host)","kind":"mastodon","boards":[]}"#
            #expect(try JSONDecoder().decode(SyncSource.self, from: Data(live.utf8)).host == host)
        }
        let mixed = SyncSnapshot(sources: [
            "localhost": Stamped(nil, at: SyncMergeTests.stamp(1, "A")),
            "127.0.0.1": Stamped(SyncMergeTests.source("127.0.0.1", .mastodon), at: SyncMergeTests.stamp(2, "A")),
            "[a.example:8443]": Stamped(SyncMergeTests.source("[a.example:8443]", .mastodon), at: SyncMergeTests.stamp(3, "A")),
        ])
        #expect(Set(mixed.shared.sources.keys) == ["[a.example:8443]"])
    }

    @Test("A source repeating a board's fid is malformed, not quietly folded")
    func repeatedBoards() {
        let json = #"{"host":"f.example","kind":"discuz","boards":[{"fid":1,"name":"a"},{"fid":1,"name":"b"}]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(SyncSource.self, from: Data(json.utf8)) }
    }

    @Test("A store's stamps and tombstones become merge entries; a source with no stamp is zero")
    func sourceSyncEntries() {
        let sync = SourceSync(
            stamps: ["a.example": SyncStamp(ms: 4, counter: 0, device: "A")],
            gone: ["c.example": SyncStamp(ms: 6, counter: 0, device: "A")])
        let entries = sync.entries([
            Source(host: "a.example", kind: .mastodon, lists: [ListSubscription(id: "1", name: "x")]),
            Source(host: "b.example", kind: .lemmy),
        ])
        #expect(entries == [
            "a.example": Stamped(SyncSource(host: "a.example", kind: .mastodon, boards: []), at: SyncStamp(ms: 4, counter: 0, device: "A")),
            "b.example": Stamped(SyncSource(host: "b.example", kind: .lemmy, boards: []), at: .zero),
            "c.example": Stamped(nil, at: SyncStamp(ms: 6, counter: 0, device: "A")),
        ])
        #expect(sync.newest == SyncStamp(ms: 6, counter: 0, device: "A"))
        #expect(SourceSync().newest == .zero)
    }
}
