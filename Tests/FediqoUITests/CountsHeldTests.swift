import FediqoCore
import Foundation
import Testing
@testable import FediqoUI

/// #194: Usage's figures count everything this device holds — a search's finds, a conversation's
/// answers, a forum topic's replies — and say how many of them no timeline shows.
@Suite("Usage counts everything held, in one figure")
@MainActor
struct CountsHeldTests {
    private static let alpha = Source(host: "alpha.test", kind: .mastodon)
    private static let beta = Source(host: "beta.test", kind: .mastodon)
    private static let forum = Source(host: "forum.test", kind: .discuz)
    private static let now = Date()

    private static func note(_ id: String, daysAgo: Double = 1, from source: Source) -> Note {
        Note(id: id, source: source, author: "Ada", handle: "@ada", body: "hello",
             postedAt: now.addingTimeInterval(-daysAgo * 86_400), categories: [.public])
    }

    /// A forum topic's reply as the store keeps one its forum gave no date (#177, #297): a post
    /// the search leaves out.
    private static func reply(_ pid: Int) -> Note {
        note("discuz:forum.test:7:post:\(pid)", from: forum)
    }

    /// Alpha's one timeline post; a find from beta, which no timeline shows; a reply on the forum.
    private static func held() async -> ItemStore {
        let store = ItemStore(sources: [alpha, beta, forum], notes: [note("1", from: alpha)])
        await store.ingest([note("found", from: beta)], ifSourceHere: beta.host)
        await store.ingest([reply(2)], ifSourceHere: forum.host)
        return store
    }

    @Test("A search's find counts for its source and in total, in the one figure, and stands with the items the timelines read")
    func findsAreCounted() async {
        let session = ShellSession(http: FixtureHTTP(), store: await Self.held())
        await session.reloadFromStore()
        #expect(session.notes.map(\.id).sorted() == ["1", "found"], "what a search brought is an item like any other")
        #expect(session.holdings.posts == 3)
        #expect(session.holdings.posts(host: Self.beta.host) == 1)
        #expect(session.holdings.posts(host: Self.alpha.host) == 1)
    }

    @Test("A forum topic's reply its forum gave no date is counted, and is no item: no timeline and no search reads it")
    func forumRepliesAreCounted() async {
        let session = ShellSession(http: FixtureHTTP(), store: await Self.held())
        await session.reloadFromStore()
        #expect(!session.notes.contains { $0.isTopicReply }, "a part of a topic stood among the items")
        #expect(session.heldReplies.map(\.id) == ["discuz:forum.test:7:post:2"])
        #expect(session.holdings.posts(host: Self.forum.host) == 1)
    }

    @Test("A find held after launch is counted as the store says it changed")
    func aLaterFindIsCounted() async {
        let store = await Self.held()
        let session = ShellSession(http: FixtureHTTP(), store: store)
        await session.reloadFromStore()
        await store.ingest([Self.note("found-later", from: Self.beta)], ifSourceHere: Self.beta.host)
        await session.reloadFromStore()
        #expect(session.holdings.posts(host: Self.beta.host) == 2)
        #expect(session.holdings.posts == 4)
    }

    @Test("Letting posts go by time counts what a search brought in what went, and the count follows")
    func keepingCountsAside() async {
        let store = await Self.held()
        await store.ingest([Self.note("stale", daysAgo: 400, from: Self.beta)], ifSourceHere: Self.beta.host)
        let session = ShellSession(http: FixtureHTTP(), store: store)
        await session.reloadFromStore()
        #expect(session.holdings.posts == 4)
        #expect(await session.keep(months: 3, from: Self.now) == 1)
        #expect(session.holdings.posts == 3)
        #expect(session.holdings.posts(host: Self.beta.host) == 1)
    }

    @Test("The store's weight on disk is read from the one measure the app hands in, and again after a drop")
    func storeBytesAreMeasured() async {
        let store = await Self.held()
        await store.ingest([Self.note("stale", daysAgo: 400, from: Self.beta)], ifSourceHere: Self.beta.host)
        let session = ShellSession(http: FixtureHTTP(), store: store)
        #expect(session.storeBytes == nil, "until measured, nothing is said")
        await session.readStoreBytes()
        #expect(session.storeBytes == nil, "no measure, no figure")
        let measures = Measures()
        session.measureStore = { await measures.next() }
        await session.readStoreBytes()
        #expect(session.storeBytes == 1_000)
        await session.reloadFromStore()
        _ = await session.keep(months: 3, from: Self.now)
        await session.saved()
        #expect(session.storeBytes == 2_000, "a drop by time measures the index again once it is written")
    }

    private actor Measures {
        private var calls = 0
        func next() -> Int {
            calls += 1
            return calls * 1_000
        }
    }

    @Test("The total line carries the disk figure once measured, and nothing is said apart")
    func lines() {
        #expect(UsagePane.totalLine(3, onDisk: nil) == UsagePane.postsLine(3))
        #expect(UsagePane.totalLine(3, onDisk: 4096).components(separatedBy: " · ").count == 2)
        for language in [DummyLanguage.english, .taiwanese] {
            #expect(L10n.t("prefs.held.aside", language: language) == "prefs.held.aside", "the words for held apart are gone")
        }
    }

    @Test("No file of words has a line for what is held apart: nothing is")
    func noWordsForHeldApart() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FediqoUI/Resources")
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            #expect(!strings.contains("prefs.held.aside"), "\(lproj) still has words for held apart")
            #expect(!strings.contains("apart from the timelines") && !strings.contains("時間軸之外"), "\(lproj) still says so somewhere")
        }
    }
}
