import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #176: a search asks the sources of the timeline in front as well, and what they found stays.
///
/// Read through `ShellSession.searched`, the one call the pane's list and the keys both read, so
/// what is asserted is what the reader is shown. The sources answer through a signed-in door that
/// is a fixture; nothing here touches a network.
@MainActor
@Suite("A search asks the sources of the timeline in front")
struct SearchSourcesTests {
    private static let one = "one.example"
    private static let two = "two.example"
    private static let forum = "forum.example"

    init() {
        L10n.language = .english
    }

    private static func status(_ id: String, _ text: String, on host: String = one) -> String {
        """
        {"id":"\(id)","uri":"https://\(host)/users/ada/statuses/\(id)",
         "created_at":"2024-02-0\(id)T00:00:00.000Z","content":"<p>\(text)</p>",
         "account":{"username":"ada","acct":"ada","display_name":"Ada"}}
        """
    }

    /// What `one.example` finds for "cats": a post this device never held.
    private static let found = #"{"statuses":["# + status("7", "cats on the wire") + "]}"

    /// The row a search on `one.example` brings back.
    private static var foundKey: NoteKey {
        Note(
            id: "https://\(one)/users/ada/statuses/7", source: Source(host: one, kind: .mastodon),
            author: "Ada", handle: "@ada@\(one)", body: "", postedAt: .distantPast, categories: []
        ).key
    }

    /// Held on this device already, and matching "cats".
    private static let local = Note(
        id: "https://\(one)/users/ada/statuses/1", source: Source(host: one, kind: .mastodon),
        author: "Ada", handle: "@ada@\(one)", body: "cats at home",
        postedAt: Date(timeIntervalSince1970: 0), categories: [.public]
    )

    /// Two Mastodons — `one` signed in, `two` not — and a forum, over `store`, with `local` held.
    private func shell(
        _ sender: any HTTPSender, signedIn hosts: [String] = [one], store: ItemStore = ItemStore()
    ) async throws -> ShellSession {
        let tokens = MemoryMastodonTokens()
        for host in hosts {
            try tokens.save(MastodonToken(host: host, accessToken: "tok", clientID: "c", clientSecret: "s"))
        }
        await store.add(Source(host: Self.one, kind: .mastodon))
        await store.add(Source(host: Self.two, kind: .mastodon))
        await store.add(Source(
            host: Self.forum, kind: .discuz, boards: [BoardSubscription(fid: 34, name: "Dev")]
        ))
        await store.ingest([Self.local])
        let http = FixtureHTTP([:])
        let session = ShellSession(
            http: http, store: store, mastodon: MastodonSessions(tokens: tokens, sender: sender),
            posts: ForumPosts(http: http)
        )
        await session.reloadFromStore()
        return session
    }

    private func searching(_ pattern: String, in session: ShellSession) async -> ShellSearch {
        let search = ShellSearch()
        search.open(from: nil, over: session.searchable)
        await search.indexed()
        search.text = pattern
        search.settle(pattern)
        return search
    }

    private func found(_ search: ShellSearch, in session: ShellSession) -> Set<String> {
        Set(session.searched(search, latest: nil)?.map(\.id) ?? [])
    }

    // MARK: - Acceptance

    @Test("What the sources in front sent shows among the results, held aside, and All does not grow")
    func reachesTheSources() async throws {
        let server = Searchable([Self.one: Self.found])
        let session = try await shell(server)
        let search = await searching("cats", in: session)
        #expect(found(search, in: session) == [Self.local.key.rowID], "what this device held, at once")

        await session.reload.search("cats", timeline: .all, in: session)
        #expect(await server.asked == [Self.one], "only the source that can be searched")
        let query = try #require(await server.queries.first)
        #expect(query.contains(URLQueryItem(name: "q", value: "cats")))
        #expect(query.contains(URLQueryItem(name: "type", value: "statuses")))

        #expect(found(search, in: session) == [Self.local.key.rowID, Self.foundKey.rowID])
        #expect(await session.store.note(Self.foundKey)?.holding == .aside, "the store's answer, held aside")
        #expect(!session.notes.contains { $0.key == Self.foundKey }, "All did not grow by it")
        #expect(session.timelineItems(latest: nil).count == 1)
        #expect(session.reload.searchFailed.isEmpty)
        #expect(session.reload.line == nil)
    }

    @Test("Which sources were asked is said, and that the rest cannot be searched and were not")
    func saysWhoWasAsked() async throws {
        let session = try await shell(Searchable([Self.one: Self.found]))
        await session.reload.search("cats", timeline: .all, in: session)
        let reach = try #require(session.reload.reach)
        #expect(reach.asked == [Self.one])
        #expect(reach.unasked == [Self.two, Self.forum])
        #expect(reach.sentence
            == "Also asked one.example. Not asked, as they cannot be searched from here: two.example, forum.example.")
        for key in ["search.asking", "search.failed", "search.reach.asked", "search.reach.notAsked", "work.purpose.search"] {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    @Test("A timeline with no source that can be searched asks nobody, and says so")
    func nobodyToAsk() async throws {
        let server = Searchable([:])
        let session = try await shell(server, signedIn: [])
        await session.reload.search("cats", timeline: .all, in: session)
        #expect(await server.asked.isEmpty)
        #expect(!session.reload.running)
        #expect(session.reload.reach?.asked == [])
        #expect(session.reload.reach?.unasked == [Self.one, Self.two, Self.forum])
    }

    @Test("With the network off afterwards, the same search still finds what was brought back")
    func staysOffline() async throws {
        let first = try await shell(Searchable([Self.one: Self.found]))
        await first.reload.search("cats", timeline: .all, in: first)

        // Relaunched from what a save writes, and nothing answers any more.
        let saved = await first.store.snapshot()
        let relaunched = ItemStore(sources: saved.sources, notes: saved.notes)
        let offline = ShellSession(
            http: FixtureHTTP([:]), store: relaunched,
            mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: Searchable([:]))
        )
        await offline.reloadFromStore()
        let search = await searching("cats", in: offline)
        #expect(found(search, in: offline) == [Self.local.key.rowID, Self.foundKey.rowID])
        #expect(!offline.notes.contains { $0.key == Self.foundKey }, "still held aside, not in All")
    }

    @Test("While on its way it says so and what was held shows; a source that failed says so, the others land")
    func onItsWayAndFailing() async throws {
        let server = Searchable(
            [Self.one: Self.found, Self.two: #"{"statuses":[]}"#], failing: [Self.two], holding: true
        )
        let guardTask = hangGuard(server.gate)
        defer { guardTask.cancel() }
        let session = try await shell(server, signedIn: [Self.one, Self.two])
        let search = await searching("cats", in: session)

        let asking = Task { await session.reload.search("cats", timeline: .all, in: session) }
        #expect(await spun { await server.asked.count == 2 })
        #expect(session.reload.running)
        #expect(session.reload.line == "Searching one.example, two.example…")
        let toast = TimelineToast.shown(
            running: session.reload.running, waiting: session.reload.onlyWaiting,
            line: session.reload.line, stopped: session.reload.stopped, note: nil
        )
        #expect(toast == TimelineToast(kind: .loading, text: "Searching one.example, two.example…"))
        #expect(session.reload.reading.isEmpty, "the toast says the search's line, not a reload's pieces")
        #expect(found(search, in: session) == [Self.local.key.rowID], "what this device held, not waiting")
        #expect(!session.reload.stop(), "Esc closes the search rather than being spent here")

        await server.gate.open()
        await asking.value
        #expect(session.reload.searchFailed == [Self.two])
        #expect(session.reload.line == "Could not search two.example.")
        #expect(found(search, in: session) == [Self.local.key.rowID, Self.foundKey.rowID], "the other landed")
    }

    @Test("The results still pass the rules of the timeline in front")
    func rulesStillHold() async throws {
        let session = try await shell(Searchable([Self.one: Self.found]))
        await session.reload.search("cats", timeline: .all, in: session)

        session.timelineID = .trends
        let fromTrends = await searching("cats", in: session)
        #expect(found(fromTrends, in: session).isEmpty, "a search's find is no trend")

        var draft = TimelineDraft(new: session.written.count + 1)
        draft.name = "Wire"
        draft.rules = [try #require(Rule.keyword("wire", in: .every))]
        session.commit(draft)
        session.timelineID = .written(draft.id)
        let fromMine = await searching("cats", in: session)
        #expect(found(fromMine, in: session) == [Self.foundKey.rowID], "a keyword rule reads what was held aside")
    }

    @Test("Closing the search ends its ask: nothing it had not brought lands, and what it said goes")
    func closingEndsTheAsk() async throws {
        let server = Searchable([Self.one: Self.found], holding: true)
        let guardTask = hangGuard(server.gate)
        defer { guardTask.cancel() }
        let session = try await shell(server)
        let asking = Task { await session.reload.search("cats", timeline: .all, in: session) }
        #expect(await spun { await server.asked.count == 1 })
        session.reload.endSearch()
        await asking.value
        #expect(!session.reload.running)
        #expect(!session.reload.stopped)
        #expect(session.reload.reach == nil)
        #expect(session.reload.line == nil)
        await server.gate.open()
        for _ in 0..<2_000 { await Task.yield() }
        #expect(await session.store.note(Self.foundKey) == nil)
    }

    @Test("The line saying who was asked is drawn under the field, whole, in light and in dark, at a phone's width")
    func reachIsDrawn() throws {
        let reach = ShellReload.SearchReach(asked: [Self.one], unasked: [Self.two, Self.forum]).sentence
        func height(_ reach: String?, _ scheme: ColorScheme) throws -> CGFloat {
            let bar = SearchBar(
                search: ShellSearch(), timeline: "All", found: 2, reach: reach,
                onSubmit: {}, onCleared: {}, onClose: {}
            )
            .frame(width: 320)
            .environment(\.colorScheme, scheme)
            let image = try #require(ImageRenderer(content: bar).cgImage)
            return CGFloat(image.height)
        }
        for scheme in [ColorScheme.light, .dark] {
            let bare = try height(nil, scheme)
            #expect(try height(reach, scheme) > bare + 20, "wrapped over lines rather than cut to one")
        }
    }

    @Test("A search sends a server its words, not the pattern's wildcards")
    func words() {
        #expect(MastodonSearch.words(of: "cats") == "cats")
        #expect(MastodonSearch.words(of: " c*t  do?s ") == "c t do s")
        #expect(MastodonSearch.words(of: "* ?") == nil)
    }
}

/// A signed-in door answering `/api/v2/search` per host, remembering who was asked and with what.
/// `failing` hosts answer 500; `holding` parks every search until the gate opens.
private actor Searchable: HTTPSender {
    private let bodies: [String: String]
    private let failing: Set<String>
    private let holding: Bool
    let gate = Gate()
    private(set) var asked: [String] = []
    private(set) var queries: [[URLQueryItem]] = []

    init(_ bodies: [String: String], failing: Set<String> = [], holding: Bool = false) {
        self.bodies = bodies
        self.failing = failing
        self.holding = holding
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let host = url.host ?? ""
        guard url.path == "/api/v2/search", let body = bodies[host] else { throw FixtureHTTPError.unmapped }
        asked.append(host)
        queries.append(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        if holding { await gate.wait() }
        let status = failing.contains(host) ? 500 : 200
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
