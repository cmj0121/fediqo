import Foundation
@testable import FediqoCore
import Testing
@testable import FediqoUI

/// U3: timelines file v4 (D3, D4, D8) — every add, edit and removal stamps, a reorder does not;
/// v1–v3 read at `.zero` and v4 fails closed; a merge's entries lay in as they came; and every
/// save tells the other windows keeping timelines in the same place to read them again.
@Suite("Timeline stamps and tombstones")
@MainActor
struct WrittenTimelineStampTests {
    private let microblog = Source(host: "m.example", kind: .mastodon)

    private static func clock(ms: Int64 = 1_000) -> SyncClock {
        SyncClock(device: "here") { Date(timeIntervalSince1970: Double(ms) / 1000) }
    }

    private static func stamp(_ ms: Int64, _ device: String = "there") -> SyncStamp {
        SyncStamp(ms: ms, counter: 0, device: device)
    }

    private func held(_ store: WrittenTimelineStore) throws -> (timelines: [TimelineDefinition], stamps: WrittenTimelineStore.Stamps) {
        try #require(store.loadStamped())
    }

    private func kept(_ json: String, in store: WrittenTimelineStore) {
        store.defaults.set(Data(json.utf8), forKey: store.key)
    }

    private func top(_ store: WrittenTimelineStore) throws -> [String: Any] {
        let data = try #require(store.defaults.object(forKey: store.key) as? Data)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Adding, editing and removing stamp; an unchanged timeline and a reorder keep their stamps")
    func saveStamps() throws {
        let store = WrittenTimelineStore(defaults: StampDefaults())
        let clock = Self.clock()
        let a = TimelineDefinition(name: "A", rules: [])
        let b = TimelineDefinition(name: "B", rules: [])
        #expect(store.save([a, b], clock: clock))
        let first = try held(store).stamps
        #expect(first.timelines[a.id]?.device == "here")
        #expect(first.timelines[b.id].map { $0 > first.timelines[a.id]! } == true)

        #expect(store.save([b, a], clock: clock))
        #expect(try held(store).stamps == first, "a reorder changes no definition")

        let edited = TimelineDefinition(id: a.id, name: "A again", rules: [])
        #expect(store.save([b, edited], clock: clock))
        let second = try held(store).stamps
        #expect(second.timelines[b.id] == first.timelines[b.id])
        #expect(second.timelines[a.id].map { $0 > first.timelines[b.id]! } == true)

        #expect(store.save([edited], clock: clock))
        let third = try held(store).stamps
        #expect(third.timelines[b.id] == nil)
        #expect(third.gone[b.id].map { $0 > second.timelines[a.id]! } == true)

        #expect(store.save([edited, b], clock: clock))
        #expect(try held(store).stamps.gone.isEmpty, "back from a tombstone drops it")
        #expect(try top(store)["version"] as? Int == 4)
    }

    @Test("The clock is told every stamp the file holds before it stamps")
    func witnessesFile() throws {
        let store = WrittenTimelineStore(defaults: StampDefaults())
        let id = UUID()
        kept(#"{"version":4,"timelines":[],"gone":[{"id":"\#(id.uuidString)","stamp":{"ms":9000,"n":0,"by":"there"}}]}"#, in: store)
        let added = TimelineDefinition(name: "New", rules: [])
        #expect(store.save([added], clock: Self.clock(ms: 1_000)))
        #expect(try held(store).stamps.timelines[added.id].map { $0 > Self.stamp(9_000) } == true)
        #expect(try held(store).stamps.gone[id] == Self.stamp(9_000))
    }

    @Test("A version 1–3 file reads at .zero with nothing gone")
    func olderReadsZero() throws {
        let store = WrittenTimelineStore(defaults: StampDefaults())
        kept(#"{"version":3,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"Old","rules":[]}]}"#, in: store)
        let read = try held(store)
        #expect(read.timelines.map(\.name) == ["Old"])
        #expect(read.stamps == WrittenTimelineStore.Stamps(timelines: [:], gone: [:]))
        let entries = try #require(store.syncEntries())
        #expect(entries.values.map(\.stamp) == [.zero])
    }

    @Test("What is not exactly version 4's shape is unreadable, and never written over", arguments: [
        // A version before 4 holding a stamp or a tombstone.
        #"{"version":3,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[],"stamp":{"ms":1,"n":0,"by":"a"}}]}"#,
        #"{"version":3,"timelines":[],"gone":[]}"#,
        // Version 4 without a stamp on a timeline, or without `gone`.
        #"{"version":4,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[]}],"gone":[]}"#,
        #"{"version":4,"timelines":[]}"#,
        // A stamp with a field more or less, a tombstone with a field more.
        #"{"version":4,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[],"stamp":{"ms":1,"n":0}}],"gone":[]}"#,
        #"{"version":4,"timelines":[],"gone":[{"id":"11111111-1111-1111-1111-111111111111","stamp":{"ms":1,"n":0,"by":"a","x":1}}]}"#,
        #"{"version":4,"timelines":[],"gone":[{"id":"11111111-1111-1111-1111-111111111111","stamp":{"ms":1,"n":0,"by":"a"},"name":"X"}]}"#,
        // A stamp past what the clock can carry on from, or a counter out of its range.
        #"{"version":4,"timelines":[{"id":"11111111-1111-1111-1111-111111111111","name":"X","rules":[],"stamp":{"ms":9223372036854775807,"n":0,"by":"a"}}],"gone":[]}"#,
        #"{"version":4,"timelines":[],"gone":[{"id":"11111111-1111-1111-1111-111111111111","stamp":{"ms":1,"n":-1,"by":"a"}}]}"#,
        #"{"version":4,"timelines":[],"gone":[{"id":"11111111-1111-1111-1111-111111111111","stamp":{"ms":-5,"n":0,"by":"a"}}]}"#,
        // A version after this build's.
        #"{"version":5,"timelines":[],"gone":[]}"#,
    ])
    func failsClosed(json: String) throws {
        let store = WrittenTimelineStore(defaults: StampDefaults())
        kept(json, in: store)
        #expect(store.load() == .unreadable)
        #expect(store.syncEntries() == nil)
        #expect(!store.save([TimelineDefinition(name: "Over", rules: [])], clock: Self.clock()))
        #expect(store.settle(arrived: [:]) == nil)
        #expect(store.defaults.object(forKey: store.key) as? Data == Data(json.utf8))
    }

    @Test("A build that reads up to version 3 finds version 4 out of its range")
    func olderBuildRefuses() throws {
        let store = WrittenTimelineStore(defaults: StampDefaults())
        #expect(store.save([TimelineDefinition(name: "A", rules: [])], clock: Self.clock()))
        let version = try #require(try top(store)["version"] as? Int)
        #expect(!(1...3).contains(version))
    }

    @Test("A merge lays in what wins at the stamp it came with: a new one at the end, a replaced one in place, a removal gone")
    func settle() throws {
        let store = WrittenTimelineStore(defaults: StampDefaults())
        let a = TimelineDefinition(name: "A", rules: [])
        let b = TimelineDefinition(name: "B", rules: [])
        #expect(store.save([a, b], clock: Self.clock(ms: 1_000)))
        let renamed = TimelineDefinition(id: b.id, name: "B there", rules: [])
        let new = TimelineDefinition(name: "New", rules: [])
        let body = { (t: TimelineDefinition) in SyncTimeline(id: t.id, name: t.name, body: WrittenTimelineStore.body(of: t)) }
        let olderID = UUID()
        #expect(store.settle(arrived: [
            b.id: Stamped(body(renamed), at: Self.stamp(5_000)),
            new.id: Stamped(body(new), at: Self.stamp(5_001)),
            // Older than what is here: stands.
            a.id: Stamped(nil, at: Self.stamp(10)),
            olderID: Stamped(nil, at: Self.stamp(5_002)),
        ]) == true)
        let read = try held(store)
        #expect(read.timelines == [a, renamed, new])
        #expect(read.stamps.timelines[b.id] == Self.stamp(5_000))
        #expect(read.stamps.timelines[new.id] == Self.stamp(5_001))
        #expect(read.stamps.gone == [olderID: Self.stamp(5_002)])

        #expect(store.settle(arrived: [a.id: Stamped(nil, at: Self.stamp(6_000))]) == true)
        #expect(try held(store).timelines.map(\.id) == [b.id, new.id])
        #expect(try held(store).stamps.gone[a.id] == Self.stamp(6_000))
    }

    @Test("A merge whose body does not read writes nothing")
    func settleRefusesBody() throws {
        let store = WrittenTimelineStore(defaults: StampDefaults())
        #expect(store.save([TimelineDefinition(name: "A", rules: [])], clock: Self.clock()))
        let before = store.defaults.object(forKey: store.key) as? Data
        let id = UUID()
        let bad = SyncTimeline(id: id, name: "X", body: Data(#"{"id":"\#(id.uuidString)","name":"X","rules":[],"later":1}"#.utf8))
        #expect(store.settle(arrived: [id: Stamped(bad, at: Self.stamp(9_000))]) == nil)
        #expect(store.defaults.object(forKey: store.key) as? Data == before)
    }

    @Test("A body is the row without its stamp, and reads back as the same timeline")
    func bodyRoundTrip() {
        let timeline = TimelineDefinition(name: "Mine", rules: [Rule.source("m.example", effect: .include)!], desc: "kept")
        #expect(WrittenTimelineStore.definition(from: WrittenTimelineStore.body(of: timeline)) == timeline)
        #expect(!String(decoding: WrittenTimelineStore.body(of: timeline), as: UTF8.self).contains("stamp"))
    }

    @Test("A window's keep stamps by its clock, and the other windows over the same file read the timelines again")
    func keptElsewhere() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-kept-\(UUID().uuidString)", isDirectory: true)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-kept-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: other)
        }
        for dir in [folder, other] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let defaults = StampDefaults()
        let file = ListFiles(directory: folder, defaults: defaults, protected: .always).timelines
        let shared = WrittenTimelineStore(defaults: defaults, file: file)
        let first = ShellSession(http: FixtureHTTP([:]), timelines: shared)
        let second = ShellSession(http: FixtureHTTP([:]), timelines: WrittenTimelineStore(defaults: defaults, file: file))
        let elsewhere = ShellSession(
            http: FixtureHTTP([:]),
            timelines: WrittenTimelineStore(defaults: defaults, file: ListFiles(directory: other, defaults: defaults, protected: .always).timelines)
        )
        for session in [first, second, elsewhere] {
            session.sources = [microblog]
            session.rebuildQueries()
        }
        first.syncClock = SyncClock(device: "mine")
        var draft = TimelineDraft(new: 1)
        draft.name = "Shared"
        first.commit(draft)
        #expect(second.written.map(\.name) == ["Shared"])
        #expect(second.queries.contains(.written(draft.id)))
        #expect(elsewhere.written.isEmpty, "another place's window is not told")
        let stamps = try held(shared).stamps
        #expect(stamps.timelines[draft.id]?.device == "mine")

        // The window that kept them does not read them again: a trends rule it holds, which the
        // file lets go of when read, stays in its own timelines.
        var trending = TimelineDraft(new: 2)
        trending.name = "Trending"
        trending.rules = [try #require(Rule.category(.trends, in: .every, sources: []))]
        first.commit(trending)
        #expect(first.written.first { $0.id == trending.id }?.rules.count == 1, "the posting window read its own save again")
        #expect(second.written.first { $0.id == trending.id }?.rules.isEmpty == true)
        first.removeTimeline(trending.id)

        second.removeTimeline(draft.id)
        #expect(first.written.isEmpty)
        #expect(try held(shared).stamps.gone[draft.id] != nil)
    }
}

/// Preferences kept in memory, so no test reads or writes the reader's.
private final class StampDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
