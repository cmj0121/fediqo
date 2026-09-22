import Foundation
@testable import FediqoCore
import Testing
@testable import FediqoUI

/// #145: a search finds what the timeline in front lets through, not everything this device holds.
///
/// Asked through `ShellSession.searched`, the one call both the pane's list and the keys read, so
/// what is asserted here is what the reader is shown and what `j` walks.
@Suite("Searching the timeline in front")
@MainActor
struct SearchInTimelineTests {
    private let microblog = Source(host: "m.example", kind: .mastodon)
    private let forum = Source(host: "f.example", kind: .discuz, boards: [BoardSubscription(fid: 42, name: "Dev")])

    init() {
        L10n.language = .english
    }

    private func note(
        _ id: String, _ author: String, _ body: String, _ categories: Set<FediqoCore.Category> = [.public],
        at t: Double = 0, on source: Source? = nil
    ) -> Note {
        let source = source ?? microblog
        return Note(id: id, source: source, author: author, handle: "@\(author.lowercased())@\(source.host)",
                    body: body, postedAt: Date(timeIntervalSince1970: t), categories: categories)
    }

    /// Every post says "swift", so the pattern alone would find all of them: whatever is not found
    /// was kept out by the timeline.
    private var notes: [Note] {
        [
            note("pub", "Ada", "swift public", [.public], at: 9),
            note("trend", "Bob", "swift trending", [.trends], at: 8),
            note("spoil", "Cy", "swift spoiler", [.public], at: 7),
            note("board", "Dee", "swift board", [.board(id: "42")], at: 6, on: forum),
        ]
    }

    private func session() -> ShellSession {
        let session = ShellSession(http: FixtureHTTP([:]), timelines: WrittenTimelineStore(defaults: SearchDefaults()))
        session.sources = [microblog, forum]
        session.rebuildQueries()
        session.notes = notes
        return session
    }

    private func write(_ name: String, _ rules: [Rule], in session: ShellSession) -> TimelineQuery {
        var draft = TimelineDraft(new: session.written.count + 1)
        draft.name = name
        draft.rules = rules
        session.commit(draft)
        return .written(draft.id)
    }

    private func searching(_ pattern: String, in session: ShellSession) async -> ShellSearch {
        let search = ShellSearch()
        search.open(from: nil, over: session.notes)
        await search.indexed()
        search.text = pattern
        search.settle(pattern)
        return search
    }

    private func found(_ search: ShellSearch, in session: ShellSession, latest: LatestDate? = nil) -> [String]? {
        session.searched(search, latest: latest)?.map(\.noteID)
    }

    private func shown(_ session: ShellSession, latest: LatestDate? = nil) -> [String] {
        session.timelineItems(latest: latest).map(\.noteID)
    }

    // MARK: Acceptance

    @Test("From Trends, only what Trends shows is found")
    func fromTrends() async {
        let session = session()
        session.timelineID = .trends
        let search = await searching("swift", in: session)
        #expect(found(search, in: session) == ["trend"])
        #expect(found(search, in: session) == shown(session))
    }

    @Test("From All, what All shows is found")
    func fromAll() async {
        let session = session()
        session.timelineID = .all
        let search = await searching("swift", in: session)
        #expect(found(search, in: session) == shown(session))
        #expect(found(search, in: session) == ["pub", "trend", "spoil", "board"])
    }

    @Test("From a written timeline, a post one of its rules keeps out is not found, however well it matches")
    func aRuleKeepsOut() async throws {
        let session = session()
        let mine = write("No spoilers", [try #require(Rule.keyword("spoiler", in: .every, effect: .exclude))], in: session)
        session.timelineID = mine
        let search = await searching("*spoil*", in: session)
        #expect(found(search, in: session) == [])
        search.text = "swift"
        search.settle("swift")
        #expect(found(search, in: session) == shown(session))
        #expect(found(search, in: session)?.contains("spoil") == false)
    }

    @Test("A written timeline's sources and categories hold for the search")
    func sourcesAndCategories() async throws {
        let session = session()
        let forumOnly = write("Forum", [try #require(Rule.source("f.example"))], in: session)
        let trendsOnly = write(
            "Trending", [try #require(Rule.category(.trends, in: .every, sources: []))], in: session
        )
        let search = await searching("swift", in: session)
        session.timelineID = forumOnly
        #expect(found(search, in: session) == ["board"])
        session.timelineID = trendsOnly
        #expect(found(search, in: session) == ["trend"])
    }

    @Test("The latest date, when set, still holds")
    func latestHolds() async {
        let session = session()
        session.timelineID = .all
        let latest = LatestDate("1970-01-01")!
        let late = latest.end().timeIntervalSince1970
        session.notes = [
            note("after", "Ada", "swift", at: late + 10),
            note("before", "Ada", "swift", at: late - 10),
            note("trend-before", "Bob", "swift", [.trends], at: late - 20),
        ]
        let search = await searching("swift", in: session)
        #expect(found(search, in: session, latest: latest) == ["before", "trend-before"])
        session.timelineID = .trends
        #expect(found(search, in: session, latest: latest) == ["trend-before"])
    }

    @Test("Switching timeline with the search open searches the new one, with the pattern kept")
    func switchingReSearches() async throws {
        let session = session()
        let mine = write("No spoilers", [try #require(Rule.keyword("spoiler", in: .every, effect: .exclude))], in: session)
        session.timelineID = .all
        let search = await searching("swift", in: session)
        #expect(found(search, in: session)?.count == 4)
        session.timelineID = .trends
        #expect(search.text == "swift")
        #expect(found(search, in: session) == ["trend"])
        session.timelineID = mine
        #expect(found(search, in: session) == ["pub", "trend", "board"])
        session.timelineID = .all
        #expect(found(search, in: session)?.count == 4)
    }

    @Test("Closed, the search finds nothing and the timeline is drawn as it was")
    func closedIsNothing() async {
        let session = session()
        session.timelineID = .trends
        let search = await searching("swift", in: session)
        _ = search.close()
        #expect(session.searched(search, latest: nil) == nil)
    }

    // MARK: Saying which timeline

    @Test("A search that finds nothing says which timeline it looked in, in both languages")
    func theEmptyNoticeNamesTheTimeline() throws {
        let session = session()
        let mine = write("No spoilers", [], in: session)
        for language in [DummyLanguage.english, .taiwanese] {
            for (query, name) in [
                (TimelineQuery.all, L10n.t("timeline.tab.all", language: language)),
                (.trends, L10n.t("timeline.tab.trends", language: language)),
                (mine, "No spoilers"),
            ] {
                let notice = EmptyNotice.timeline(
                    searching: true, indexed: true, query: query, notes: session.notes, written: session.written,
                    sources: session.sources, index: TextIndex([]), latest: nil, asked: true, language: language
                )
                #expect(notice.kind == .search)
                #expect(notice.title.contains(name), "\(notice.title) \(language)")
                #expect(notice.spoken.contains(name))
            }
        }
    }

    @Test("The field's words name the timeline, in both languages")
    func theFieldNamesTheTimeline() {
        for language in [DummyLanguage.english, .taiwanese] {
            for key in ["search.placeholder", "search.label", "search.empty.title"] {
                let words = L10n.t(key, language: language)
                #expect(words.components(separatedBy: "%@").count == 2, "\(key) \(language)")
                #expect(String(format: words, "Trends").contains("Trends"))
            }
        }
    }

    @Test("A timeline's name is the tab's word, and a deleted one's is All's")
    func names() {
        let session = session()
        let mine = write("Mine", [], in: session)
        #expect(session.name(of: .all) == L10n.t("timeline.tab.all"))
        #expect(session.name(of: .trends) == L10n.t("timeline.tab.trends"))
        #expect(session.name(of: mine) == "Mine")
        #expect(session.name(of: .written(UUID())) == L10n.t("timeline.tab.all"))
    }
}

/// Defaults whose values live in this object only: nothing reaches `cfprefsd` or the disk.
private final class SearchDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
