import Foundation
import Testing
import GRDB
@testable import FediqoCore

/// Finding what this device already holds (#105).
///
/// `PostStore.search` has been here since migration 010 and nothing opened it. What makes it
/// worth opening is what it does not do: it asks nobody, so it is instant, private, and there
/// with the network off.
@Suite("Finding what you already have")
struct LocalSearchTests {
    private let server = Server(host: "held.example", socialProtocol: .mastodon)

    private func stocked() async throws -> LocalStore {
        let store = try LocalStore.inMemory()
        // Three posts that arrived three different ways. What a search is about is what this
        // device holds, so how each of them got here must make no difference.
        try await store.save([makePost(uri: "https://held.example/1", at: 300, from: "held.example",
                                       text: "a quiet argument about libraries")],
                             from: server, into: .public, as: nil)
        try await store.save([makePost(uri: "https://held.example/2", at: 200, from: "held.example",
                                       text: "libraries close early on Sundays")],
                             from: server, into: .tag, as: nil)
        try await store.save([makePost(uri: "https://held.example/3", at: 100, from: "held.example",
                                       text: "nothing to do with the subject")],
                             from: server, into: .thread, as: nil)
        return store
    }

    // MARK: - it is a reading, so it is a timeline

    /// The whole of why there is no new screen: a search is a base source, so the rows, the
    /// ring, the keys and the paging are the ones that were already there (#103).
    @Test("A search is a base source and a search timeline carries its words")
    func asearchIsAReading() {
        let timeline = Timeline(name: "", source: .search, words: "libraries", template: "search")
        #expect(timeline.words == "libraries")
        #expect(timeline.query.words == "libraries")
    }

    /// It asks nobody, so there is nothing to fan out — which is what keeps the loader from
    /// ever putting a reader's search to somebody else's server. That is #106, and it has a
    /// cost this one does not.
    @Test("A search asks nobody")
    func asearchAsksNobody() {
        let timeline = Timeline(name: "", source: .search, words: "libraries", template: "search")
        #expect(timeline.query.readings.isEmpty)
    }

    /// Words on a reading that is not a search cannot mean anything, so they are not carried
    /// around waiting to be believed — the same rule `writers` and `account` are kept by.
    @Test("Only a search keeps words")
    func onlyAsearchKeepsWords() {
        for source in BaseSource.allCases where source != .search {
            #expect(Timeline(name: "", source: source, words: "x", template: "t").words == "")
        }
    }

    @Test("A search is a way a post can arrive")
    func searchIsAFeed() async throws {
        let store = try LocalStore.inMemory()
        let feeds = try await store.read { db in
            try String.fetchAll(db, sql: "SELECT feed FROM feeds ORDER BY feed")
        }
        #expect(feeds.contains("search"))
    }

    // MARK: - what it finds

    /// **However it came to be here.** Every other base asks `post_origins` how a post arrived;
    /// this one does not ask at all, and a search that only found what the public timeline
    /// carried would not be a search of this device.
    @Test("It finds what this device holds, whichever reading brought it")
    func itfindsWhateverIsHeld() async throws {
        let store = try await stocked()
        let found = try await store.timeline(matching: TimelineQuery(source: .search,
                                                                     words: "libraries"))
        #expect(found.count == 2)
    }

    /// Newest first, like everything else here. Nothing in this app ranks anything, and a
    /// search that quietly ordered by relevance would be the first thing that did.
    @Test("It is newest first, and nothing is ranked")
    func newestFirst() async throws {
        let store = try await stocked()
        let found = try await store.timeline(matching: TimelineQuery(source: .search,
                                                                     words: "libraries"))
        #expect(found.map(\.createdAt) == found.map(\.createdAt).sorted(by: >))
    }

    @Test("Every word has to be there, not just one of them")
    func everyWord() async throws {
        let store = try await stocked()
        let both = try await store.timeline(matching: TimelineQuery(source: .search,
                                                                    words: "libraries Sundays"))
        #expect(both.map(\.text) == ["libraries close early on Sundays"])
    }

    /// A search with nothing in it is not a search for everything. The screen says so in words;
    /// this is the half that makes the words true.
    @Test("No words find nothing, rather than everything")
    func nowordsFindNothing() async throws {
        let store = try await stocked()
        #expect(try await store.timeline(matching: TimelineQuery(source: .search, words: "")).isEmpty)
        #expect(try await store.timeline(matching: TimelineQuery(source: .search, words: "   ")).isEmpty)
    }

    @Test("A word nobody wrote finds nothing")
    func nothingMatches() async throws {
        let store = try await stocked()
        #expect(try await store.timeline(matching: TimelineQuery(source: .search,
                                                                 words: "bicycles")).isEmpty)
    }

    /// A quote is a word rather than the start of an FTS phrase and the end of trouble.
    @Test("A quotation mark is a character somebody typed, not syntax")
    func aquoteIsNotSyntax() async throws {
        let store = try await stocked()
        #expect(try await store.timeline(matching: TimelineQuery(source: .search,
                                                                 words: "\"libraries")).count == 2)
    }

    // MARK: - through the store and back

    @Test("A search kept as a timeline remembers what it was for")
    func roundTrip() async throws {
        let store = try LocalStore.inMemory()
        try await store.save(Timeline(id: "s", name: "Libraries", source: .search,
                                      words: "libraries", template: "search"))
        #expect(try await store.timelines().first?.words == "libraries")
    }
}
