import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// F10, the hashtags followed: a page of its own in the frame every opened page stands in, with
/// no tabs, no timelines' head over it, a bar that holds the way back and the mark that asks the
/// source again — never Stop — a figure of how many are shown that opens nothing, Tab that turns
/// nothing, and unfollow kept in each row's `…`.
///
/// **No check here waits on anything but the call it makes**: each hosts a view and lays it
/// out, asks a value, or awaits an ask the server answers at once.
@MainActor
@Suite("The hashtags followed, as a page", .watched)
struct FollowedTagsPageTests {
    private static let host = "m.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let forum = Source(host: "forum.example", kind: .discuz)
    private static let page = FollowedTags(host: host)
    private static let step = ShellStep.followedTags(page)
    private static let scopes = "read:statuses read:accounts read:follows write:follows"

    private static func rows(_ count: Int) -> [FollowedTagRow] {
        (0..<count).map { FollowedTagRow(tag: PostTag("#tag\($0)")!, host: host) }
    }

    /// A session with the source and a forum beside it, signed in at the source where `signedIn`.
    private func session(signedIn: Bool, server: PageServer = PageServer([:])) async throws -> ShellSession {
        let session = ShellSession(http: server, store: ItemStore(), mastodon: MastodonSessions(tokens: MemoryMastodonTokens(), sender: server))
        session.work = SourceWork()
        for added in [Self.source, Self.forum] { await session.store.add(added) }
        session.sources = await session.store.sources()
        if signedIn {
            try session.mastodon.tokens.save(MastodonToken(
                host: Self.host, accessToken: "tok", clientID: "c", clientSecret: "s", scopes: Self.scopes, asked: Self.scopes
            ))
            session.mastodon.refresh()
        }
        return session
    }

    // MARK: - What the page says

    @Test("How many are shown is the head's figure — the glyph and the number on no well, opening nothing, its sentence its name — counted from the rows drawn; with no row there is none, and the list says in words why")
    func theFigureIsWhatIsShown() throws {
        let said = FollowedTagsSaid(page: Self.page, reading: .said, rows: Self.rows(1204), foot: .farthest)
        let figure = try #require(said.figure(language: .english))
        #expect(figure.symbol == "number" && figure.figure == "1,204" && figure.spoken == "1,204 shown")
        #expect(!figure.opens && !figure.lit, "it opens nothing, and is never lit")
        #expect(said.figure(language: .taiwanese)?.spoken == "顯示 1,204 個")
        // Never nought: no row, no figure — and what stands there instead is a sentence.
        let none = FollowedTagsSaid(page: Self.page, reading: .said)
        #expect(none.figure() == nil && none.nothing(language: .english) == "m.example lists no hashtags you follow.")
        for reading in [FollowedTagsSaid.Reading.asking, .failed] {
            let waiting = FollowedTagsSaid(page: Self.page, reading: reading)
            #expect(waiting.figure() == nil && waiting.stateLine() != nil, "\(reading)")
        }
    }

    @Test("A row unfollowed here stays shown, said as not followed, so the figure still counts it — as many as are drawn, never a figure the rows contradict; unfollow stays in the row's `…`, with Follow back once it is done")
    func theFigureFollowsAnUnfollow() async throws {
        let names = ["birds", "cats"]
        let server = PageServer([
            "/api/v1/accounts/verify_credentials": PageServer.Answer(body: #"{"id":"7","acct":"me","username":"me"}"#),
            "/api/v1/followed_tags?limit=100": PageServer.Answer(
                body: "[" + names.map { #"{"id":"1","name":"\#($0)","following":true,"featuring":false}"# }.joined(separator: ",") + "]"
            ),
            "/api/v1/tags/birds/unfollow": PageServer.Answer(body: #"{"id":"2","name":"birds","history":[],"following":false,"featuring":false}"#),
        ])
        let session = try await session(signedIn: true, server: server)
        let list = ShellPersonPages().followed
        await list.opened(Self.page, in: session)
        let before = try #require(list.said(of: Self.page, in: session))
        #expect(before.figure()?.figure == "2")
        let birds = try #require(before.rows.first)
        let menu = try #require(before.more(for: birds, act: {}, ask: {}))
        #expect(menu.items.map(\.name) == [L10n.t("tag.follow.unfollow")])
        // The item About's row holds, as a person's unfollow is: one glyph, ordinary, asking nothing.
        let about = TagFollowLine(host: Self.host, tag: birds.tag, standing: .said(true)).more(act: {})
        #expect(menu.items.map(\.symbol) == about?.items.map(\.symbol) && menu.dangers.isEmpty && menu.items.first?.question == nil)

        await list.press(birds.id, on: Self.page, in: session)
        let after = try #require(list.said(of: Self.page, in: session))
        #expect(after.rows.map(\.tag.name) == names && after.rows.first?.standing == .unfollowed)
        #expect(after.figure()?.figure == "\(after.rows.count)" && after.figure()?.spoken == after.shown())
        #expect(after.more(for: after.rows[0], act: {}, ask: {})?.items.map(\.name) == [L10n.t("tag.follow.follow")])
    }

    @Test("The bar's mark asks the list's source again, named by it, where `r` would ask; with nobody to ask there is no mark; the bar never holds Stop")
    func theBarsMark() {
        let said = FollowedTagsSaid(page: Self.page)
        #expect(FollowedTagsPane.reloadName(of: said, canReload: true, language: .english) == "Ask m.example again")
        #expect(FollowedTagsPane.reloadName(of: said, canReload: true, language: .taiwanese) == "再問 m.example 一次")
        #expect(FollowedTagsPane.reloadName(of: said, canReload: false) == nil)
        #expect(FollowedTagsPane.acts(onBack: {}, onReload: {}, onPull: {}).onStop == nil, "its asks are not the timeline's reload")
        // `r` and the mark are one answer: the root's, for the list in front.
        for asked in [true, false] {
            #expect(FediqoRootView.canReload(place: .timeline, editing: false, hasSources: true, open: [Self.step.layer, .selection], personAsked: asked) == asked)
        }
        #expect(!FediqoRootView.canReload(place: .timeline, editing: false, hasSources: true, open: [.shortcuts, Self.step.layer], personAsked: true), "not under the keys list")
    }

    @Test("The press beside a failure is called by its words, as Voice Control hears them, and tells a listener after them whom it asks")
    func thePressBesideAFailure() {
        let failed = FollowedTagsPane.again(FollowedTagsSaid(page: Self.page, reading: .failed), language: .english)
        #expect(failed.words == "Try again" && failed.hint == "Ask m.example again")
        let tw = FollowedTagsPane.again(FollowedTagsSaid(page: Self.page, reading: .failed), language: .taiwanese)
        #expect(tw.words == L10n.t("person.retry", language: .taiwanese) && tw.hint == "再問 m.example 一次")
    }

    // MARK: - Where it stands

    @Test("With the list in front the timelines' head is not drawn and the swipe is the page's own — on its one tab, toward the trailing edge, it leaves; signed out, or with no one holding what sources say, the list cannot be drawn, and the stream is, under the timelines' head")
    func theTimelinesHeadIsNotDrawn() async throws {
        #expect(!TimelinePane.headDrawn(over: Self.step) && TimelinePane.headDrawn(over: Self.step, drawn: false))
        #expect(TimelinePane.page(Self.step) == .tabbed && TimelinePane.page(Self.step, drawn: false) == .opened)
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: SoleTab.tabs.count, leaves: true) == .beside)
        #expect(TimelineSwipe.tabStep(from: 0, count: SoleTab.tabs.count, step: -1, leaves: true) == .leave)
        #expect(TimelineSwipe.tabStep(from: 0, count: SoleTab.tabs.count, step: 1, leaves: true) == nil)

        let pages = ShellPersonPages()
        let signedIn = try await session(signedIn: true)
        let there = TimelinePane.drawn(Self.step, of: pages, in: signedIn)
        #expect(there.drawn && there.followed?.page == Self.page && there.list == nil && there.root == nil)
        #expect(!TimelinePane.drawn(Self.step, of: nil, in: signedIn).drawn)
        let signedOut = try await session(signedIn: false)
        let gone = TimelinePane.drawn(Self.step, of: pages, in: signedOut)
        #expect(!gone.drawn && gone.followed == nil)
        #expect(TimelinePane.headDrawn(over: Self.step, drawn: gone.drawn) && TimelinePane.page(Self.step, drawn: gone.drawn) == .opened)
        // At a forum there is no such list.
        #expect(!TimelinePane.drawn(.followedTags(FollowedTags(host: Self.forum.host)), of: pages, in: signedIn).drawn)
    }

    @Test("Tab on the list is the page's — taken, turning nothing — while it is drawn and in front, nobody's while something covers it, and the timelines' over a list that cannot be drawn, where `r` asks the timeline too; Esc, q, Back and the swipe go one step back, the lamp on the line the list was opened from")
    func tabIsTakenAndLeavingIsOneStep() {
        var walk = ShellWalk()
        let me = DummyPerson(handle: "@me@m.example", host: Self.host)!
        _ = walk.walk(to: .person(me), from: "row-1")
        var lamp: String? = "you"
        #expect(walk.open(Self.page, lamp: &lamp) && lamp == Self.page.id)
        let key = Self.step.tabKey
        #expect(walk.tabKey == .sole(.rising) && key == .sole(Self.step.layer))
        #expect(FediqoRootView.stepTab(.sole(.rising), drawn: true, open: [.rising, .selection]) == .page)
        #expect(FediqoRootView.stepTab(.sole(.rising), drawn: true, open: [.viewer, .rising]) == .covered)
        #expect(FediqoRootView.stepTab(.sole(.rising), drawn: true, open: [.shortcuts, .rising]) == .covered)
        #expect(FediqoRootView.stepTab(.sole(.rising), drawn: false, open: [.rising]) == .timelines)
        // Undrawn, `r` and its mark are the stream's, as Tab is.
        let undrawn = FediqoRootView.drawnLayers([.rising, .selection], standing: Self.step, drawn: false)
        #expect(undrawn == [.selection])
        #expect(FediqoRootView.canReload(place: .timeline, editing: false, hasSources: true, open: undrawn, personAsked: false))
        #expect(FediqoRootView.drawnLayers([.rising, .selection], standing: Self.step, drawn: true) == [.rising, .selection])

        #expect(walk.depth == 2)
        let left = walk.back()
        #expect(left?.step == Self.step && left?.lamp == Self.page.id && walk.depth == 1)
        #expect(walk.back()?.lamp == "row-1" && walk.isEmpty)
    }

    // MARK: - Laid out

    private func laidOut(_ pane: FollowedTagsPane, width: CGFloat, scheme: ColorScheme, size: DynamicTypeSize, layout: ShellLayout) -> [OpenedPageProbe.Part: CGRect] {
        let probe = OpenedPageProbe()
        let view = NSHostingView(
            rootView: pane.frame(width: width, height: 700)
                .environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size).environment(\.openedPageProbe, probe)
        )
        view.frame = NSRect(x: 0, y: 0, width: width, height: 700)
        view.layoutSubtreeIfNeeded()
        return probe.frames
    }

    @Test("The list takes the pane's whole height through the frame's no-tabs form: its bar at the top and as wide as the page, no strip, its head between the bar and the hashtags — and at the largest text the head is the list's first rows — at 720, 390 and 320, in light and in dark, with and without the mark that asks again, in each state the list is said in")
    func thePageTakesTheWholeHeight() throws {
        let rows = Self.rows(3)
        let saids: [(String, FollowedTagsSaid)] = [
            ("read on", FollowedTagsSaid(page: Self.page, reading: .said, rows: rows, foot: .more)),
            ("asking", FollowedTagsSaid(page: Self.page)),
            ("failed", FollowedTagsSaid(page: Self.page, reading: .failed)),
            ("none", FollowedTagsSaid(page: Self.page, reading: .said)),
            ("asked again and failed", FollowedTagsSaid(page: Self.page, reading: .said, againFailed: true, rows: rows, foot: .end)),
            ("a sign-in that only sees", FollowedTagsSaid(page: Self.page, reading: .said, rows: rows, foot: .end, changing: PartWords.Place(kind: .none, key: "part.ask.partly"))),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (layout, width, size) in [
                (ShellLayout.wide, CGFloat(720), DynamicTypeSize.large), (.narrow, 390, .large), (.narrow, 320, .xxxLarge),
                (.narrow, 320, .accessibility5),
            ] {
                for (name, said) in saids {
                    for canReload in [true, false] {
                        let at = "\(name) at \(width), \(scheme), \(size), \(canReload ? "with" : "without") the mark"
                        let pane = FollowedTagsPane(
                            said: said, selectedID: .constant(rows[1].id),
                            reload: FollowedTagsPane.reloadName(of: said, canReload: canReload), onOpen: { _ in }, onBack: {}
                        )
                        let parts = laidOut(pane, width: width, scheme: scheme, size: size, layout: layout)
                        let bar = try #require(parts[.bar], "\(at)"), room = try #require(parts[.front], "\(at)")
                        #expect(parts[.strip] == nil, "\(at): the list has no tabs")
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

    @Test("The page, its head and its list draw and learn no kind of source")
    func drawsNotKnowingKind() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        let shell = url.appending(path: "Sources/FediqoUI/Shell")
        let page = try String(contentsOf: shell.appending(path: "FollowedTagsPage.swift"), encoding: .utf8)
        #expect(DrawsNotKnowingKindTests.draws(page) && DrawsNotKnowingKindTests.kindsNamed(in: page).isEmpty, "FollowedTagsPage.swift names a kind of source")
    }
}
