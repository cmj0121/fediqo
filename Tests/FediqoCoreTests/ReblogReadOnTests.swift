import Foundation
import Testing
@testable import FediqoCore

/// #290 over #201 and #204: a reblog is the item its timeline listed, under its own id and its own
/// key, so a stretch that mixes posts and reblogs is read on, marked and read down exactly as the
/// same stretch of posts alone is — nothing about a reblog is a special case of the bookkeeping.
///
/// Each scenario is run twice over the same ids — once with every entry a post, once with some
/// of them reblogs — and what the two runs asked, where each left its marks and where each
/// stands are compared by the ids the timeline listed.
@Suite("A stretch of posts and reblogs reads on and down as a stretch of posts does")
struct ReblogReadOnTests {
    private static let host = MastodonFixture.host
    private static let source = Source(host: host, kind: .mastodon)

    /// What one run left behind, by the ids the timeline listed things under.
    struct Trace: Equatable {
        var cursors: [String] = []
        var anchors: [String?] = []
        /// What each read said, as listed ids: `missingBelow`, `newerRemainAbove`.
        var said: [[String?]] = []
        var ends: [ReadDown.End] = []
        /// Every listed id held, with the marks on the item listed under it.
        var marks: [String: Set<TimelineGap.Kind>] = [:]
    }

    private static func listedID(_ key: NoteKey?, in store: ItemStore) async -> String? {
        guard let key else { return nil }
        return await store.note(key)?.listed[.public]
    }

    private static func item(_ id: Int, in store: ItemStore) async -> Note? {
        await store.all().first { $0.listed[.public] == "\(id)" }
    }

    private static func readOn(_ store: ItemStore, _ server: TimelineServer, into trace: inout Trace) async throws {
        let anchor = await store.newestListedID(host: host, category: .public)
        let held = anchor == nil ? await store.held(host: host, category: .public) : []
        let read = try await MastodonClient(http: server, host: host)
            .publicTimeline(source: source, readingOnFrom: anchor, holding: held)
        await store.land(read, of: .public, ifSourceHere: host)
        trace.said.append([
            await listedID(read.missingBelow, in: store), await listedID(read.newerRemainAbove, in: store),
        ])
        trace.anchors.append(await store.newestListedID(host: host, category: .public))
    }

    private static func readDown(_ store: ItemStore, _ server: TimelineServer, at id: Int, into trace: inout Trace) async throws {
        let key = try #require(await item(id, in: store)?.key)
        let place = try #require(await store.missing(below: key, in: .public))
        let down = try await MastodonClient(http: server, host: host).publicTimeline(source: source, readingDownFrom: place)
        await store.land(down, below: key, of: .public, ifSourceHere: host)
        trace.ends.append(down.end)
    }

    private static func finish(_ trace: inout Trace, _ store: ItemStore, _ server: TimelineServer) async {
        trace.cursors = await server.cursors
        for note in await store.all() {
            guard let listed = note.listed[.public] else { continue }
            trace.marks[listed] = Set(note.gaps.filter { $0.category == .public }.map(\.kind))
        }
    }

    /// Sixty entries read; three hundred and forty more arrive while everything below 100 is let
    /// go by the source; read on twice; then the source has 60…99 again and the hole is read down.
    private func acrossAGap(boosts: [Int: Int]) async throws -> (Trace, ItemStore) {
        let server = TimelineServer(host: Self.host, 1...60)
        for (id, inner) in boosts { await server.boost(id, of: inner) }
        let store = ItemStore()
        await store.add(Self.source)
        var trace = Trace()
        try await Self.readOn(store, server, into: &trace)
        await server.post(61...400)
        await server.keep(from: 100)
        try await Self.readOn(store, server, into: &trace)
        try await Self.readOn(store, server, into: &trace)
        await server.post(60...99)
        try await Self.readDown(store, server, at: 100, into: &trace)
        await Self.finish(&trace, store, server)
        return (trace, store)
    }

    /// The reblogs of the mixed run: the anchor, the item the hole sits below, the item newer
    /// posts remained above, the newest of all, and some in the middle of each stretch — of posts
    /// held, of one never listed, and of one inside the hole.
    private static let boosts = [30: 3, 60: 45, 75: 74, 100: 5, 101: 100, 180: 30, 259: 250, 299: 298, 300: 120, 400: 399]

    @Test("Across a gap and a read down, a stretch with reblogs in it asks the same asks, leaves the same marks under the same listed ids, and moves its anchor the same way as one of posts alone")
    func theSameBookkeeping() async throws {
        let (plain, _) = try await acrossAGap(boosts: [:])
        let (mixed, _) = try await acrossAGap(boosts: Self.boosts)
        #expect(mixed.cursors == plain.cursors)
        #expect(mixed.anchors == plain.anchors)
        #expect(mixed.said == plain.said)
        #expect(mixed.ends == plain.ends)
        #expect(mixed.marks == plain.marks)
        // And what the plain run is, so the comparison is not of two empty things.
        #expect(plain.cursors == ["newest", "min_id=59", "max_id=100", "min_id=139", "min_id=179", "min_id=219", "min_id=259", "min_id=298", "min_id=338", "min_id=378", "max_id=100"])
        #expect(plain.anchors == ["60", "299", "400"])
        #expect(plain.said == [[nil, nil], ["100", "299"], [nil, nil]])
        #expect(plain.ends == [.met])
        #expect(plain.marks.values.allSatisfy { $0.isEmpty }, "the hole was filled and nothing newer remains")
        #expect(Set(plain.marks.keys) == Set(((21...400).map(String.init))))
    }

    @Test("Every row that is not a reblog is held exactly as it is with no reblog in the stretch: its listing, its marks, what it came through")
    func everyOtherRowIsAsItWas() async throws {
        let (_, plain) = try await acrossAGap(boosts: [:])
        let (_, mixed) = try await acrossAGap(boosts: Self.boosts)
        for note in await plain.all() where Self.boosts[Int(note.statusID!)!] == nil {
            let other = try #require(await mixed.note(note.key), "post \(note.statusID!) is not held in the mixed run")
            #expect(other.listed == note.listed && other.gaps == note.gaps && other.categories == note.categories)
            #expect(other.postedAt == note.postedAt && !other.isReblog)
        }
    }

    @Test("In the mixed run each reblog is its own row under the id it was listed under, and the post it reblogs is held beside it — through the timeline only where the timeline also listed the post itself")
    func whatTheMixedRunHolds() async throws {
        let (_, store) = try await acrossAGap(boosts: Self.boosts)
        for (id, inner) in Self.boosts {
            let reblog = try #require(await Self.item(id, in: store), "nothing is listed under \(id)")
            #expect(reblog.isReblog && reblog.statusID == "\(id)" && reblog.categories == [.public])
            let target = try #require(reblog.reblogKey)
            let post = try #require(await store.note(target))
            #expect(post.statusID == "\(inner)" && !post.isReblog)
            // 3 and 5 were never listed themselves by anything this run read, and the entries
            // 30 and 100 are reblogs: the posts of those ids came only inside a reblog.
            let listedItself = inner >= 21 && Self.boosts[inner] == nil
            #expect(post.listed == (listedItself ? [.public: "\(inner)"] : [:]))
            #expect(post.categories == (listedItself ? [.public] : []))
        }
    }

    @Test("While the hole stands, it stands below the reblog that was the oldest item read, and newer posts remain above the reblog that was the newest")
    func theMarksSitOnTheReblogs() async throws {
        let server = TimelineServer(host: Self.host, 1...60)
        for (id, inner) in Self.boosts { await server.boost(id, of: inner) }
        let store = ItemStore()
        await store.add(Self.source)
        var trace = Trace()
        try await Self.readOn(store, server, into: &trace)
        await server.post(61...400)
        await server.keep(from: 100)
        try await Self.readOn(store, server, into: &trace)
        let below = try #require(await Self.item(100, in: store))
        let above = try #require(await Self.item(299, in: store))
        #expect(below.isReblog && below.gaps == [TimelineGap(.mayBeMissing, in: .public)])
        #expect(above.isReblog && above.gaps == [TimelineGap(.newerRemain, in: .public)])
        // The posts they reblog carry none of it: a post is not where its reblog was listed.
        let belowTarget = try #require(below.reblogKey), aboveTarget = try #require(above.reblogKey)
        #expect(await store.note(belowTarget)?.gaps.isEmpty == true)
        #expect(await store.note(aboveTarget)?.gaps.isEmpty == true)
        let place = try #require(await store.missing(below: below.key, in: .public))
        #expect(place.listed == "100" && place.floor == "60")
        let listedBelow = Set(await store.all().filter { $0.listed[.public].map { Int($0)! <= 60 } == true }.map(\.key))
        #expect(place.held == listedBelow, "every item listed below, the reblogs among them as themselves")
    }

    @Test("A read down that stops short, or is told there is nothing more, leaves its place on the oldest item it read — a reblog where that is one")
    func aReadDownSettlesOnAReblog() async throws {
        for boosted in [false, true] {
            let server = TimelineServer(host: Self.host, 1...60)
            if boosted { await server.boost(70, of: 69) }
            let store = ItemStore()
            await store.add(Self.source)
            var trace = Trace()
            try await Self.readOn(store, server, into: &trace)
            await server.post(61...140)
            await server.keep(from: 100)
            try await Self.readOn(store, server, into: &trace)
            // The source has 70…99 again, and nothing below.
            await server.post(70...99)
            try await Self.readDown(store, server, at: 100, into: &trace)
            #expect(trace.ends == [.settled])
            let carrier = try #require(await Self.item(70, in: store))
            #expect(carrier.isReblog == boosted)
            #expect(carrier.gaps.map(\.kind) == [.settled], "on the oldest item read, whichever it is")
            #expect(await Self.item(100, in: store)?.gaps.isEmpty == true)
        }
    }

    @Test("A reblog in the hole, of a post held below it, does not fill the hole; a reblog held below, listed again where it stands, does")
    func whatFillsAHole() async throws {
        let server = TimelineServer(host: Self.host, 1...500)
        await server.boost(440, of: 5)
        await server.boost(8, of: 2)
        let store = ItemStore()
        await store.add(Self.source)
        // Held: 1…10 (8 a reblog) and 450…500, read as two stretches of the same timeline.
        let client = MastodonClient(http: server, host: Self.host)
        await store.ingest(try await client.publicTimeline(source: Self.source, olderThan: "11"), ifSourceHere: Self.host)
        await store.ingest(try await client.publicTimeline(source: Self.source, olderThan: "501"), ifSourceHere: Self.host)
        let marked = try #require(await Self.item(461, in: store))
        await store.land(ReadOn(missingBelow: marked.key), of: .public, ifSourceHere: Self.host)
        let place = try #require(await store.missing(below: marked.key, in: .public))
        #expect(place.floor == "10")
        let reblogBelow = try #require(await Self.item(8, in: store)?.key)
        #expect(place.held.contains(reblogBelow), "the reblog held below is one of what is held below")
        let fromHole = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(TimelineServer.boost(440, of: 5, host: Self.host).utf8))
            .listed(source: Self.source, category: .public, sent: .now())
        #expect(!place.meets(fromHole), "440 reblogs 5; it is not 5 listed where 5 stands")
        let heldBelow = try MastodonJSON.decoder.decode(StatusDTO.self, from: Data(TimelineServer.boost(8, of: 2, host: Self.host).utf8))
            .listed(source: Self.source, category: .public, sent: .now())
        #expect(place.meets(heldBelow))
    }
}
