import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// F10, a list of people opened on its own — the directory, the people suggested, who asks to
/// follow the reader, the people a search found: a page of its own in the frame every opened
/// page stands in, with no tabs, no timelines' head over it, a bar that holds the way back and
/// the mark that asks the source again, the source's count only where it gave one and while it
/// holds, and Tab that turns nothing.
///
/// **No check here waits on anything but the call it makes**: each hosts a view and lays it
/// out, asks a value, or awaits an ask the server answers at once.
@MainActor
@Suite("A list of people's page", .watched)
struct PeoplePageTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let directory = PeopleList(directoryAt: host)
    private static let suggested = PeopleList(suggestedAt: host)
    private static let requests = PeopleList(requestsAt: host)
    private static let found = PeopleList(foundAt: host, words: "cats")
    private static let followers = PeopleList(.followers, of: Person(
        source: source, accountID: "42", handle: "@ada@m.example", name: "Ada", tally: Person.Tally(followers: 2811)
    ))
    private static let given = (0..<3).map {
        Person(source: source, accountID: "\($0)", handle: "@p\($0)@m.example", name: "P\($0)", words: "Says \($0)")
    }

    // MARK: - What the page says

    @Test("The source's count is the head's figure — a glyph and the number, opening nothing, its sentence its name — only where the source gave one: never as nought, and never on a list nobody counts; the source is heard once in the head")
    func theFigureIsTheSourcesOnly() throws {
        let en = DummyLanguage.english
        var asking = PeopleSaid(list: Self.requests, signedIn: true, own: true, reading: .said, people: Self.given)
        asking.tally = 1204
        let figure = try #require(asking.figure(language: en))
        // Said as the way to the list says it: the title already names the source.
        #expect(figure.symbol == "person.2" && figure.figure == "1,204" && figure.spoken == "1,204 people ask to follow you")
        #expect(!figure.opens && !figure.lit, "it opens nothing, and is never lit")
        #expect(asking.figure(language: .taiwanese)?.spoken == "1,204 人請求跟隨你")
        #expect(PeopleSaid.title(Self.requests, language: en) == "Who asks to follow you at m.example")
        // The pill is not said again where the title names the source; a list of somebody's names whose it is.
        for list in [Self.requests, Self.directory, Self.suggested, Self.found] {
            #expect(PeopleSaid.titleNamesHost(list), "\(list.which)")
        }
        #expect(!PeopleSaid.titleNamesHost(Self.followers))
        #expect(PeopleSaid(list: Self.followers).figure(language: en)?.spoken == "m.example counts 2,811")
        // Nothing said, or nought: no figure — the rows say who is there.
        for tally in [nil, 0] as [Int?] {
            var said = asking
            said.tally = tally
            #expect(said.counted == nil && said.figure() == nil, "\(String(describing: tally))")
        }
        // The lists nobody counts have none; a list somebody's source counted has its own.
        for list in [Self.directory, Self.suggested, Self.found] {
            #expect(PeopleSaid(list: list, reading: .said, people: Self.given).figure() == nil, "\(list.which)")
        }
        #expect(PeopleSaid(list: Self.followers).figure(language: en)?.figure == "2,811")
    }

    @Test("Under the title a directory says how it is read; a list its source counts has no sentence, its figure says it — and the people a search found have none, the head of the page of what it found says what it was asked")
    func theLineUnderTheTitle() {
        let en = DummyLanguage.english
        let choice = DirectoryChoice(order: .new, localOnly: true)
        let directory = PeopleSaid(list: Self.directory, sorting: choice)
        #expect(directory.sorting.map { PeopleSaid.sortingLine($0, source: directory.source, language: en) } == PeopleSaid.sortingLine(choice, source: Self.host, language: en))
        for list in [Self.suggested, Self.requests, Self.followers, Self.found] {
            let said = PeopleSaid(list: list)
            #expect(said.sorting.map { PeopleSaid.sortingLine($0, source: said.source, language: en) } == nil, "\(list.which)")
        }
    }

    @Test("The bar's mark asks the list's source again, named by it, where `r` would ask; with nobody to ask there is no mark, not a dim one")
    func theBarsMark() {
        let said = PeopleSaid(list: Self.directory)
        #expect(PeoplePane.reloadName(of: said, canReload: true, language: .english) == "Ask m.example again")
        #expect(PeoplePane.reloadName(of: said, canReload: true, language: .taiwanese) == "再問 m.example 一次")
        #expect(PeoplePane.reloadName(of: said, canReload: false) == nil)
        // `r` and the mark are one answer: the root's, for a list in front.
        for asked in [true, false] {
            #expect(FediqoRootView.canReload(place: .timeline, editing: false, hasSources: true, open: [.people, .selection], personAsked: asked) == asked)
        }
    }

    @Test("The press beside a list its source says it has not is called by its words, as Voice Control hears them, and tells a listener after them whom it asks — and a failure has none: it is the toast's")
    func thePressBesideAnAbsentList() {
        let absent = PeopleRows<EmptyView>.again(PeopleSaid(list: Self.directory, reading: .absent), language: .english)
        #expect(absent.words == "Ask again" && absent.hint == "Ask m.example again")
        let tw = PeopleRows<EmptyView>.again(PeopleSaid(list: Self.directory, reading: .absent), language: .taiwanese)
        #expect(tw.words == L10n.t("source.more.again", language: .taiwanese) && tw.hint == "再問 m.example 一次")
        #expect(!PeopleSaid(list: Self.found, reading: .failed).offersAgain && PeopleSaid(list: Self.found, reading: .failed).stateLine() == nil)
    }

    @Test("Who asks to follow the reader is counted as the sign-in's own check last said, while that holds: it stands while nobody is answered here, and is gone — not counted down — once one is, read from the top again or not")
    func theRequestsFigureIsTheChecks() async throws {
        let check = PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me","source":{"note":"","follow_requests_count":3}}"#)
        let person = { (id: Int) in #"{"id":"\#(id)","acct":"p\#(id)","display_name":"Person \#(id)"}"# }
        let standing = { (id: Int, by: Bool) in
            #"{"id":"\#(id)","following":false,"followed_by":\#(by),"blocking":false,"blocked_by":false,"muting":false,"requested":false,"domain_blocking":false}"#
        }
        let server = PageServer([
            "/api/v1/accounts/verify_credentials": check,
            "/api/v1/follow_requests?limit=80": PageServer.Answer(body: "[" + person(3) + "," + person(4) + "]"),
            "/api/v1/accounts/relationships?id%5B%5D=3&id%5B%5D=4": PageServer.Answer(body: "[" + standing(3, false) + "," + standing(4, false) + "]"),
            "/api/v1/follow_requests/3/authorize": PageServer.Answer(body: standing(3, true)),
        ])
        let session = ShellSession(http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server))
        session.work = SourceWork()
        await session.store.add(Self.source)
        session.sources = await session.store.sources()
        let pages = ShellPersonPages()
        #expect(pages.lists.said(of: Self.requests, in: session) == nil, "nobody signed in: no such list")
        let scopes = "read:statuses read:accounts read:follows write:follows"
        try session.mastodon.tokens.save(MastodonToken(
            host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: scopes, asked: scopes
        ))
        session.mastodon.refresh()
        await session.mastodon.learnWho(host: Self.host)
        let said = try #require(pages.lists.said(of: Self.requests, in: session))
        #expect(said.tally == 3 && said.figure(language: .english)?.figure == "3")
        // The directory beside it counts nobody, whoever is signed in.
        #expect(pages.lists.said(of: Self.directory, in: session)?.figure() == nil)

        // Read, with nobody answered: the figure stands.
        await pages.lists.opened(Self.requests, in: session)
        let listed = try #require(pages.lists.said(of: Self.requests, in: session))
        #expect(listed.people.map(\.accountID) == ["3", "4"] && listed.figure()?.figure == "3")
        // One accepted here: what the check counted no longer holds.
        await pages.lists.press(.acceptRequest, on: listed.people[0], of: Self.requests, in: session)
        let answered = try #require(pages.lists.said(of: Self.requests, in: session))
        #expect(answered.people.map(\.accountID) == ["4"] && answered.tally == nil && answered.figure() == nil)
        await pages.lists.again(Self.requests, in: session)
        #expect(pages.lists.said(of: Self.requests, in: session)?.figure() == nil, "and not back for reading from the top")
        // Nor for the page let go and made again: the old figure is the host's, not the page's.
        pages.lists.forget(Self.requests)
        #expect(pages.lists.said(of: Self.requests, in: session)?.figure() == nil, "nor for the page made again")
        // The account check run again says its own figure, and that one stands.
        await server.answer("/api/v1/accounts/verify_credentials", PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me","source":{"note":"","follow_requests_count":1}}"#))
        await session.mastodon.learnWho(host: Self.host)
        #expect(pages.lists.said(of: Self.requests, in: session)?.figure(language: .english)?.figure == "1")
    }

    // MARK: - Where it stands

    @Test("With a list in front the timelines' head is not drawn and the swipe is the page's own — on its one tab, toward the trailing edge, it leaves; a list that cannot be drawn draws the stream under the timelines' head, left by the swipe as before")
    func theTimelinesHeadIsNotDrawn() async {
        let step = ShellStep.people(Self.directory)
        #expect(!TimelinePane.headDrawn(over: step) && TimelinePane.headDrawn(over: step, drawn: false))
        #expect(TimelinePane.page(step) == .tabbed && TimelinePane.page(step, drawn: false) == .opened)
        #expect(TimelineSwipe.means(touch: true, page: .tabbed, searching: false, listShown: false, editing: false) == nil, "the timeline's swipe is not heard on it")
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: SoleTab.tabs.count, leaves: true) == .beside)
        #expect(TimelineSwipe.tabStep(from: 0, count: SoleTab.tabs.count, step: -1, leaves: true) == .leave)
        #expect(TimelineSwipe.tabStep(from: 0, count: SoleTab.tabs.count, step: 1, leaves: true) == nil)

        // What is drawn is asked once, of the list as its page would be handed it.
        let session = ShellSession(http: FixtureHTTP([:]), store: ItemStore())
        for added in [Self.source, Self.forum] { await session.store.add(added) }
        session.sources = await session.store.sources()
        let pages = ShellPersonPages()
        let there = TimelinePane.drawn(step, of: pages, in: session)
        #expect(there.list?.list == Self.directory && there.drawn && there.root == nil)
        // At a source that says nobody's lists, and with nobody holding what sources say: the stream.
        let atForum = ShellStep.people(PeopleList(directoryAt: Self.forum.host))
        let gone = TimelinePane.drawn(atForum, of: pages, in: session)
        #expect(gone.list == nil && !gone.drawn && !TimelinePane.drawn(step, of: nil, in: session).drawn)
        #expect(TimelinePane.headDrawn(over: atForum, drawn: gone.drawn) && TimelinePane.page(atForum, drawn: gone.drawn) == .opened)
    }

    @Test("Tab on a list is the page's — taken, turning nothing — while the list is drawn and in front, nobody's while something covers it, and the timelines' over a list that cannot be drawn; Esc, q, Back and the swipe go one step back, the lamp on the row the list was taken from")
    func tabIsTakenAndLeavingIsOneStep() {
        var walk = ShellWalk()
        _ = walk.walk(to: .person(DummyPerson(handle: "@me@m.example", host: Self.host)!), from: "row-1")
        let opened = walk.walk(to: .people(Self.requests), from: Self.requests.id)
        #expect(opened)
        #expect(walk.tabKey == .sole(.people) && ShellStep.people(Self.found).tabKey == .sole(.people))
        #expect(FediqoRootView.stepTab(.sole(.people), drawn: true, open: [.people, .selection]) == .page)
        #expect(FediqoRootView.stepTab(.sole(.people), drawn: true, open: [.viewer, .people]) == .covered)
        #expect(FediqoRootView.stepTab(.sole(.people), drawn: true, open: [.shortcuts, .people]) == .covered)
        #expect(FediqoRootView.stepTab(.sole(.people), drawn: false, open: [.people]) == .timelines)
        #expect(FediqoRootView.stepTab(.sole(.thread), drawn: true, open: [.thread, .selection]) == .page)
        // `r`, its mark and a pull ask what Tab asks: over a list or a conversation that cannot
        // be drawn they are the stream's, as the timeline's are; over one drawn, the page's.
        func reloads(_ open: Set<DummyLayer>, asked: Bool) -> Bool {
            FediqoRootView.canReload(place: .timeline, editing: false, hasSources: true, open: open, personAsked: asked)
        }
        for step in [ShellStep.people(Self.requests), .thread("withdrawn")] {
            let undrawn = FediqoRootView.drawnLayers([step.layer, .selection], standing: step, drawn: false)
            #expect(undrawn == [.selection] && reloads(undrawn, asked: false) == reloads([.selection], asked: false), "\(step)")
            #expect(reloads(undrawn, asked: false), "\(step): the timeline in front is asked again")
            #expect(FediqoRootView.drawnLayers([step.layer, .selection], standing: step, drawn: true) == [step.layer, .selection])
        }
        #expect(!reloads([.people, .selection], asked: false) && reloads([.people, .selection], asked: true), "a list drawn asks its own source, where there is one")
        #expect(FediqoRootView.drawnLayers([.selection], standing: nil, drawn: false) == [.selection])
        #expect(walk.depth == 2)
        let left = walk.back()
        #expect(left?.step == .people(Self.requests) && left?.lamp == Self.requests.id && walk.depth == 1)
        #expect(walk.back()?.lamp == "row-1" && walk.isEmpty)
    }

    // MARK: - Laid out

    private func laidOut(_ pane: PeoplePane, width: CGFloat, layout: ShellLayout, scheme: ColorScheme, size: DynamicTypeSize) -> [OpenedPageProbe.Part: CGRect] {
        let probe = OpenedPageProbe()
        let view = NSHostingView(
            rootView: pane.frame(width: width, height: 700)
                .environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size).environment(\.openedPageProbe, probe)
        )
        // Laid out at the page's own size, as a window would hold it.
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        view.layoutSubtreeIfNeeded()
        return probe.frames
    }

    @Test("Each list takes the pane's whole height through the frame's no-tabs form: its bar at the top and as wide as the page, no strip, its head between the bar and the people — and at the largest text the head is the list's first rows — at 720, 390 and 320, in light and in dark, with and without the mark that asks again")
    func thePageTakesTheWholeHeight() throws {
        var counted = PeopleSaid(list: Self.requests, signedIn: true, own: true, reading: .said, people: Self.given, acts: [.acceptRequest, .refuseRequest], foot: .end)
        counted.tally = 1204
        let saids: [(String, PeopleSaid)] = [
            ("the directory", PeopleSaid(list: Self.directory, reading: .said, people: Self.given, foot: .more, sorting: DirectoryChoice())),
            ("the people suggested", PeopleSaid(list: Self.suggested, signedIn: true, reading: .said, people: Self.given, foot: .farthest)),
            ("who asks, counted", counted),
            ("who asks, locked", PeopleSaid(list: Self.requests, signedIn: true, own: true, reading: .said, lock: PartWords.Place(kind: .none, key: "part.ask.partly"))),
            ("a directory the host has not", PeopleSaid(list: Self.directory, reading: .absent, sorting: DirectoryChoice())),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (layout, width, size) in [
                (ShellLayout.wide, CGFloat(720), DynamicTypeSize.large), (.narrow, 390, .large), (.narrow, 320, .xxxLarge),
                (.narrow, 320, .accessibility5),
            ] {
                for (name, said) in saids {
                    for canReload in [true, false] {
                        let at = "\(name) at \(width), \(scheme), \(size), \(canReload ? "with" : "without") the mark"
                        let pane = PeoplePane(said: said, selectedID: .constant(Self.given[1].id), canReload: canReload, onOpen: { _ in }, onBack: {})
                        let parts = laidOut(pane, width: width, layout: layout, scheme: scheme, size: size)
                        let bar = try #require(parts[.bar], "\(at)"), room = try #require(parts[.front], "\(at)")
                        #expect(parts[.strip] == nil, "\(at): a list has no tabs")
                        #expect(bar.minX == 0 && abs(bar.minY) < 0.5 && bar.width == width, "\(at): \(bar)")
                        #expect(room.minX == 0 && room.width == width && room.maxY == 700, "\(at): \(room)")
                        if PageFrame.headScrolls(at: size) {
                            #expect(room.minY - bar.maxY <= 1.5 && room.minY >= bar.maxY, "\(at): the head scrolls with the list: \(bar), \(room)")
                        } else {
                            #expect(room.minY - bar.maxY > 20, "\(at): the head stands between the bar and the list: \(bar), \(room)")
                        }
                    }
                }
            }
        }
    }

    @Test("The page and its head draw and learn no kind of source, nor do the rows")
    func drawsNotKnowingKind() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        for file in ["PeoplePane.swift", "PeopleRows.swift"] {
            let text = try String(contentsOf: url.appending(path: "Sources/FediqoUI/Shell/\(file)"), encoding: .utf8)
            #expect(DrawsNotKnowingKindTests.draws(text) && DrawsNotKnowingKindTests.kindsNamed(in: text).isEmpty, "\(file) names a kind of source")
        }
    }
}
