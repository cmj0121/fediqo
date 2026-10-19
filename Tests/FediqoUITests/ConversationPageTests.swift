import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// F10, a conversation: a page of its own in the frame every opened page stands in — no
/// timelines' head over it, no head and no tabs of its own, a bar that holds the way back, what
/// the page is, the way out and the mark that asks again, and Tab that turns nothing.
///
/// **No check here waits**: each hosts a view and lays it out, or asks a value.
@MainActor
@Suite("A conversation's page", .watched)
struct ConversationPageTests {
    private static func item(_ host: String, _ kind: ProtocolKind, id: String, url: String?) -> DummyItem {
        DummyItem(Note(
            id: id, source: Source(host: host, kind: kind), author: "ada", handle: "@ada@\(host)", body: "<p>Counts things</p>",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public], url: url.flatMap { URL(string: $0) }
        ))
    }

    private static let post = item("m.example", .mastodon, id: "https://m.example/users/ada/statuses/9", url: "https://m.example/@ada/9")
    private static let topic = item(
        "forum.example", .discuz, id: "discuz:forum.example:70241", url: "https://forum.example/forum.php?mod=viewthread&tid=70241"
    )

    /// Where the screens' source is, from wherever the package stands.
    private static func sources() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1, !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url.deleteLastPathComponent()
        }
        return url.appending(path: "Sources/FediqoUI")
    }

    // MARK: - What the bar says

    @Test("The bar says what the page is, the way out to the post's own page and whom the mark asks again — for a Mastodon conversation and a forum's thread alike; what a post lacks is absent")
    func whatTheBarSays() throws {
        let en = DummyLanguage.english
        let said = ConversationSaid.made(of: Self.post, blog: false, canReload: true, language: en)
        // The mark is called what the keys guide calls `r`: asking again may ask more than one source.
        let again = L10n.t("shortcut.reload", language: en)
        #expect(said.title == "Thread" && said.reload == again && again.hasPrefix("Reload this timeline, or the open thread"))
        #expect(said.wayOut == ConversationSaid.WayOut(name: "Open on m.example", url: try #require(Self.post.outwardURL)))
        let forum = ConversationSaid.made(of: Self.topic, blog: false, canReload: true, language: en)
        #expect(forum.title == "Thread" && forum.reload == again && forum.wayOut?.name == "Open on forum.example")
        #expect(ConversationSaid.made(of: Self.topic, blog: true, canReload: true, language: en).title == "Blog")
        // Nobody to ask: no mark. No page of its own, or one this device will not go to: no way out.
        #expect(ConversationSaid.made(of: Self.post, blog: false, canReload: false, language: en).reload == nil)
        for url in [nil, "javascript:alert(1)", "http://m.example/@ada/9"] {
            let nowhere = ConversationSaid.made(of: Self.item("m.example", .mastodon, id: "n", url: url), blog: false, canReload: true, language: en)
            #expect(nowhere.wayOut == nil && nowhere.marks(open: { _ in }).isEmpty, "\(url ?? "no address")")
        }
        let tw = ConversationSaid.made(of: Self.post, blog: false, canReload: true, language: .taiwanese)
        #expect(tw.title == "討論串" && tw.reload == L10n.t("shortcut.reload", language: .taiwanese) && tw.reload != again && tw.wayOut?.name == "在 m.example 開啟")
        #expect(ConversationSaid.made(of: Self.topic, blog: true, canReload: true, language: .taiwanese).title == "日誌")
    }

    @Test("The way out is one mark: its glyph, its words as its name, where it leads told to a pointer, that it leaves the app told to a listener — and its press opens the post's own page")
    func theWayOutIsAMark() throws {
        var opened: [URL] = []
        let said = ConversationSaid.made(of: Self.post, blog: false, canReload: true, language: .english)
        let marks = said.marks(language: .english) { opened.append($0) }
        let mark = try #require(marks.first)
        #expect(marks.count == 1 && mark.symbol == "arrow.up.forward.app" && mark.name == "Open on m.example")
        #expect(mark.help == "Opens https://m.example/@ada/9 in your browser" && mark.hint == "Leaves this app and opens your browser")
        mark.action()
        #expect(opened == [URL(string: "https://m.example/@ada/9")!])
        let tw = try #require(said.marks(language: .taiwanese) { _ in }.first)
        #expect(tw.help == "用瀏覽器開啟 https://m.example/@ada/9" && tw.hint == "會離開這個 App，改用瀏覽器開啟")
        // Every glyph of the bar is named to a pointer and to a listener, shed to its glyph or not.
        let bar = try String(contentsOf: Self.sources().appending(path: "Shell/PageBar.swift"), encoding: .utf8)
        for said in [".help(mark.help ?? mark.name)", ".accessibilityLabel(mark.name)", ".help(name)", ".accessibilityLabel(name)"] {
            #expect(bar.components(separatedBy: said).count == 2, "the bar has \(said) once")
        }
    }

    // MARK: - The page

    /// What the page handed its rows, and where the frame laid its parts.
    private final class Handed {
        var titleRow: String??
    }

    private func laidOut(
        _ said: ConversationSaid, width: CGFloat, layout: ShellLayout, scheme: ColorScheme = .light, size: DynamicTypeSize = .large,
        onStop: (() -> Void)? = nil, bar: PageBarProbe? = nil
    ) -> (parts: [OpenedPageProbe.Part: CGRect], titleRow: String??) {
        let probe = OpenedPageProbe(), handed = Handed()
        let page = ConversationPage(said: said, slide: PageSlide(), onStop: onStop) { titleRow in
            let _ = handed.titleRow = .some(titleRow)
            Color.clear
        }
        let view = NSHostingView(
            rootView: page.frame(width: width, height: 700)
                .environment(\.shellLayout, layout).environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, size).environment(\.openedPageProbe, probe).environment(\.pageBarProbe, bar)
        )
        view.layoutSubtreeIfNeeded()
        return (probe.frames, handed.titleRow)
    }

    @Test("The page takes the pane's whole height through the frame's no-tabs form: its bar at the top and as wide as the page, no strip, and the conversation straight under the bar's rule — at 720, 390 and 320, at the largest text, in light and in dark, whatever the bar holds")
    func thePageTakesTheWholeHeight() throws {
        let en = DummyLanguage.english
        let whole = ConversationSaid.made(of: Self.post, blog: false, canReload: true, language: en)
        let saids: [(String, ConversationSaid)] = [
            ("a Mastodon conversation", whole),
            ("a forum's thread", ConversationSaid.made(of: Self.topic, blog: false, canReload: true, language: en)),
            ("a forum's blog", ConversationSaid.made(of: Self.topic, blog: true, canReload: true, language: en)),
            ("nobody to ask", ConversationSaid.made(of: Self.post, blog: false, canReload: false, language: en)),
            ("no way out", ConversationSaid(title: "Thread", reload: "Ask m.example again")),
            ("neither", ConversationSaid(title: "Thread")),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (layout, width, size) in [
                (ShellLayout.wide, CGFloat(720), DynamicTypeSize.large), (.narrow, 390, .large), (.narrow, 320, .large),
                (.narrow, 320, .xxxLarge), (.narrow, 320, .accessibility5),
            ] {
                for (name, said) in saids {
                    let at = "\(name) at \(width), \(scheme), \(size)"
                    let laid = laidOut(said, width: width, layout: layout, scheme: scheme, size: size)
                    let bar = try #require(laid.parts[.bar]), room = try #require(laid.parts[.front])
                    #expect(laid.parts[.strip] == nil, "\(at): a conversation has no tabs")
                    // The bar sheds what does not fit: it is never wider than the page.
                    #expect(bar.minX == 0 && bar.minY == 0 && bar.width == width, "\(at): \(bar)")
                    // Nothing between the bar and the conversation but the rule: no head, no strip.
                    #expect(room.minY - bar.maxY <= 1.5 && room.minY >= bar.maxY, "\(at): \(bar), \(room)")
                    #expect(room.minX == 0 && room.width == width && room.maxY == 700, "\(at): \(room)")
                    // At an accessibility text size the title is the conversation's first row.
                    let scrolls = ConversationSaid.titleScrolls(at: size)
                    #expect(laid.titleRow == .some(scrolls ? said.title : nil), "\(at)")
                }
            }
        }
        #expect(ConversationSaid.titleScrolls(at: .accessibility1) && !ConversationSaid.titleScrolls(at: .xxxLarge))
    }

    /// How wide `view` would be drawn with all the room it wants.
    private func ideal<V: View>(_ view: V, size: DynamicTypeSize) -> CGFloat {
        NSHostingView(rootView: view.environment(\.dynamicTypeSize, size).environment(\.shellLayout, .wide)).fittingSize.width
    }

    @Test("The bar draws the first rung that fits and no lesser one: everything where there is room, without the hint about a key where only that does not fit, and the way out as its glyph alone only where its words do not fit either — one line high, and inside the page, at every width and at the largest text")
    func theBarShedsWhatDoesNotFit() throws {
        let said = ConversationSaid.made(of: Self.post, blog: false, canReload: true, language: .english)
        let way = PageBarProbe.Part.mark(ConversationSaid.wayOutSymbol)
        var rungs: Set<[Bool]> = []
        for (width, size) in [
            (CGFloat(1000), DynamicTypeSize.large), (440, .large), (390, .large), (320, .large), (240, .large), (200, .large),
            (390, .xxxLarge), (320, .xxxLarge), (320, .accessibility5),
        ] {
            let at = "\(width) at \(size)"
            let titled = ConversationSaid.titleScrolls(at: size) ? nil : said.title
            // What each rung needs, measured apart from the page: the whole line, and the line
            // without its hint; and the way out with its words, and as its glyph alone.
            let whole = ideal(PageBar(title: titled, marks: said.marks { _ in }, reload: said.reload), size: size)
            let hint = ideal(ShellKeyHint("person.leaveHint"), size: size)
            let named = PageBarProbe(), roomy = PageBarProbe()
            _ = laidOut(said, width: 2000, layout: .narrow, size: size, bar: named)
            let words = try #require(named.widths[way])
            let room = width - ShellSpace.pad * 2
            let fitsWhole = whole <= room, fitsUnhinted = whole - hint - ShellSpace.snug <= room

            let bar = PageBarProbe()
            let laid = try #require(laidOut(said, width: width, layout: .narrow, size: size, bar: bar).parts[.bar])
            let tall = try #require(laidOut(said, width: 2000, layout: .narrow, size: size, bar: roomy).parts[.bar])
            let drawn = try #require(bar.widths[way])
            #expect((bar.widths[.hint] != nil) == fitsWhole, "\(at): the hint, with \(whole) wanted of \(room)")
            #expect((drawn == words) == fitsUnhinted, "\(at): the way out is \(drawn) wide, \(words) with its words")
            #expect(drawn == words || drawn < words / 2, "\(at): whole, or its glyph alone, never squeezed: \(drawn) of \(words)")
            #expect(laid.height == tall.height, "\(at): \(laid.height), one line is \(tall.height)")
            // Inside the page wherever a rung fits; the last rung is drawn where none does.
            if width >= 240 { #expect(laid.minX == 0 && laid.width == width, "\(at): \(laid)") }
            rungs.insert([bar.widths[.hint] != nil, drawn == words])
        }
        // Each of the three rungs was drawn somewhere above: the check is of the ladder, not of one rung.
        #expect(rungs == [[true, true], [false, true], [false, false]], "\(rungs)")
        // With the way out and the mark that asks again the bar is no taller than with the mark alone.
        let large = try #require(laidOut(said, width: 320, layout: .narrow, size: .accessibility5).parts[.bar])
        let bare = try #require(laidOut(ConversationSaid(title: "Thread", reload: said.reload), width: 320, layout: .narrow, size: .accessibility5).parts[.bar])
        #expect(large.width == 320 && large.height == bare.height, "\(large), \(bare)")
    }

    @Test("While a read the reader pressed for runs, the bar's mark is Stop: the same button with another glyph and another name, to a pointer and to a listener, and the bar does not shift; somebody's page has nothing to stop and is handed none")
    func theMarkStopsWhatItBegan() throws {
        let en = DummyLanguage.english
        #expect(ReloadMark.shown(canReload: true, stoppable: true) == .stop && ReloadMark.shown(canReload: true, stoppable: false) == .reload)
        #expect(ReloadMark.stop.symbol != ReloadMark.reload.symbol)
        let again = L10n.t("shortcut.reload", language: en)
        #expect(PageBar.againName(again, shown: .reload, language: en) == again)
        #expect(PageBar.againName(again, shown: .stop, language: en) == "Stop reloading")
        #expect(PageBar.againName(again, shown: .stop, language: .taiwanese) == "停止重新載入")
        // A press on Stop just after the press that began the read is not heard, as on the timelines' mark.
        let pressed = Date()
        #expect(!ReloadMark.stops(at: pressed.addingTimeInterval(0.1), pressedAt: pressed) && ReloadMark.stops(at: pressed.addingTimeInterval(1), pressedAt: pressed))
        // One button, as wide and as tall in either state.
        let said = ConversationSaid.made(of: Self.post, blog: false, canReload: true, language: en)
        for (layout, width, size) in [(ShellLayout.wide, CGFloat(720), DynamicTypeSize.large), (.narrow, 390, .large), (.narrow, 320, .accessibility5)] {
            let asks = laidOut(said, width: width, layout: layout, size: size).parts
            let stops = laidOut(said, width: width, layout: layout, size: size, onStop: {}).parts
            #expect(asks == stops && asks[.bar] != nil, "\(width), \(size)")
        }
        let ui = try Self.sources()
        let bar = try String(contentsOf: ui.appending(path: "Shell/PageBar.swift"), encoding: .utf8)
        for call in [
            "if let shown = ReloadMark.shown(canReload: true, stoppable: onStop != nil) {",
            "let name = Self.againName(reload, shown: shown)",
            "switch ReloadMark.press(shown, at: Date(), pressedAt: reloadPressed) {\n                case .begins:\n                    reloadPressed = Date()\n                    onReload()\n                case .stops: onStop?()\n                case .unheard: break",
            "Image(systemName: shown.symbol)",
        ] {
            #expect(bar.components(separatedBy: call).count == 2, "the bar has \(call) once")
        }
        let pane = try String(contentsOf: ui.appending(path: "Shell/TimelinePane.swift"), encoding: .utf8)
        #expect(pane.components(separatedBy: "onStop: session.reload.stoppable ? { session.reload.stop() } : nil,").count == 2)
        #expect(ShellReload.stoppable([.thread]) == [.thread], "a conversation's read is one the reader may stop")
        // Somebody's page has a Stop of its own, handed by the pane, and never the stream's.
        let person = try String(contentsOf: ui.appending(path: "Shell/PersonPage.swift"), encoding: .utf8)
        #expect(person.contains("onStop: acts.onStop") && !person.contains("session.reload"))
        #expect(pane.contains("onStop: onStop(.person(person)),"))
    }

    // MARK: - Where it stands

    @Test("With a conversation in front the timelines' head is not drawn and the sideways swipe is the page's own; one that cannot be drawn draws the stream, under the timelines' head, and is left by the swipe as before")
    func theTimelinesHeadIsNotDrawn() throws {
        #expect(!TimelinePane.headDrawn(over: .thread("a")) && !TimelinePane.headDrawn(over: .thread("a"), drawn: true))
        #expect(TimelinePane.headDrawn(over: .thread("a"), drawn: false) && TimelinePane.headDrawn(over: nil))
        #expect(TimelinePane.page(.thread("a")) == .tabbed && TimelinePane.page(.thread("a"), drawn: false) == .opened)
        #expect(TimelineSwipe.means(touch: true, page: .tabbed, searching: false, listShown: false, editing: false) == nil, "the timeline's swipe is not heard on it")
        // The page's own swipe: on its one tab, toward the trailing edge, it leaves.
        #expect(TimelineSwipe.means(touch: true, detail: false, tabs: SoleTab.tabs.count, leaves: true) == .beside)
        #expect(TimelineSwipe.tabStep(from: 0, count: SoleTab.tabs.count, step: -1, leaves: true) == .leave)

        let ui = try Self.sources()
        let pane = try String(contentsOf: ui.appending(path: "Shell/TimelinePane.swift"), encoding: .utf8)
        for call in [
            "if Self.headDrawn(over: standing, drawn: drawn) {",
            "page: Self.page(standing, drawn: drawn),",
            "if let root {\n                    conversationPage(root)\n                } else {\n                    underneath",
            "let shown = Self.drawn(standing, of: people, in: session)\n        let root = shown.root, listed = shown.list, drawn = shown.drawn\n        VStack(alignment: .leading, spacing: 0) {",
            // The names of the timelines are brought to the one in front as the head is drawn again.
            ".onAppear {\n                        guard let query = session.timelineID else { return }\n                        Task { @MainActor in proxy.scrollTo(query.id) }\n                    }",
            // Asked as it opens and let go as it is left, as it was.
            ".task(id: opened.id) { await session.reload.opened(opened, in: session) }",
            "await PullsToReload.pull(offered: true, reload: ways.onReload, settled: { await session.reload.settled(.thread) })",
        ] {
            #expect(pane.components(separatedBy: call).count == 2, "the pane has \(call) once")
        }
        // The conversation keeps no bar of its own: the frame's is the only one.
        let thread = try String(contentsOf: ui.appending(path: "Shell/DummyThreadPane.swift"), encoding: .utf8)
        #expect(!thread.contains("ShellBackButton") && !thread.contains("ShellKeyHint") && !thread.contains("onBack"))
        #expect(thread.contains("LazyVStack(alignment: .leading, spacing: ShellSpace.snug) {\n                        // What the page is, where its bar has no room to say it.\n                        if let titleRow { ConversationTitleRow(title: titleRow).id(ConversationTitleRow.rowID) }"))
        // `g` goes to the top of what is drawn: the title, where it is the list's first row.
        #expect(DummyThreadPane.topRow(titled: true, first: "post-1") == ConversationTitleRow.rowID)
        #expect(DummyThreadPane.topRow(titled: false, first: "post-1") == "post-1")
        // The page and the bar draw, and learn no kind of source.
        for file in ["ConversationPage.swift", "PageBar.swift"] {
            let text = try String(contentsOf: ui.appending(path: "Shell/\(file)"), encoding: .utf8)
            #expect(DrawsNotKnowingKindTests.draws(text) && DrawsNotKnowingKindTests.kindsNamed(in: text).isEmpty, "\(file) names a kind of source")
        }
    }

    @Test("Tab on a conversation is taken and does nothing — it turns neither the timelines nor the walk — while the page is what is in front; and leaving goes one step back with the lamp on the row the conversation was taken from")
    func tabIsTakenAndLeavingIsOneStep() throws {
        var walk = ShellWalk()
        _ = walk.walk(to: .person(DummyPerson(handle: "@ada@m.example", host: "m.example")!), from: "row-1")
        _ = walk.walk(to: .thread("post-9"), from: "row-7")
        #expect(walk.tabKey == .sole(.thread) && ShellStep.thread("post-9").tabKey == .sole(.thread))
        let before = walk
        // The key is the page's only while nothing is drawn over it — the one rule somebody's page has.
        #expect(FediqoRootView.pageInFront(.thread, open: [.thread, .selection]))
        #expect(!FediqoRootView.pageInFront(.thread, open: [.viewer, .thread]) && !FediqoRootView.pageInFront(.thread, open: [.shortcuts, .thread]))
        #expect(FediqoRootView.turnsPersonTabs(open: [.person]) == FediqoRootView.pageInFront(.person, open: [.person]))
        #expect(!FediqoRootView.turnsPersonTabs(open: [.viewer, .person]))
        let root = try String(contentsOf: Self.sources().appending(path: "FediqoRootView.swift"), encoding: .utf8)
        for call in [
            "if case .sole(let layer) = key, !pageInFront(layer, open: open) { return .covered }",
            "static func turnsPersonTabs(open: Set<DummyLayer>) -> Bool {\n        pageInFront(.person, open: open)",
        ] {
            #expect(root.components(separatedBy: call).count == 2, "the root has \(call) once")
        }
        #expect(walk == before && walk.depth == 2)
        let left = walk.back()
        #expect(left?.step == .thread("post-9") && left?.lamp == "row-7" && walk.depth == 1)
    }

    @Test("A conversation that cannot be drawn — its post no longer held — draws the stream under the timelines' head, and there Tab turns the timelines as it always did: what is drawn is asked once, by the head, the swipe and the key alike")
    func aConversationThatCannotBeDrawn() async throws {
        let store = ItemStore()
        let source = Source(host: "m.example", kind: .mastodon)
        await store.add(source)
        let note = Note(
            id: "https://m.example/users/ada/statuses/9", source: source, author: "ada", handle: "@ada@m.example", body: "<p>Counts things</p>",
            postedAt: Date(timeIntervalSince1970: 1_700_000_000), categories: [.public]
        )
        await store.ingest([note])
        let http = FixtureHTTP([:])
        let session = ShellSession(http: http, store: store, posts: ForumPosts(http: http))
        await session.reloadFromStore()
        let held = DummyItem(note).id
        #expect(session.held(held) != nil)
        let here = ShellStep.thread(held), gone = ShellStep.thread("https://m.example/users/ada/statuses/withdrawn")
        func drawn(_ step: ShellStep?) -> TimelinePane.Drawn { TimelinePane.drawn(step, of: nil, in: session) }
        #expect(drawn(here).drawn && !drawn(gone).drawn)
        // A list of people is drawn only where somebody says what it is (F10): with nobody, the stream.
        #expect(drawn(nil).drawn && !drawn(.people(PeopleList(directoryAt: "m.example"))).drawn)
        // Drawn: no head of the timelines, the page's own swipe, and the key the page's.
        #expect(!TimelinePane.headDrawn(over: here, drawn: drawn(here).drawn))
        // Not drawn: the head, the swipe that goes back — and the key the timelines'.
        let undrawn = drawn(gone).drawn
        #expect(TimelinePane.headDrawn(over: gone, drawn: undrawn) && TimelinePane.page(gone, drawn: undrawn) == .opened)
        #expect(gone.tabKey == .sole(.thread), "the step still answers; the root asks what is drawn before it listens")
        let root = try String(contentsOf: Self.sources().appending(path: "FediqoRootView.swift"), encoding: .utf8)
        let asked = "if place.isStream, let key = walk.tabKey {\n            switch Self.stepTab(key, drawn: standingDrawn, open: openLayers) {\n            case .page: return rotateStepTab(key, by: step)\n            case .covered: return false\n            case .timelines: break\n            }\n        }\n        return switch place {\n        case .timeline: session.rotateTab(by: step)"
        #expect(root.components(separatedBy: asked).count == 2, "the root asks what is drawn, and else turns the timelines")
        #expect(root.contains("private var standingDrawn: Bool {\n        TimelinePane.drawn(walk.standing, of: people, in: session).drawn\n    }"))
        let pane = try String(contentsOf: Self.sources().appending(path: "Shell/TimelinePane.swift"), encoding: .utf8)
        // One look-up of the post, in one function: the pane's body and the root both go through it.
        #expect(pane.components(separatedBy: "session.held(").count == 2, "the pane looks a post up to draw it in one place")
        #expect(pane.contains("case .thread(let id):\n            let root = session.held(id)\n            return Drawn(root: root, drawn: root != nil)"))
        #expect(pane.components(separatedBy: "Self.drawn(standing, of: people, in: session)").count == 2, "asked once in the body")
        #expect(drawn(here).root?.id == held && drawn(gone).root == nil && drawn(nil).root == nil)
    }

    @Test("The keys guide says what Tab does on an opened page with no tabs, in each language; the bar's words are the ones every opened page has")
    func theGuideSaysWhatTabDoes() throws {
        #expect(L10n.t("shortcut.tabs", language: .english) == "Turn the tabs of the page in front — the timelines, or those of somebody's page, a hashtag, what is rising or what a search found. A conversation, a list of people and the hashtags you follow have none, and there it does nothing: leave the page to change timeline")
        #expect(L10n.t("shortcut.tabs", language: .taiwanese) == "輪換眼前這一頁的分頁——時間軸，或某人的頁面、主題標籤頁、正在竄升的、搜尋找到的那一頁的分頁。討論串、一份名單和你追蹤的主題標籤沒有分頁，在那裡這個鍵不做任何事：先離開那一頁，才能換時間軸")
        let resources = try Self.sources().appending(path: "Resources")
        let tw = try String(contentsOf: resources.appending(path: "zh-TW.lproj/Localizable.strings"), encoding: .utf8)
        let hant = try String(contentsOf: resources.appending(path: "zh-Hant.lproj/Localizable.strings"), encoding: .utf8)
        let line = try #require(tw.split(separator: "\n").first { $0.hasPrefix("\"shortcut.tabs\"") })
        #expect(hant.contains(line))
        // A conversation's own words for Back and the key went with its own bar.
        for table in [tw, hant, try String(contentsOf: resources.appending(path: "en.lproj/Localizable.strings"), encoding: .utf8)] {
            #expect(!table.contains("\"thread.back\"") && !table.contains("\"thread.leaveHint\""))
            #expect(table.contains("\"person.back\"") && table.contains("\"person.leaveHint\"") && table.contains("\"person.reload\""))
        }
    }
}
