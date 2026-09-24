import Foundation
import Testing
@testable import FediqoCore

/// Two limits on the store (#249), and what each says it let go (#251), at the store's own door.
@Suite("The store's two limits")
struct LimitTests {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let alpha = Source(host: "alpha.test", kind: .mastodon)
    private let beta = Source(host: "beta.test", kind: .mastodon)

    private func note(
        _ id: String, daysAgo: Double, from source: Source, holding: Holding = .arrived, quote: Quote? = nil
    ) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada", body: "hello",
            postedAt: origin.addingTimeInterval(-daysAgo * 86_400), categories: [.public],
            holding: holding, quote: quote
        )
    }

    @Test("The oldest posts go first, across every source, rows held aside included")
    func oldestGoFirstAcrossSources() async {
        let store = ItemStore(sources: [alpha, beta], notes: [
            note("new-a", daysAgo: 1, from: alpha),
            note("old-b", daysAgo: 30, from: beta),
            note("aside-a", daysAgo: 40, from: alpha, holding: .aside),
            note("mid-b", daysAgo: 10, from: beta),
        ])

        let went = await store.letGoOldest(count: 2)

        #expect(went == WentByLimit(posts: 2, sources: ["alpha.test", "beta.test"]))
        let left = await store.snapshot().notes.map(\.id).sorted()
        #expect(left == ["mid-b", "new-a"], "the aside row and the oldest timeline row went")
        #expect(await store.aside().isEmpty)
    }

    @Test("Two posted in the same second go in the order they arrived")
    func sameSecondByArrival() async {
        let store = ItemStore(sources: [alpha], notes: [
            note("first", daysAgo: 5, from: alpha), note("second", daysAgo: 5, from: alpha),
        ])
        #expect(await store.letGoOldest(count: 1).posts == 1)
        #expect(await store.snapshot().notes.map(\.id) == ["second"])
    }

    @Test("A post another held post quotes stays whatever its age, and goes once the quoting post has")
    func quotedStays() async {
        let quoted = QuotedPost(id: "quoted", author: "Bob", handle: "@bob", body: "old", postedAt: origin.addingTimeInterval(-99 * 86_400))
        let store = ItemStore(sources: [alpha], notes: [
            note("quoted", daysAgo: 99, from: alpha, holding: .aside),
            note("quoting", daysAgo: 2, from: alpha, quote: Quote(state: .accepted, post: quoted)),
            note("plain", daysAgo: 50, from: alpha),
        ])

        #expect(await store.letGoOldest(count: 1).posts == 1)
        #expect(await store.snapshot().notes.map(\.id).sorted() == ["quoted", "quoting"], "the quoted post outlived an older plain one")
        #expect(await store.letGoOldest(count: 1).posts == 1)
        #expect(await store.snapshot().notes.map(\.id) == ["quoted"], "the quoting post went next")
        #expect(await store.letGoOldest(count: 1).posts == 1)
        #expect(await store.snapshot().notes.isEmpty, "unquoted, it goes")
    }

    @Test("Nothing to let go, or none asked for, is nothing and no change")
    func nothingIsNothing() async {
        let store = ItemStore(sources: [alpha], notes: [note("a", daysAgo: 1, from: alpha)])
        let revision = await store.revision
        #expect(await store.letGoOldest(count: 0) == .none)
        #expect(await ItemStore().letGoOldest(count: 3) == .none)
        #expect(await store.revision == revision)
    }

    @Test("The months limit says which sources its posts went from")
    func monthsNamesSources() async {
        let store = ItemStore(sources: [alpha, beta], notes: [
            note("a", daysAgo: 1, from: alpha), note("b", daysAgo: 400, from: beta), note("c", daysAgo: 500, from: beta),
        ])
        let went = await store.letGoBeyond(months: 3, from: origin)
        #expect(went == WentByLimit(posts: 2, sources: ["beta.test"]))
        #expect(await store.letGoBeyond(months: 3, from: origin) == .none)
        #expect(await store.letGoBeyond(months: nil, from: origin) == .none)
    }

    @Test("A room never set is never over; over is by how much")
    func roomOver() {
        #expect(RoomPolicy.over(total: 5_000, room: nil) == 0)
        #expect(RoomPolicy.over(total: 5_000, room: 0) == 0)
        #expect(RoomPolicy.over(total: 5_000, room: 6_000) == 0)
        #expect(RoomPolicy.over(total: 5_000, room: 4_000) == 1_000)
        #expect(RoomPolicy.tightens(from: nil, to: 100))
        #expect(RoomPolicy.tightens(from: 200, to: 100))
        #expect(!RoomPolicy.tightens(from: 100, to: 200))
        #expect(!RoomPolicy.tightens(from: 100, to: nil))
        #expect(!RoomPolicy.tightens(from: nil, to: nil))
        #expect(RoomPolicy.choices == [100_000_000, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000])
    }

    @Test("How many posts to let go is judged by the average post, at least one and never more than held")
    func postsToLetGo() {
        #expect(RoomPolicy.postsToLetGo(over: 0, bytes: 1_000, posts: 10) == 0)
        #expect(RoomPolicy.postsToLetGo(over: 50, bytes: 1_000, posts: 10) == 1)
        #expect(RoomPolicy.postsToLetGo(over: 250, bytes: 1_000, posts: 10) == 3)
        #expect(RoomPolicy.postsToLetGo(over: 5_000, bytes: 1_000, posts: 10) == 10)
        #expect(RoomPolicy.postsToLetGo(over: 5, bytes: 0, posts: 10) == 5, "a store of no weight is judged a byte a post")
        #expect(RoomPolicy.postsToLetGo(over: 5, bytes: 100, posts: 0) == 0)
    }

    @Test("A line holds the limit, the moment, the counts and the sources folded and sorted, and survives JSON")
    func lineRoundTrips() throws {
        let act = LimitAct(limit: .room, at: origin, posts: 3, copies: 2, sources: ["Beta.test", "alpha.test"])
        #expect(act.sources == ["alpha.test", "beta.test"])
        #expect(act.isSomething)
        #expect(!LimitAct(limit: .months, at: origin, posts: 0, sources: []).isSomething)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(LimitAct.self, from: try encoder.encode(act))
        #expect(back == act)
        let text = String(decoding: try encoder.encode(act), as: UTF8.self)
        #expect(!text.contains("hello"), "a line never carries a post")
    }

    @Test("The account is newest first and bounded")
    func accountIsBounded() {
        var lines: [LimitAct] = []
        for n in 0..<(LimitAccount.capacity + 5) {
            lines = LimitAccount.adding(LimitAct(limit: .months, at: origin.addingTimeInterval(Double(n)), posts: 1, sources: []), to: lines)
        }
        #expect(lines.count == LimitAccount.capacity)
        #expect(lines.first?.at == origin.addingTimeInterval(Double(LimitAccount.capacity + 4)))
    }
}
