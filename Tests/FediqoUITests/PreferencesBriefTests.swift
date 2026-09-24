import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #233: Preferences says the least first — a short line under each setting, its explanation
/// behind a (?), and every list a list of rows that open their detail.
///
/// No view inspector, so what the page shows by default is pinned by what its files say, and the
/// pieces it adds are drawn by `ImageRenderer`.
@Suite("Preferences says the least first", .serialized)
@MainActor
struct PreferencesBriefTests {
    static let shell = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/FediqoUI")

    static let pages = [
        "PreferencesPane.swift", "BuildStampSection.swift", "SourceWorkSection.swift",
        "AllowanceSection.swift", "OwnHostsSection.swift", "ActivityPanel.swift",
    ]

    /// The short line each explanation became, and the explanation behind its (?).
    static let briefs: [(brief: String, long: String)] = [
        ("prefs.askEvery.brief", "prefs.askEvery.footer"),
        ("prefs.latest.brief", "prefs.latest.footer"),
        ("about.brief", "about.footer"),
        ("work.brief", "work.footer"),
        ("allow.builtIn.brief", "allow.builtIn.footer"),
        ("allow.own.brief", "allow.own.footer"),
        ("activity.brief", "activity.footer"),
    ]

    @Test("No explanation under a setting is shown by default: each is behind a (?)")
    func explanationsAreBehindTheMark() throws {
        var said = ""
        for page in Self.pages {
            said += try String(contentsOf: Self.shell.appendingPathComponent("Shell/\(page)"), encoding: .utf8)
        }
        for (brief, long) in Self.briefs {
            #expect(said.contains("Text(L10n.t(\"\(brief)\"))"), "\(brief) is not drawn")
            #expect(said.contains(".shellHelp(\"\(long)\""), "\(long) is not behind a (?)")
            #expect(!said.contains("Text(L10n.t(\"\(long)\"))"), "\(long) is still drawn in full")
        }
        #expect(!said.contains("EntryText"), "an entry is a row and a detail, not five lines")
    }

    @Test("Each short line is a line, in every language the app ships", arguments: [DummyLanguage.english, .taiwanese])
    func briefsAreShort(_ language: DummyLanguage) {
        for (brief, long) in Self.briefs {
            let short = L10n.t(brief, language: language)
            #expect(short != brief, "\(brief) is missing in \(language)")
            #expect(short.count <= 60, "\(brief) is \(short.count) long in \(language)")
            #expect(short.count < L10n.t(long, language: language).count)
        }
    }

    @Test("↑ and ↓ walk a list's rows, from the first or last where none is lit, and stop at its ends")
    func stepping() {
        let ids = ["a", "b", "c"]
        #expect(ShellListStep.stepped(ids, from: nil, by: 1) == "a")
        #expect(ShellListStep.stepped(ids, from: nil, by: -1) == "c")
        #expect(ShellListStep.stepped(ids, from: "a", by: 1) == "b")
        #expect(ShellListStep.stepped(ids, from: "c", by: 1) == "c")
        #expect(ShellListStep.stepped(ids, from: "a", by: -1) == "a")
        #expect(ShellListStep.stepped([String](), from: "a", by: 1) == "a")
    }

    @Test("A detail's head names its way back, and draws light and dark at every size", arguments: [ColorScheme.light, .dark])
    func detailHeadDraws(_ scheme: ColorScheme) throws {
        let head = ShellDetailHead("A forum's browser check", onBack: {}) { Image(systemName: "globe") }
        #expect(head.backName == "detail.back")
        #expect(!head.escapes, "on a page Escape is the shell's, not the back button's")
        for language in [DummyLanguage.english, .taiwanese] {
            #expect(L10n.t(head.backName, language: language) != head.backName)
        }
        for size in [DynamicTypeSize.large, .accessibility5] {
            let renderer = ImageRenderer(
                content: VStack(alignment: .leading) {
                    ShellDetailHead("A forum's browser check", onBack: {}) { Image(systemName: "globe") }
                    ShellDetailFact(label: "When", value: "On a forum's pages")
                    ShellDetailFact(label: "Now", value: "Its source is not on this device", alarm: true)
                }
                .environment(\.colorScheme, scheme)
                .dynamicTypeSize(size)
                .frame(width: 360)
                .background(ShellChrome.page(scheme))
            )
            let image = try #require(renderer.cgImage)
            #expect(image.width > 0 && image.height > 0)
        }
    }

    @Test("Preferences' tabs each lead with a glyph and are named in every language")
    func tabsLeadWithGlyphs() {
        for purpose in PreferencesPane.Purpose.allCases {
            #expect(!purpose.symbol.isEmpty)
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(purpose.titleKey, language: language) != purpose.titleKey)
            }
        }
        #expect(Set(PreferencesPane.Purpose.allCases.map(\.symbol)).count == PreferencesPane.Purpose.allCases.count)
    }

    // MARK: - A detail is the session's, so Escape reaches it

    @Test("A detail shows only on its own tab, and a host's only while it is on the list")
    func whereADetailShows() {
        let mine = Allowance.ID.own(host: "cdn.example", source: "bbs.example")
        typealias Detail = PreferencesPane.Detail
        #expect(Detail.entry(.directory).shown(on: .reach, own: []))
        #expect(!Detail.entry(.directory).shown(on: .hosts, own: []))
        #expect(Detail.entry(mine).shown(on: .hosts, own: [mine]))
        #expect(!Detail.entry(mine).shown(on: .hosts, own: []), "a host removed from under it")
        #expect(!Detail.entry(mine).shown(on: .reach, own: [mine]))
        #expect(Detail.adding.shown(on: .hosts, own: []))
        #expect(!Detail.adding.shown(on: .work, own: []))
    }

    @Test("Escape closes a detail on screen, and hands its row back to the list; nothing else")
    func escapeClosesTheDetail() {
        let session = ShellSession(http: FixtureHTTP())
        #expect(!session.closePreferencesDetail(own: []), "nothing open is not a press Escape spends")
        session.preferencesPurpose = .reach
        session.preferencesOpened = .entry(.personCheck)
        #expect(session.closePreferencesDetail(own: []))
        #expect(session.preferencesOpened == nil)
        #expect(session.preferencesReturning == .entry(.personCheck), "the list lights the row that was opened")

        session.preferencesOpened = .adding
        #expect(!session.closePreferencesDetail(own: []), "a detail of another tab is not on screen")
        session.preferencesPurpose = .hosts
        #expect(session.preferencesOpened == nil, "a tab changed closes what was left open")
        session.preferencesOpened = .adding
        session.rotatePreferencesTab(by: 1)
        #expect(session.preferencesOpened == nil, "and so does Tab")
    }

    @Test("The shell's Escape closes Preferences' detail first, and leaving the page forgets it")
    func theRootHearsEscape() throws {
        let root = try String(contentsOf: Self.shell.appendingPathComponent("FediqoRootView.swift"), encoding: .utf8)
        #expect(root.contains("if place == .preferences, openLayers.subtracting([.selection]).isEmpty,\n               session.closePreferencesDetail() { return true }"))
        #expect(root.contains("session.preferencesOpened = nil"))
        let dismiss = try #require(root.range(of: "case .dismiss:"))
        let closes = try #require(root.range(of: "session.closePreferencesDetail()"))
        let selection = try #require(root.range(of: "selectedItemID = nil", range: closes.upperBound..<root.endIndex))
        #expect(dismiss.upperBound < closes.lowerBound && closes.upperBound < selection.lowerBound,
                "before a timeline selection nobody can see is cleared")
    }

    @Test("The host field tells the shell it holds the keyboard, and Return flips only the focused switch once")
    func keysAreWired() throws {
        let pane = try String(contentsOf: Self.shell.appendingPathComponent("Shell/PreferencesPane.swift"), encoding: .utf8)
        let hosts = try String(contentsOf: Self.shell.appendingPathComponent("Shell/OwnHostsSection.swift"), encoding: .utf8)
        let allowed = try String(contentsOf: Self.shell.appendingPathComponent("Shell/AllowanceSection.swift"), encoding: .utf8)
        #expect(pane.contains("session?.searchFocused = now"))
        #expect(pane.contains("onTyping: typing"))
        #expect(hosts.contains(".focused($typing)"))
        #expect(hosts.contains(".modifier(TypingTold(typing: typing, onTyping: onTyping))"))
        #expect(hosts.contains(".onChange(of: typing) { _, now in onTyping(now) }"))
        #expect(hosts.contains(".onDisappear { onTyping(false) }"))
        #expect(allowed.contains(".onKeyPress(.return, phases: .down)"))
        #expect(!allowed.contains(".keyboardShortcut(.return"), "no window-wide Return")
    }

    // MARK: - A line of work opens the record on its own source

    @Test("A line of work is listed under the source that pointed to it, as the record lists it")
    func workIsListedAsTheRecordIs() {
        let since = Date(timeIntervalSince1970: 0)
        let pointed = SourceWork.Running(host: "cdn.example", source: "BBS.example", purpose: .picture, since: since)
        let own = SourceWork.Running(host: "One.Example", purpose: .timeline, since: since)
        #expect(pointed.source == SourceAct(id: 1, reached: "cdn.example", pointedBy: "BBS.example", purpose: .picture, at: since).source)
        #expect(own.source == "one.example")
        let rows = SourceWorkRow.rows(of: [
            (key: 1, value: pointed),
            (key: 2, value: SourceWork.Running(host: "cdn.example", source: "two.example", purpose: .picture, since: since)),
            (key: 3, value: own),
        ])
        #expect(Set(rows.map(\.listedUnder)) == ["bbs.example", "two.example", "one.example"],
                "one host pointed to by two sources is two lines, each opening its own")
        let running = SourceWork()
        let token = running.begin(host: "cdn.example", for: .picture, source: "bbs.example")
        #expect(running.now.values.first?.source == "bbs.example")
        running.end(token)
    }
}
