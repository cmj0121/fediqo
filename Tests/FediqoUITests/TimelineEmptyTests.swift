import Foundation
import FediqoCore
import Testing
@testable import FediqoUI

/// #68 — nothing to show reads as empty, and is never mistaken for still waiting.
///
/// What is assertable without a screen is the copy the place speaks, that empty is not
/// arriving and not failed, that a timeline the rules emptied names that rule, and that
/// a search miss is not the timeline's empty. The suite is `@MainActor` for the reason
/// `WaitingTests` is: what it reads belongs to a `View`.
@Suite("Nothing to show reads as empty")
@MainActor
struct TimelineEmptyTests {
    private let source = Source(host: "one.example", kind: .mastodon)

    private func note(
        _ id: String,
        body: String = "hello",
        _ categories: Set<FediqoCore.Category> = [.public],
        at postedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada@one.example", body: body,
            postedAt: postedAt, categories: categories
        )
    }

    private func empty(
        searching: Bool = false,
        indexed: Bool = true,
        query: TimelineQuery = .all,
        notes: [Note] = [],
        written: [TimelineDefinition] = [],
        sources: [Source]? = nil,
        latest: LatestDate? = nil,
        asked: Bool = false,
        language: DummyLanguage = .english
    ) -> EmptyNotice {
        let sources = sources ?? (notes.isEmpty ? [] : [source])
        return EmptyNotice.timeline(
            searching: searching,
            indexed: indexed,
            query: query,
            notes: notes,
            written: written,
            sources: sources,
            index: TextIndex(notes),
            latest: latest,
            asked: asked,
            language: language
        )
    }

    /// The stream is rows or this notice, and nothing else: which is decided by whether there
    /// are rows alone. Empty is not a wait, and not a miss: those are the toast — so the notice
    /// a running reload, a finished one and a missed one leave is never either.
    @Test("Empty is not arriving and not failed")
    func emptyIsNotArrivingOrFailed() {
        for asked in [false, true] {
            let place = empty(sources: [source], asked: asked)
            #expect(place.spoken != ShellWaiting.spoken)
            #expect(place.title != ShellFailure.spoken(["one.example"]))
        }

        let notice = empty(sources: [source])
        #expect(notice.kind == .held)
        #expect(notice.spoken != ShellWaiting.spoken)
        #expect(notice.title != ShellWaiting.spoken)
        #expect(notice.title != ShellFailure.spoken(["one.example"]))
        #expect(!notice.spoken.contains(ShellFailure.retryName))
        #expect(notice.fills)
    }

    /// A pattern that matched nothing is the search's empty, not the timeline's, and not
    /// the indexing notice the fold still uses.
    @Test("An empty search is not the timeline's empty")
    func emptySearchIsNotTimelineEmpty() {
        let indexing = empty(searching: true, indexed: false, sources: [source])
        let search = empty(searching: true, indexed: true, sources: [source])
        let held = empty(sources: [source])
        #expect(indexing.kind == .indexing)
        #expect(search.kind == .search)
        #expect(held.kind == .held)
        #expect(search.title != held.title)
        #expect(search.detail != held.detail)
        #expect(search.symbol == "magnifyingglass")
        #expect(held.symbol == "list.bullet.rectangle")
        #expect(indexing.title != search.title)
        #expect(search.spoken != ShellWaiting.spoken)
        #expect(search.title != ShellFailure.spoken(["one.example"]))
    }

    /// Sources here, nothing kept, no reload of this session finished: not "answered",
    /// and not a wait.
    @Test("Nothing held yet is not answered with nothing")
    func nothingHeldYetIsNotAnswered() {
        let held = empty(sources: [source], asked: false)
        let answered = empty(sources: [source], asked: true)
        let none = empty(sources: [])
        #expect(held.kind == .held)
        #expect(answered.kind == .answered)
        #expect(none.kind == .noSources)
        #expect(held.title != answered.title)
        #expect(held.detail != answered.detail)
        #expect(none.title != held.title)
        #expect(answered.spoken.contains("asked") || answered.detail.contains("asked"))
        #expect(
            L10n.t("timeline.empty.held.detail", language: .english)
                == "This device has not kept a note from your sources. Add a source on Account, or reload to ask them."
        )
        #expect(!held.detail.contains("press r"))
        #expect(held.detail.contains("reload"))
        #expect(
            !L10n.t("timeline.empty.held.detail", language: .taiwanese).contains("按 r")
        )
        #expect(
            L10n.t("timeline.empty.held.detail", language: .taiwanese).contains("重新載入")
        )
    }

    /// Trends keeps its own words; an answered Trends is still trending-empty, not All's
    /// "nothing came back".
    @Test("An empty Trends is not an empty All")
    func emptyTrendsIsNotEmptyAll() {
        let allHeld = empty(query: .all, sources: [source])
        let trendsHeld = empty(query: .trends, sources: [source])
        let trendsAsked = empty(query: .trends, sources: [source], asked: true)
        #expect(allHeld.title != trendsHeld.title)
        #expect(trendsHeld.kind == .held)
        #expect(trendsAsked.kind == .answered)
        #expect(trendsHeld.title == trendsAsked.title)
        #expect(trendsAsked.detail != trendsHeld.detail)
        #expect(trendsAsked.title != allHeld.title)
    }

    /// The store has notes; this query shows none; the notice names that rule's id and
    /// speaks the hide's own words.
    @Test("A timeline the rules emptied names that rule")
    func rulesEmptiedNamesTheRule() {
        let hide = Rule.keyword("hello", in: .every, effect: .exclude)!
        let id = UUID()
        let definition = TimelineDefinition(id: id, name: "Mine", rules: [hide])
        let notes = [note("a1", body: "hello there")]
        let notice = empty(
            query: .written(id), notes: notes, written: [definition], sources: [source]
        )
        #expect(notice.kind == .rules(hide.id))
        #expect(notice.ruleID == hide.id)
        #expect(notice.detail.contains("hello"))
        #expect(notice.spoken.contains("hello"))
        #expect(notice.title != empty(sources: [source]).title)
        #expect(notice.title != empty(searching: true, indexed: true, sources: [source]).title)

        let include = Rule.keyword("nomatch", in: .every)!
        let other = TimelineDefinition(id: id, name: "Mine", rules: [include])
        let missed = empty(
            query: .written(id), notes: notes, written: [other], sources: [source]
        )
        #expect(missed.kind == .rules(include.id))
        #expect(missed.ruleID == include.id)
        #expect(missed.detail.contains("nomatch"))
    }

    /// Trends with notes that are not trending names the trends rule, in Trends' own title.
    @Test("Trends emptied by its rule still names that rule")
    func trendsEmptiedNamesTheTrendsRule() throws {
        let notes = [note("a1")]
        let notice = empty(query: .trends, notes: notes, sources: [source])
        let rule = try #require(TimelineDefinition.trends.rules.first)
        #expect(notice.kind == .rules(rule.id))
        #expect(notice.ruleID == rule.id)
        #expect(notice.title == L10n.t("timeline.empty.trends.title", language: .english))
        #expect(notice.spoken != empty(query: .trends, sources: [source]).spoken)
    }

    /// Notes the rules would let through, all newer than the latest date, say that is why.
    @Test("A latest date that lets nothing through says so")
    func latestDateEmptyNamesTheCut() throws {
        let notes = [note("a1")]
        let latest = try #require(LatestDate("2020-01-01"))
        let notice = empty(notes: notes, sources: [source], latest: latest)
        #expect(notice.kind == .latest)
        #expect(notice.ruleID == nil)
        #expect(notice.title != empty(sources: [source]).title)
    }

    /// A thread with nothing under it has its own words, not the timeline's, and is not
    /// drawn while the replies are still on the wire. A miss is the toast, so it does
    /// not suppress this notice.
    @Test("An empty thread is not the timeline's empty")
    func emptyThreadIsNotTimelineEmpty() {
        let none = EmptyNotice.thread(
            descendantCount: 0, replyCount: 0, standing: ForumRepliesStanding.none
        )
        let zero = EmptyNotice.thread(
            descendantCount: 0, replyCount: 0, standing: nil
        )
        let timeline = empty(sources: [source])
        #expect(none?.kind == .thread)
        #expect(zero?.kind == .thread)
        #expect(none?.fills == false)
        #expect(none?.title == L10n.t("thread.replies.none", language: .english))
        #expect(zero?.title == L10n.t("thread.empty.title", language: .english))
        #expect(zero?.title != timeline.title)
        #expect(none?.title != timeline.title)
        #expect(none?.symbol != timeline.symbol)
        #expect(none?.spoken != ShellWaiting.spoken)
        #expect(none?.title != ShellFailure.spoken(["one.example"]))
        #expect(none?.spoken.contains(none?.detail ?? "") == true)

        #expect(EmptyNotice.thread(
            descendantCount: 0, replyCount: 3, standing: nil
        ) == nil)
        #expect(EmptyNotice.thread(
            descendantCount: 0, replyCount: nil, standing: nil
        ) == nil)
        #expect(EmptyNotice.thread(
            descendantCount: 1, replyCount: 0, standing: nil
        ) == nil)
        #expect(EmptyNotice.thread(
            descendantCount: 0, replyCount: 0, standing: .coming
        ) == nil)
        #expect(EmptyNotice.thread(
            descendantCount: 0, replyCount: 0, standing: .unasked
        ) == nil)
        #expect(EmptyNotice.thread(
            descendantCount: 0, replyCount: 0, standing: .absent(.unreachable)
        ) == nil)
    }

    /// VoiceOver is owed the empty case in both languages, and the two Chinese files
    /// stay the same bytes.
    @Test("VoiceOver can read the empty case, translated")
    func voiceOverReadsEmptyInBothLanguages() throws {
        let keys = [
            "timeline.empty.title", "timeline.empty.detail",
            "timeline.empty.held.title", "timeline.empty.held.detail",
            "timeline.empty.answered.title", "timeline.empty.answered.detail",
            "timeline.empty.rules.title", "timeline.empty.rules.detail",
            "timeline.empty.latest.title", "timeline.empty.latest.detail",
            "timeline.empty.trends.title", "timeline.empty.trends.detail",
            "timeline.empty.trends.answered.detail",
            "search.empty.title", "search.empty.detail",
            "search.indexing.title", "search.indexing.detail",
            "thread.empty.title", "thread.empty.detail",
            "thread.replies.none",
        ]
        for language in [DummyLanguage.english, .taiwanese] {
            for key in keys {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
            let held = empty(sources: [source], language: language)
            #expect(!held.spoken.isEmpty)
            #expect(held.spoken.contains(held.title))
            #expect(held.spoken.contains(held.detail))
        }
        #expect(
            L10n.t("timeline.empty.held.title", language: .english)
                != L10n.t("timeline.empty.held.title", language: .taiwanese)
        )
        #expect(
            L10n.t("thread.empty.title", language: .english)
                != L10n.t("thread.empty.title", language: .taiwanese)
        )

        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        let tw = try Data(contentsOf: resources.appendingPathComponent("zh-TW.lproj/Localizable.strings"))
        let hant = try Data(contentsOf: resources.appendingPathComponent("zh-Hant.lproj/Localizable.strings"))
        #expect(tw == hant)
    }
}
