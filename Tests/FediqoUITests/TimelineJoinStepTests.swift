import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #372: the join's last step — the timelines already written that a source just joined can take
/// it — reached from each way a join ends, and drawn.
@MainActor
@Suite("The timelines a joined source can join, as the join's last step", .watched)
struct TimelineJoinStepTests {
    private static let a = "a.example"
    private static let y = "first.example"
    private static let forum = "install-c.example"

    init() {
        L10n.language = .english
    }

    private static let mastodonRoutes: [String: FixtureHTTP.Outcome] = [
        "/": .text(#"""
        <html><head><meta name="application-name" content="Mastodon"></head><body></body></html>
        """#),
        "/api/v2/instance": .text(#"{"domain": "first.example", "title": "First", "version": "4.3.1"}"#),
        "/api/v1/timelines/public": .text("[]"),
        "/api/v1/trends/statuses": .text("[]"),
    ]

    /// A timeline written before the source came: A's public, by a source group and a category group.
    private static func onlyA(_ name: String = "Mine") -> TimelineDefinition {
        let sources = [Source(host: a, kind: .mastodon)]
        return TimelineDefinition(name: name, rules: [
            Rule.source(a)!, Rule.category(.public, in: .source(host: a), sources: sources)!,
        ])
    }

    /// A Mastodon joined from the field, with `written` the timelines already written.
    private func joined(_ written: [TimelineDefinition]) async -> ShellSession {
        let session = ShellSession(http: FixtureHTTP(Self.mastodonRoutes), store: ItemStore())
        session.written = written
        session.hostname = Self.y
        await session.add()
        await session.confirm()
        return session
    }

    private func chooser(_ session: ShellSession) -> TimelineJoinChoice? {
        guard case .joiningTimelines(let choice) = session.stage else { return nil }
        return choice
    }

    // MARK: - Each way a join ends

    @Test("A join with a timeline to take it lands on the step, its divisions offered, nothing ticked")
    func joinReachesTheStep() async throws {
        let mine = Self.onlyA()
        let session = await joined([mine])
        #expect(session.isAdded(Self.y))
        let choice = try #require(chooser(session), "the sheet closed instead of offering the timeline")
        #expect(choice.host == Self.y)
        #expect(choice.offers.map(\.timeline) == [mine.id])
        #expect(choice.offers[0].divisions.map(\.category) == [.public])
        #expect(choice.labels[.public] == "Public")
        #expect(choice.ticked.isEmpty && choice.picks.isEmpty)
        #expect(session.stage?.surface == .sheet && session.stage?.id == "joiningTimelines:\(Self.y)")
    }

    @Test("A join with nothing to offer closes as before")
    func joinWithNothingCloses() async {
        let none = await joined([])
        #expect(none.isAdded(Self.y) && none.stage == nil)
        let whole = TimelineDefinition(name: "Everything", rules: [])
        let reached = await joined([whole])
        #expect(reached.isAdded(Self.y) && reached.stage == nil, "a timeline that reads every source has nothing to add")
    }

    @Test("Done applies what was ticked, through the timelines' own join, and the sheet comes down")
    func doneApplies() async throws {
        let mine = Self.onlyA()
        let session = await joined([mine])
        let offered = try #require(chooser(session))
        let expected = mine.joining(Self.y, categories: [.public], sources: session.sources)
        #expect(expected != mine, "the premise: joining adds to it")
        session.stage = .joiningTimelines(offered.ticking(.public, on: offered.offers[0]))
        await session.chooseTimelines()
        #expect(session.stage == nil)
        let shape = { (timeline: TimelineDefinition) in timeline.rules.map { "\($0.effect) \($0.kind)" } }
        #expect(session.written.map(\.id) == [mine.id])
        #expect(session.written.map(shape) == [shape(expected)])
    }

    @Test("Done with nothing ticked, Cancel, or a swipe change nothing")
    func noneChangesNothing() async throws {
        let mine = Self.onlyA()
        let done = await joined([mine])
        #expect(chooser(done) != nil)
        await done.chooseTimelines()
        #expect(done.stage == nil && done.written == [mine])

        let cancelled = await joined([mine])
        #expect(JoinSheet.leading(for: cancelled.stage) == .cancel)
        JoinSheet.press(.cancel, on: cancelled)
        #expect(cancelled.stage == nil && cancelled.written == [mine])

        let swiped = await joined([mine])
        swiped.sheetDismissed()
        #expect(swiped.stage == nil && swiped.written == [mine])
        await swiped.chooseTimelines()
        #expect(swiped.written == [mine], "Done after the sheet went does nothing")
    }

    @Test("A reader who dismissed mid-press never sees the step spring up")
    func dismissedMidPress() async {
        let http = GatedHTTP(Self.mastodonRoutes, holding: "/api/v1/timelines/public")
        let watchdog = watching(http.gate, "the join, held on the public timeline")
        defer { watchdog.cancel() }
        let session = ShellSession(http: http, store: ItemStore())
        session.written = [Self.onlyA()]
        session.hostname = Self.y
        await session.add()
        let press = Task { await session.confirm() }
        await met("the press is on the wire", by: press) { await http.reached }
        session.dismissStage()
        await http.gate.open()
        await press.value
        #expect(session.isAdded(Self.y), "the premise: the join went through")
        #expect(session.stage == nil, "the step sprang up behind a reader who left")
    }

    @Test("A reader who began another errand mid-press keeps it")
    func anotherErrandMidPress() async {
        let http = GatedHTTP(Self.mastodonRoutes, holding: "/api/v1/timelines/public")
        let watchdog = watching(http.gate, "the join, held on the public timeline")
        defer { watchdog.cancel() }
        let session = ShellSession(http: http, store: ItemStore())
        session.written = [Self.onlyA()]
        session.hostname = Self.y
        await session.add()
        let press = Task { await session.confirm() }
        await met("the press is on the wire", by: press) { await http.reached }
        session.dismissStage()
        session.stage = .browsing
        await http.gate.open()
        await press.value
        #expect(session.stage == .browsing)
    }

    // MARK: - Boards

    private static func forumHTTP(boardsAnswer: [Int: FixtureHTTP.Outcome]) -> FixtureHTTP {
        var routes: [String: FixtureHTTP.Outcome] = [
            "/": .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body></body></html>
            """#),
            "https://\(forum)/forum.php": .text(#"""
            <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
            <h2><a href="forum.php?gid=56">::工具区::</a></h2>
            <div id="category_56" class="bm_c">
            <dl><dt><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></dt>
            <dd><em>主题: 4207</em></dd></dl>
            <dl><dt><a href="forum.php?mod=forumdisplay&fid=41">虚拟机专区</a></dt>
            <dd><em>主题: 1854</em></dd></dl>
            </div></body></html>
            """#),
        ]
        for (fid, outcome) in boardsAnswer {
            routes["https://\(forum)/forum.php?mod=forumdisplay&fid=\(fid)&filter=author&orderby=dateline"] = outcome
        }
        return FixtureHTTP(routes)
    }

    private static let readBoard: FixtureHTTP.Outcome = .text(#"""
    <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
    <h1 class="xs2"><a href="forum.php?mod=forumdisplay&fid=33">启动盘工具</a></h1>
    <table id="threadlisttableid"><tbody id="normalthread_40125"><tr>
    <th class="common"><a href="forum.php?mod=viewthread&tid=40125" class="s xst">一键安装说明</a></th>
    <td class="by"><cite><a href="home.php?mod=space&uid=8">tinbox</a></cite><em>2026-9-15 13:12</em></td>
    </tr></tbody></table></body></html>
    """#)

    private static let unreadableBoard: FixtureHTTP.Outcome = .text(#"""
    <html><head><meta name="generator" content="Discuz! X5.0" /></head><body>
    <h1 class="xs2">最新回复</h1>
    <table cellspacing="0" cellpadding="0"></table>
    </body></html>
    """#)

    private func boardsJoined(_ answers: [Int: FixtureHTTP.Outcome], picking fids: [Int]) async -> ShellSession {
        let session = ShellSession(http: Self.forumHTTP(boardsAnswer: answers), store: ItemStore())
        session.written = [Self.onlyA()]
        session.hostname = Self.forum
        await session.add()
        await session.confirm()
        guard let offer = session.choosing?.offer else {
            Issue.record("a Discuz! should have paused")
            return session
        }
        await session.subscribe(offer.boards.filter { fids.contains($0.fid) })
        return session
    }

    @Test("Boards all read land on the step, the chosen board among what is offered")
    func boardsAllRead() async throws {
        let session = await boardsJoined([33: Self.readBoard], picking: [33])
        #expect(session.unread.isEmpty && session.isAdded(Self.forum))
        let choice = try #require(chooser(session))
        #expect(choice.offers.first?.divisions.map(\.category).contains(.board(id: "33")) == true)
        #expect(choice.labels[.board(id: "33")] == "启动盘工具")
    }

    @Test("Boards some of which could not be read close as before, the sentence about them left on the page")
    func boardsPartlyRead() async {
        let session = await boardsJoined([33: Self.readBoard, 41: Self.unreadableBoard], picking: [33, 41])
        #expect(session.unread.map(\.board.fid) == [41], "the premise: one board went unread")
        #expect(session.stage == nil)
    }

    // MARK: - The source's page

    @Test("The source's page opens the same chooser, from no stage or its own page, and nothing where nothing is offered")
    func fromThePage() async {
        let session = await joined([])
        #expect(session.stage == nil)
        session.openTimelineJoin(host: Self.y)
        #expect(session.stage == nil, "nothing offered opens nothing")

        session.written = [Self.onlyA()]
        session.browse()
        session.openTimelineJoin(host: Self.y)
        #expect(session.stage == .browsing, "another errand is not taken over")
        session.dismissStage()

        session.openSource(host: Self.y)
        session.openTimelineJoin(host: Self.y.uppercased())
        #expect(chooser(session)?.host == Self.y)
        session.dismissStage()
        session.openTimelineJoin(host: Self.y)
        #expect(chooser(session)?.host == Self.y)
    }

    // MARK: - The stage

    @Test("The step is a sheet that goes with the window, Cancel behind it, and holds no board ticks")
    func theStage() throws {
        let offer = TimelineJoinOffer(
            timeline: Self.onlyA().id, name: "Mine", divisions: [TimelineJoinDivision(category: .public, locked: false)],
            addsSource: true, joinsAsIs: false
        )
        let stage = JoinStage.joiningTimelines(try #require(TimelineJoinChoice(host: Self.y, offers: [offer], sources: [])))
        #expect(stage.closesWhenTheWindowLeaves && stage.surface == .sheet && !stage.admitsASecondLook)
        #expect(stage.host == Self.y && stage.ticked.isEmpty && stage.ticking([1]) == stage && stage.inlinePreview == nil)
        #expect(JoinSheet.leading(for: stage) == .cancel)
        #expect(JoinSheet.head(for: stage)?.title == "Timelines")
        #expect(TimelineJoinChoice(host: Self.y, offers: [], sources: []) == nil)
    }

    @Test("A locked division is ticked and does not move; picks take it out; as-is joins with nothing new")
    func ticking() throws {
        let asIs = TimelineJoinOffer(
            timeline: TimelineID(), name: "Home and A",
            divisions: [TimelineJoinDivision(category: .home, locked: true), TimelineJoinDivision(category: .public, locked: false)],
            addsSource: true, joinsAsIs: true
        )
        let divided = TimelineJoinOffer(
            timeline: TimelineID(), name: "Mine", divisions: [TimelineJoinDivision(category: .public, locked: false)],
            addsSource: false, joinsAsIs: false
        )
        let whole = TimelineJoinOffer(timeline: TimelineID(), name: "Friends", divisions: [], addsSource: true, joinsAsIs: true)
        var choice = try #require(TimelineJoinChoice(host: Self.y, offers: [asIs, divided, whole], sources: []))
        #expect(choice.isTicked(.home, on: asIs) && !choice.isTicked(.public, on: asIs))
        #expect(choice.ticking(.home, on: asIs) == choice, "a locked division does not move")

        choice = choice.ticking(.public, on: divided)
        #expect(choice.picks == [divided.timeline: [.public]])
        choice = choice.ticking(.public, on: divided)
        #expect(choice.picks.isEmpty, "the last division unticked takes the timeline out")
        #expect(choice.tickingAsIs(divided) == choice, "a timeline that cannot join as it is has no such row")

        choice = choice.tickingAsIs(asIs).tickingAsIs(whole)
        #expect(choice.picks == [asIs.timeline: [], whole.timeline: []])
        #expect(choice.joinsAsIs(asIs) && choice.joinsAsIs(whole))
        choice.ticked[asIs.timeline] = [.home]
        #expect(choice.picks[asIs.timeline] == [], "a locked division is never handed on")
        choice = choice.tickingAsIs(whole)
        #expect(choice.picks[whole.timeline] == nil)
    }

    @Test("Joining as it is and joining with a new division are distinct choices, drawn on distinct rows")
    func asIsAndDivisionsAreDistinct() throws {
        let asIs = TimelineJoinOffer(
            timeline: TimelineID(), name: "Home and A",
            divisions: [TimelineJoinDivision(category: .home, locked: true), TimelineJoinDivision(category: .public, locked: false)],
            addsSource: true, joinsAsIs: true
        )
        var choice = try #require(TimelineJoinChoice(host: Self.y, offers: [asIs], sources: []))
        #expect(!choice.joinsAsIs(asIs))

        choice = choice.ticking(.public, on: asIs)
        #expect(choice.isTicked(.public, on: asIs) && !choice.joinsAsIs(asIs), "a division ticked does not tick as-is")
        #expect(choice.picks == [asIs.timeline: [.public]])

        choice = choice.tickingAsIs(asIs)
        #expect(choice.joinsAsIs(asIs) && !choice.isTicked(.public, on: asIs), "as-is chosen lets the new division go")
        #expect(choice.isTicked(.home, on: asIs), "what is already on stays ticked")
        #expect(choice.picks == [asIs.timeline: []])

        choice = choice.ticking(.public, on: asIs)
        #expect(!choice.joinsAsIs(asIs) && choice.isTicked(.public, on: asIs), "a division ticked after as-is takes its place")
        choice = choice.ticking(.public, on: asIs)
        #expect(!choice.joinsAsIs(asIs) && choice.picks.isEmpty, "the last division unticked chooses nothing, not as-is")
    }

    // MARK: - Drawn

    private static func drawnChoice() -> TimelineJoinChoice {
        let offers = [
            TimelineJoinOffer(
                timeline: TimelineID(), name: "Everything I read in the morning, before the news",
                divisions: [
                    TimelineJoinDivision(category: .home, locked: true),
                    TimelineJoinDivision(category: .public, locked: false),
                    TimelineJoinDivision(category: .list(id: "1"), locked: false),
                ],
                addsSource: true, joinsAsIs: true
            ),
            TimelineJoinOffer(timeline: TimelineID(), name: "Friends", divisions: [], addsSource: true, joinsAsIs: true),
        ]
        var choice = TimelineJoinChoice(host: "a-rather-long-host-name.example", offers: offers, sources: [])!
        choice = choice.ticking(.public, on: offers[0])
        return choice
    }

    @Test("The chooser lays out at 420, 390 and 320 at the largest text, in light and in dark, no wider than its room", arguments: 0..<2)
    func laidOut(_ dark: Int) {
        let scheme = HostedFit.scheme(dark)
        for (width, size) in HostedFit.rooms {
            let list = TimelineJoinList(choice: .constant(Self.drawnChoice()))
            #expect(HostedFit.fits(list, width: width, height: 900, scheme: scheme, size: size), "at \(width)")
        }
    }

    @Test("The whole sheet at the step lays out in light and in dark", arguments: 0..<2)
    func sheetLaidOut(_ dark: Int) {
        let session = ShellSession(http: FixtureHTTP())
        session.stage = .joiningTimelines(Self.drawnChoice())
        for (width, size) in HostedFit.rooms {
            #expect(HostedFit.fits(JoinSheet(session: session), width: width, height: 900, scheme: HostedFit.scheme(dark), size: size))
        }
    }

    /// No view inspector, so what VoiceOver reads is pinned by what the file draws: each row says
    /// what it adds and to which timeline, a locked one says it is already in, and the rest say
    /// what a press does.
    @Test("Each row says what it adds and where, out loud")
    func spoken() throws {
        let file = try ShellSource.shell("TimelineJoinList")
        #expect(file.contains(".accessibilityLabel(Text(Self.spoken(name, in: offer)))"))
        #expect(file.contains(#".accessibilityValue(Text(locked ? L10n.t("timeline.join.locked") : ""))"#))
        #expect(file.contains(".accessibilityAddTraits(on ? [.isSelected] : [])"))
        #expect(file.contains(".disabled(locked)"))
        let offer = Self.drawnChoice().offers[1]
        #expect(TimelineJoinList.spoken("Public", in: offer, language: .english) == "Public, in Friends")
        #expect(TimelineJoinList.asIsName(offer, host: Self.y, language: .english) == "All of first.example")
        #expect(TimelineJoinList.spoken("公開", in: offer, language: .taiwanese) == "公開，在 Friends")
    }

    @Test("Every sentence the step says is in every language")
    func sentences() {
        let keys = [
            "timeline.join.title", "timeline.join.timelines", "timeline.join.line", "timeline.join.detail",
            "timeline.join.done", "timeline.join.whole", "timeline.join.asIs", "timeline.join.spoken",
            "timeline.join.locked", "timeline.join.hint.on", "timeline.join.hint.off",
        ]
        for key in keys {
            for language in DummyLanguage.allCases {
                let said = L10n.t(key, language: language)
                #expect(said != key && !said.isEmpty, "\(key) is missing in \(language)")
            }
        }
    }
}
