import Testing
@testable import FediqoCore
@testable import FediqoUI

@MainActor
@Suite("A list's explaining sentence leaves its foot (#402)")
struct ListFeetTests {
    @Test("A marks timeline's order is a (?), and nothing where the timeline reads no marks")
    func marksOrderIsAHelp() {
        #expect(TimelineStatus.marksKey(readsMarks: true) == "timeline.marks.order")
        #expect(TimelineStatus.marksKey(readsMarks: false) == nil)
        let said = L10n.t("timeline.marks.order", language: .english)
        #expect(said.contains("published") && !said.contains("timeline.marks"))
        #expect(L10n.t("timeline.marks.order", language: .taiwanese) != "timeline.marks.order")
    }

    @Test("A Trends source with nothing more is one counted line, and Again reads from the top")
    func trendsEndedIsAStatusLine() {
        var read = 0
        let lines = TimelineStatus.ended(["a.example", "b.example"], reload: { read += 1 }, language: .english)
        #expect(lines.map(\.host) == ["a.example", "b.example"])
        #expect(lines.allSatisfy { $0.needsReader && $0.standsOut && $0.press?.kind == .again })
        #expect(StatusWords.count(lines) == 2)
        #expect(lines[0].words == ShellReload.trendsEndLine(["a.example"], language: .english))
        #expect(!lines[0].words.contains("b.example"))
        lines[0].press?.act()
        #expect(read == 1)
        #expect(TimelineStatus.ended([], reload: {}).isEmpty)
        let chinese = TimelineStatus.ended(["a.example"], reload: {}, language: .taiwanese)
        #expect(chinese.first?.words.contains("a.example") == true)
        #expect(chinese.first?.words != lines[0].words)
    }

    @Test("A timeline the reader wrote with a Trends rule names a source that has ended")
    func aWrittenTrendsRuleEnds() throws {
        let host = "a.example"
        let beside = "b.example"
        let session = ShellSession(http: FixtureHTTP())
        let sources = [Source(host: host, kind: .mastodon), Source(host: beside, kind: .mastodon)]
        session.sources = sources
        let rising = try #require(Rule.category(.trends, in: .source(host: host), sources: sources))
        let timeline = TimelineDefinition(name: "Rising", rules: [rising])
        let plain = try #require(Rule.category(.public, in: .source(host: host), sources: sources))
        let publicOnly = TimelineDefinition(name: "Public", rules: [plain])
        session.written = [timeline, publicOnly]
        for ended in [host, beside] {
            session.reload.stretches.readTrends(
                Stretch(host: ended, category: .trends),
                from: 0, brought: [], of: MastodonClient.trendsStretch
            )
        }
        session.reload.noteTrendsEnded()

        let ended = session.reload.trendsEnded(of: .written(timeline.id), in: session)
        #expect(ended == [host], "the rule names one source, and that source has ended")
        let lines = TimelineStatus.ended(ended, reload: {}, language: .english)
        #expect(lines.map(\.host) == [host])
        #expect(lines.first?.needsReader == true && lines.first?.press?.kind == .again)
        #expect(session.reload.trendsEnded(of: .written(publicOnly.id), in: session).isEmpty)
        #expect(session.reload.trendsEnded(of: .all, in: session).isEmpty)
    }
}
