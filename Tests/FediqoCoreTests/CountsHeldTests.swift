import Foundation
import Testing
@testable import FediqoCore

/// #194: what this device says it holds counts the posts no timeline shows, and says how many.
@Suite("Everything held is counted, in one figure")
struct CountsHeldTests {
    private let first = Source(host: "first.example", kind: .mastodon)
    private let second = Source(host: "second.example", kind: .mastodon)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func note(_ id: String, daysAgo: Double = 1, from source: Source) -> Note {
        Note(id: id, source: source, author: "Ada", handle: "@ada", body: "hello",
             postedAt: now.addingTimeInterval(-daysAgo * 86_400), categories: [.public])
    }

    @Test("A post a search or a thread brought counts with the rest: one figure, in total and by source")
    func asideIsCountedAndSaid() async {
        let store = ItemStore(sources: [first, second], notes: [note("1", from: first)])
        await store.ingest([note("found", from: second), note("answer", from: first)], ifSourceHere: second.host)
        await store.ingest([note("answer", from: first)], ifSourceHere: first.host)

        let held = Holdings(notes: await store.all(), per: .month)
        #expect(held.posts == 3, "everything held is in what the timelines read from")
        #expect(held.posts(host: "second.example") == 1)
        #expect(held.posts(host: "FIRST.example") == 2)
        #expect(held.byPeriod.map(\.posts).reduce(0, +) == 3, "the stretches count what the total does")
    }

    @Test("Letting posts go by time counts what a search brought in what went")
    func keepingCountsAsideAmongTheGone() async {
        let store = ItemStore(sources: [first, second], notes: [
            note("new", daysAgo: 1, from: first), note("old", daysAgo: 400, from: first),
        ])
        await store.ingest([note("stale-find", daysAgo: 400, from: second), note("fresh-find", from: second)],
                         ifSourceHere: second.host)
        let went = await store.setRetention(months: 3, from: now)
        #expect(went == 2, "the stale find went with the old post, and both are counted")
        let held = Holdings(notes: await store.all(), per: .month)
        #expect(held.posts == 2)
        #expect(held.posts(host: second.host) == 1)
    }
}
