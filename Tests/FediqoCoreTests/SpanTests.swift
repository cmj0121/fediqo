import Foundation
import Testing
@testable import FediqoCore

/// #248: the store lets go of exactly the rows of a span of moments from one host, or from every
/// host — arrived and aside alike — and nothing else moves.
@Suite("Letting a span go")
struct SpanTests {
    private static let alpha = Source(host: "alpha.test", kind: .mastodon)
    private static let beta = Source(host: "beta.test", kind: .mastodon)
    private static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private static func note(_ id: String, day: Double, from source: Source, holding: Holding = .arrived) -> Note {
        Note(id: id, source: source, author: "Ada", handle: "@ada", body: "hello",
             postedAt: origin.addingTimeInterval(day * 86_400), categories: [.public], holding: holding)
    }

    /// Days 0 through 3: alpha holds one a day, one of day 2's held aside; beta holds day 1 and 2.
    private static func held() -> ItemStore {
        ItemStore(sources: [alpha, beta], notes: [
            note("a0", day: 0, from: alpha), note("a1", day: 1, from: alpha),
            note("a2", day: 2, from: alpha, holding: .aside), note("a3", day: 3, from: alpha),
            note("b1", day: 1, from: beta), note("b2", day: 2, from: beta),
        ])
    }

    /// From the start of day 1 to the start of day 3: days 1 and 2.
    private static let days1to2 = origin.addingTimeInterval(86_400)..<origin.addingTimeInterval(3 * 86_400)

    @Test("A span from one host takes its arrived and aside rows inside it, and nothing else")
    func spanFromOneHost() async {
        let store = Self.held()
        let revision = await store.revision
        #expect(await store.count(span: Self.days1to2, host: "Alpha.Test") == 2, "the count the question names")
        #expect(await store.letGo(span: Self.days1to2, host: "Alpha.Test") == 2)
        #expect(await store.all().map(\.id).sorted() == ["a0", "a3", "b1", "b2"])
        #expect(await store.aside().isEmpty, "the aside row on day 2 went with the arrived one")
        #expect(await store.snapshot().notes.map(\.id).sorted() == ["a0", "a3", "b1", "b2"])
        #expect(await store.sources() == [Self.alpha, Self.beta], "every source stays joined")
        #expect(await store.revision > revision, "a save follows")
    }

    @Test("A span from every host takes every host's rows inside it")
    func spanFromEveryHost() async {
        let store = Self.held()
        #expect(await store.count(span: Self.days1to2) == 4)
        #expect(await store.letGo(span: Self.days1to2) == 4)
        #expect(await store.snapshot().notes.map(\.id).sorted() == ["a0", "a3"])
    }

    @Test("The span's first moment is inside it and its last is not")
    func edgesAreHalfOpen() async {
        let store = Self.held()
        let start = Self.origin.addingTimeInterval(86_400)
        #expect(await store.count(span: start..<start.addingTimeInterval(1)) == 2, "b1 and a1 sit on the start")
        #expect(await store.count(span: Self.origin..<start) == 1, "a0 only: a1 sits on the end")
    }

    @Test("A span holding nothing changes nothing and says so")
    func nothingInside() async {
        let store = Self.held()
        let revision = await store.revision
        #expect(await store.letGo(span: Self.days1to2, host: "nobody.test") == 0)
        #expect(await store.letGo(span: Self.origin.addingTimeInterval(9 * 86_400)..<Self.origin.addingTimeInterval(10 * 86_400)) == 0)
        #expect(await store.revision == revision)
        #expect(await store.snapshot().notes.count == 6)
    }

    @Test("A host that is no longer a source is reached like any other")
    func removedSourcesRowsGoToo() async {
        let store = ItemStore(sources: [Self.alpha], notes: [
            Self.note("a1", day: 1, from: Self.alpha), Self.note("b1", day: 1, from: Self.beta),
        ])
        #expect(await store.count(span: Self.days1to2, host: Self.beta.host) == 1)
        #expect(await store.letGo(span: Self.days1to2, host: Self.beta.host) == 1)
        #expect(await store.snapshot().notes.map(\.id) == ["a1"])
    }

    @Test("What went stays gone through a snapshot and a relaunch")
    func relaunchKeepsThemGone() async {
        let store = Self.held()
        await store.letGo(span: Self.days1to2, host: Self.alpha.host)
        let snapshot = await store.snapshot()
        let relaunched = ItemStore(sources: snapshot.sources, notes: snapshot.notes)
        #expect(await relaunched.all().map(\.id).sorted() == ["a0", "a3", "b1", "b2"])
        #expect(await relaunched.count(span: Self.days1to2, host: Self.alpha.host) == 0)
    }
}
