import Foundation
import Testing
@testable import FediqoCore

/// #194: what this device says it holds counts the posts no timeline shows, and says how many.
@Suite("What is held apart is counted")
struct CountsHeldTests {
    private let first = Source(host: "first.example", kind: .mastodon)
    private let second = Source(host: "second.example", kind: .mastodon)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func note(_ id: String, daysAgo: Double = 1, from source: Source) -> Note {
        Note(id: id, source: source, author: "Ada", handle: "@ada", body: "hello",
             postedAt: now.addingTimeInterval(-daysAgo * 86_400), categories: [.public])
    }

    @Test("A post held aside counts with the rest, and is said apart, in total and by source")
    func asideIsCountedAndSaid() async {
        let store = ItemStore(sources: [first, second], notes: [note("1", from: first)])
        await store.hold([note("found", from: second), note("answer", from: first)], ifSourceHere: second.host)
        await store.hold([note("answer", from: first)], ifSourceHere: first.host)

        let shown = Holdings(notes: await store.all(), per: .month)
        let held = Holdings(notes: await store.all() + store.aside(), per: .month)
        #expect(shown.posts == 1, "a timeline's count leaves the finds out, which is the lie")
        #expect(held.posts == 3)
        #expect(held.aside == 2)
        #expect(held.posts(host: "second.example") == 1, "a source no timeline shows still holds its find")
        #expect(held.aside(host: "second.example") == 1)
        #expect(held.posts(host: "FIRST.example") == 2)
        #expect(held.aside(host: "first.example") == 1)
        #expect(held.byPeriod.map(\.posts).reduce(0, +) == 3, "the stretches count what the total does")
    }

    @Test("Nothing held aside says nothing apart")
    func nothingAside() {
        let held = Holdings(notes: [note("1", from: first)], per: .week)
        #expect(held.aside == 0)
        #expect(held.asideBySource.isEmpty)
        #expect(held.aside(host: first.host) == 0)
    }

    @Test("Letting posts go by time counts those held aside in what went")
    func keepingCountsAsideAmongTheGone() async {
        let store = ItemStore(sources: [first, second], notes: [
            note("new", daysAgo: 1, from: first), note("old", daysAgo: 400, from: first),
        ])
        await store.hold([note("stale-find", daysAgo: 400, from: second), note("fresh-find", from: second)],
                         ifSourceHere: second.host)
        let went = await store.setRetention(months: 3, from: now)
        #expect(went == 2, "the stale find went with the old post, and both are counted")
        let held = Holdings(notes: await store.all() + store.aside(), per: .month)
        #expect(held.posts == 2)
        #expect(held.aside == 1)
        #expect(held.posts(host: second.host) == 1)
    }
}
