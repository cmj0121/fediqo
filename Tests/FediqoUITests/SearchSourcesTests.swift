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
@Suite("A search asks the sources of the timeline in front", .watched)
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
        session.deadlinesUnturned()
        await session.reloadFromStore()
        return session
    }

    private func searching(_ pattern: String, in session: ShellSession) async -> ShellSearch {
        let search = ShellSearch()
        search.open(from: nil, over: session.notes)
        await search.indexed()
        search.text = pattern
        search.settle(pattern)
        return search
    }

    private func found(_ search: ShellSearch, in session: ShellSession) -> Set<String> {
        Set(session.searched(search, latest: nil)?.map(\.id) ?? [])
    }

    // MARK: - Acceptance

    @Test("What the sources in front sent shows among the results and stands in All, and clearing the search leaves it there")
    func reachesTheSources() async throws {
        let server = Searchable([Self.one: Self.found])
        let session = try await shell(server)
        let search = await searching("cats", in: session)
        #expect(found(search, in: session) == [Self.local.key.rowID], "what this device held, at once")

        await session.reload.search("cats", timeline: .all, in: session)
        #expect(await server.asked == [Self.one], "only the source that can be searched")
        let query = try #require(await server.queries.first)
        #expect(query.contains(URLQueryItem(name: "q", value: "cats")))
        #expect(!query.contains { $0.name == "type" }, "one ask, of no kind alone: its answer carries what else the source found")
        #expect(query.contains(URLQueryItem(name: "resolve", value: "false")))

        #expect(found(search, in: session) == [Self.local.key.rowID, Self.foundKey.rowID])
        #expect(await session.store.note(Self.foundKey)?.categories.isEmpty == true, "the store's answer, through no category")
        #expect(session.notes.contains { $0.key == Self.foundKey }, "an item like any other")
        #expect(session.timelineItems(latest: nil).count == 2, "All grew by what the search brought")
        #expect(session.reload.searchFailed.isEmpty)
        #expect(session.reload.line == nil)

        // The search cleared: what it brought stays where it stands.
        search.text = ""
        search.settle("")
        session.reload.endSearch()
        #expect(session.timelineItems(latest: nil).map(\.id).contains(Self.foundKey.rowID))
        #expect(await session.store.all().contains { $0.key == Self.foundKey })
    }

    /// The rows the timeline made of `rules` draws, with that timeline in front.
    private func drawn(_ rules: [Rule?], in session: ShellSession) -> Set<String> {
        let timeline = TimelineDefinition(name: "T", rules: rules.compactMap { $0 })
        session.written = [timeline]
        session.timelineID = .written(timeline.id)
        defer { session.timelineID = .all }
        return Set(session.timelineItems(latest: nil).map(\.id))
    }

    @Test("What a search brought stands in All at the time it was posted; a timeline made of a category alone does not show it, and one whose rule is its source, its author or a word in it does")
    func whatASearchBroughtGoesThroughTheRulesThatLetItThrough() async throws {
        let session = try await shell(Searchable([Self.one: Self.found]))
        await session.reload.search("cats", timeline: .all, in: session)
        session.reload.endSearch()
        let found = Self.foundKey.rowID, local = Self.local.key.rowID
        let sources = session.sources

        let all = session.timelineItems(latest: nil)
        #expect(all.map(\.id) == [found, local], "newest first, by when each was posted")
        #expect(all.first?.postedAt == ISO8601DateFormatter().date(from: "2024-02-07T00:00:00Z"), "the source's time for it, not the search's")

        #expect(drawn([.category(.home, in: .every, sources: sources)], in: session).isEmpty, "it came through no category: not Home")
        #expect(drawn([.category(.public, in: .every, sources: sources)], in: session) == [local], "and not Public")
        #expect(drawn([.source(Self.one)], in: session) == [found, local])
        #expect(drawn([.author("ada@\(Self.one)", in: .every, sources: sources)], in: session) == [found, local])
        #expect(drawn([.keyword("wire", in: .every)], in: session) == [found])
    }

    @Test("Which sources were asked is said, and that the rest cannot be searched and were not")
    func saysWhoWasAsked() async throws {
        let session = try await shell(Searchable([Self.one: Self.found]))
        await session.reload.search("cats", timeline: .all, in: session)
        let reach = try #require(session.reload.reach)
        #expect(reach.asked == [Self.one])
        #expect(reach.unasked == [Self.two, Self.forum])
        #expect(reach.sentence == "Also asked one.example.")
        let lines = reach.unaskedLines(language: .english)
        #expect(lines.map(\.host) == [Self.two, Self.forum])
        #expect(lines.allSatisfy { $0.needsReader && $0.standsOut && $0.press == nil })
        #expect(StatusWords.count(lines) == 2)
        #expect(lines[0].words == "Not asked, as it cannot be searched from here: two.example.")
        #expect(!lines[0].words.contains(Self.forum))
        let chinese = reach.unaskedLines(language: .taiwanese)
        #expect(chinese[0].words.contains(Self.two) && chinese[0].words != lines[0].words)
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
        offline.deadlinesUnturned()
        await offline.reloadFromStore()
        let search = await searching("cats", in: offline)
        #expect(found(search, in: offline) == [Self.local.key.rowID, Self.foundKey.rowID])
        #expect(offline.notes.contains { $0.key == Self.foundKey }, "and it stands in All, as it did before the relaunch")
    }

    @Test("While on its way it says so and what was held shows; a source that failed says so, the others land")
    func onItsWayAndFailing() async throws {
        let server = Searchable(
            [Self.one: Self.found, Self.two: #"{"statuses":[]}"#], failing: [Self.two], holding: true
        )
        let guardTask = watching(server.gate, "the searches of both sources, held on the wire")
        defer { guardTask.cancel() }
        let session = try await shell(server, signedIn: [Self.one, Self.two])
        let search = await searching("cats", in: session)

        let asking = Task { await session.reload.search("cats", timeline: .all, in: session) }
        await met("both sources are asked", by: asking) { await server.asked.count == 2 }
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

        session.stream = .trends
        let fromTrends = await searching("cats", in: session)
        #expect(found(fromTrends, in: session).isEmpty, "a search's find is no trend")

        var draft = TimelineDraft(new: session.written.count + 1)
        draft.name = "Wire"
        draft.rules = [try #require(Rule.keyword("wire", in: .every))]
        session.commit(draft)
        session.stream = .timeline
        session.timelineID = .written(draft.id)
        let fromMine = await searching("cats", in: session)
        #expect(found(fromMine, in: session) == [Self.foundKey.rowID], "a keyword rule reads what the search brought")
    }

    @Test("Closing the search ends its ask: nothing it had not brought lands, and what it said goes")
    func closingEndsTheAsk() async throws {
        let server = Searchable([Self.one: Self.found], holding: true)
        let guardTask = watching(server.gate, "the search, held on the wire")
        defer { guardTask.cancel() }
        let session = try await shell(server)
        let asking = Task { await session.reload.search("cats", timeline: .all, in: session) }
        await met("the source is asked", by: asking) { await server.asked.count == 1 }
        session.reload.endSearch()
        await asking.value
        #expect(!session.reload.running)
        #expect(!session.reload.stopped)
        #expect(session.reload.reach == nil)
        #expect(session.reload.line == nil)
        await server.gate.open()
        // No `by:`: the read that was ended is the reload's own task, which no check can name.
        await met("the search ended is answered at the wire") { await server.answered == 1 }
        // Counted: what the ended read does with that answer is in that unnamed task too.
        for _ in 0..<2_000 { await Task.yield() }
        #expect(await session.store.note(Self.foundKey) == nil)
    }

    @Test("Who was asked is a (?) and who was not is the status mark, not a sentence under the field")
    func reachIsDrawn() throws {
        let lines = ShellReload.SearchReach(asked: [Self.one], unasked: [Self.two, Self.forum])
            .unaskedLines(language: .english)
        func height(_ reach: String?, _ scheme: ColorScheme) throws -> CGFloat {
            let bar = SearchBar(
                search: ShellSearch(), timeline: "All", found: 2, reach: reach, status: lines,
                onSubmit: {}, onCleared: {}, onClose: {}
            )
            .frame(width: 320)
            .environment(\.colorScheme, scheme)
            let image = try #require(ImageRenderer(content: bar).cgImage)
            return CGFloat(image.height)
        }
        let long = String(repeating: "Also asked one.example. ", count: 40)
        for scheme in [ColorScheme.light, .dark] {
            let short = try height("Also asked one.example.", scheme)
            #expect(try height(long, scheme) == short, "a (?) keeps a long explanation off the row")
        }
    }

    @Test("A search sends a server its words, not the pattern's wildcards")
    func words() {
        #expect(MastodonSearch.words(of: "cats") == "cats")
        #expect(MastodonSearch.words(of: " c*t  do?s ") == "c t do s")
        #expect(MastodonSearch.words(of: "* ?") == nil)
        #expect(MastodonSearch.words(of: "＊ ？") == nil, "a wildcard in any width")
        #expect(MastodonSearch.words(of: "a＊b") == "a b")
    }

    // MARK: - Review (#176)

    @Test("From a timeline that reads only some categories, nobody is asked, and that is said")
    func categoriesAskNobody() async throws {
        let server = Searchable([Self.one: Self.found])
        let session = try await shell(server)
        await session.reload.search("cats", timeline: .trends, in: session)
        #expect(await server.asked.isEmpty, "a find arrives through no category, so Trends could never show it")
        #expect(session.reload.reach?.asked == [])
        #expect(session.reload.reach?.unasked.contains(Self.one) == true)
        #expect(!session.reload.running)
    }

    @Test("Switching timeline with a search sent re-sends it to the new one's sources, and only then")
    func switchingReasks() async throws {
        let server = Searchable([Self.one: Self.found])
        let session = try await shell(server)
        session.stream = .trends
        await session.reload.searchSwitched(to: .trends, pattern: "cats", in: session)
        #expect(await server.asked.isEmpty, "no Return made yet: nothing to send again")

        session.stream = .timeline
        session.timelineID = .all
        await session.reload.search("cats", timeline: .all, in: session)
        #expect(await server.asked.count == 1)
        session.stream = .trends
        await session.reload.searchSwitched(to: .trends, pattern: "cats", in: session)
        #expect(await server.asked.count == 1, "Trends' sources cannot be searched")
        #expect(session.reload.reach?.asked == [], "the line is Trends', not All's")

        var draft = TimelineDraft(new: session.written.count + 1)
        draft.name = "Wire"
        draft.rules = [try #require(Rule.keyword("wire", in: .every))]
        session.commit(draft)
        session.stream = .timeline
        session.timelineID = .written(draft.id)
        await session.reload.searchSwitched(to: .written(draft.id), pattern: "cats", in: session)
        #expect(await server.asked.count == 2, "sent again, to the new timeline's sources")
        #expect(session.reload.reach?.asked == [Self.one])
    }

    @Test("Typed over since Return, a switch sends nothing and the old ask ends")
    func retypedSendsNothing() async throws {
        let server = Searchable([Self.one: Self.found])
        let session = try await shell(server)
        var draft = TimelineDraft(new: session.written.count + 1)
        draft.name = "Wire"
        draft.rules = [try #require(Rule.keyword("wire", in: .every))]
        session.commit(draft)
        session.timelineID = .all
        await session.reload.search("cats", timeline: .all, in: session)
        #expect(await server.asked.count == 1)

        session.timelineID = .written(draft.id)
        await session.reload.searchSwitched(to: .written(draft.id), pattern: "dogs", in: session)
        #expect(await server.asked.count == 1, "\"cats\" is no longer the search")
        #expect(session.reload.reach == nil)
    }

    @Test("A switch answered after another sends nothing to a timeline no longer in front")
    func lateSwitchSendsNothing() async throws {
        let server = Searchable([Self.one: Self.found])
        let session = try await shell(server)
        var draft = TimelineDraft(new: session.written.count + 1)
        draft.name = "Wire"
        draft.rules = [try #require(Rule.keyword("wire", in: .every))]
        session.commit(draft)
        session.timelineID = .all
        await session.reload.search("cats", timeline: .all, in: session)

        session.stream = .trends
        await session.reload.searchSwitched(to: .written(draft.id), pattern: "cats", in: session)
        #expect(await server.asked.count == 1)
        #expect(session.reload.reach?.asked == [Self.one], "the last search's line, untouched")
    }

    @Test("Marking a row a search brought as gone, and letting it go, each move what the timelines draw")
    func aGoneFindIsDrawn() async {
        let store = ItemStore()
        let source = Source(host: Self.one, kind: .mastodon)
        await store.add(source)
        let aside = Note(id: "aside", source: source, author: "Ada", handle: "@ada@\(Self.one)", body: "x",
                         postedAt: Date(timeIntervalSince1970: 0), categories: [])
        await store.ingest([aside], ifSourceHere: Self.one)
        let drawn = await store.drawn
        #expect(await store.markGone(aside.key))
        #expect(await store.drawn == drawn + 1, "marked: its row changed")
        #expect(await store.letGoneGo() == 1)
        #expect(await store.drawn == drawn + 2, "let go: its row went")
        #expect(await store.all().isEmpty)
    }

    @Test("A token that may not search is said as a sign-in to make again, not as silence")
    func refusedIsSaid() async throws {
        let session = try await shell(Searchable([Self.one: "{}"], refusing: [Self.one]))
        await session.reload.search("cats", timeline: .all, in: session)
        #expect(session.reload.searchFailed.isEmpty)
        #expect(session.reload.searchRefused == [Self.one])
        #expect(session.reload.line == "Could not search one.example: sign in to it again to let Fediqo search there.")
        #expect(L10n.t("search.scope", language: .taiwanese) != "search.scope")
        session.reload.endSearch()
        #expect(session.reload.line == nil)
    }

    @Test("A forum topic's kept replies its forum gave no date are counted apart from the items: a landing only the timelines see moves neither their count nor is moved by theirs")
    func repliesAreCountedApart() async {
        let store = ItemStore()
        let source = Source(host: Self.one, kind: .mastodon)
        let forum = Source(host: "forum.example", kind: .discuz)
        await store.add(source)
        await store.add(forum)
        func note(_ id: String) -> Note {
            Note(id: id, source: source, author: "Ada", handle: "@ada@\(Self.one)", body: id,
                 postedAt: Date(timeIntervalSince1970: 0), categories: [])
        }
        func reply(_ pid: Int) -> Note {
            DiscuzPost(pid: pid, tid: 7, author: "p", handle: "", body: "r\(pid)")
                .asNote(host: forum.host, read: Date(timeIntervalSince1970: 0))
        }
        await store.ingest([note("drawn")])
        #expect(await store.repliesRevision == 0)
        // What a search brought is an item: it moves what is drawn, and no reply's count.
        let drawn = await store.drawn
        await store.ingest([note("found")], ifSourceHere: Self.one)
        #expect(await store.drawn == drawn + 1)
        #expect(await store.repliesRevision == 0)

        await store.ingest([reply(2)], ifSourceHere: forum.host)
        #expect(await store.repliesRevision == 1)
        #expect(await store.drawn == drawn + 1, "a page of a topic read replaces no row of All")
        await store.ingest([reply(2)], ifSourceHere: forum.host)
        #expect(await store.repliesRevision == 1, "the same again changed nothing")
        await store.ingest([reply(3)], ifSourceHere: forum.host)
        await store.forget(reply(3).key)
        #expect(await store.repliesRevision == 3)
        await store.ingest([note("more")])
        #expect(await store.repliesRevision == 3)
        #expect(await store.all().map(\.id).sorted() == ["drawn", "found", "more"])
        #expect(await store.replies().map(\.id) == [reply(2).id])
    }
}

/// A signed-in door answering `/api/v2/search` per host, remembering who was asked and with what.
/// `failing` hosts answer 500, `refusing` ones the 403 of a sign-in made without search; `holding` parks every search until the gate opens.
private actor Searchable: HTTPSender {
    private let bodies: [String: String]
    private let failing: Set<String>
    private let refusing: Set<String>
    private let holding: Bool
    let gate = Gate()
    private(set) var asked: [String] = []
    private(set) var queries: [[URLQueryItem]] = []
    /// How many held searches have been let go and answered.
    private(set) var answered = 0

    init(
        _ bodies: [String: String], failing: Set<String> = [], refusing: Set<String> = [], holding: Bool = false
    ) {
        self.bodies = bodies
        self.failing = failing
        self.refusing = refusing
        self.holding = holding
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let host = url.host ?? ""
        guard url.path == "/api/v2/search", let body = bodies[host] else { throw FixtureHTTPError.unmapped }
        asked.append(host)
        queries.append(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        if holding {
            await gate.wait()
            answered += 1
        }
        let status = refusing.contains(host) ? 403 : failing.contains(host) ? 500 : 200
        // A refusal for want of search, as a real server words it.
        let said = refusing.contains(host) ? #"{"error":"This action is outside the authorized scopes"}"# : body
        return (Data(said.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
