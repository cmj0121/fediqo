import Foundation
import SwiftUI
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// What is left names itself and says the least first (#239).
///
/// What a test can reach: the short lines and what is behind their (?), which layers Escape may
/// take away on a page, the in-flight row naming the source it works for, and the wiring of the
/// controls that are named, hinted or focused. What it cannot: the hover, a keyboard attached to a
/// phone, VoiceOver reading the controls — the wiring is what is pinned for those.
@Suite("What is left names itself")
@MainActor
struct NamesItselfTests {
    static let shell = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/FediqoUI")

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.shell.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("An empty search says one line, and what is searched is behind its (?)",
          arguments: [DummyLanguage.english, .taiwanese])
    func emptySearchIsBrief(_ language: DummyLanguage) {
        let notice = EmptyNotice.timeline(
            searching: true, indexed: true, query: .all, notes: [], written: [],
            sources: [Source(host: "a.example", kind: .mastodon)], index: TextIndex([]), latest: nil,
            asked: false, language: language
        )
        #expect(notice.detail == L10n.t("search.empty.line", language: language))
        #expect(notice.help == L10n.t("search.empty.detail", language: language))
    }

    @Test("Every empty screen's line is short; the long ones are behind a (?)")
    func emptyLinesAreShort() {
        let lines = [
            "compose.none.detail", "timeline.empty.detail", "timeline.empty.trends.detail",
            "timeline.empty.trends.answered.detail", "timeline.empty.held.detail",
            "timeline.empty.answered.detail", "timeline.empty.rules.detail", "timeline.empty.latest.detail",
            "search.empty.line", "search.indexing.detail", "notices.empty.line", "timeline.unreadable.line",
            "usage.empty.detail", "preferences.empty.detail", "thread.empty.detail",
        ]
        for language in [DummyLanguage.english, .taiwanese] {
            for key in lines {
                let line = L10n.t(key, language: language)
                #expect(line != key, "\(key) is missing")
                #expect(line.count <= 100, "\(key) is more than a line")
            }
        }
        for long in ["search.empty.detail", "notices.empty.detail", "timeline.unreadable"] {
            #expect(L10n.t(long, language: .english).count > 100, "\(long) is what the (?) holds")
        }
    }

    @Test("The notices page and an unreadable store say one line with the rest behind their (?)")
    func pagesPutTheRestBehind() throws {
        let notices = try source("Shell/NoticesPane.swift")
        #expect(notices.contains(#"detail: L10n.t("notices.empty.line")"#))
        #expect(notices.contains(#"help: L10n.t("notices.empty.detail")"#))
        let pane = try source("Shell/TimelinePane.swift")
        #expect(pane.contains(#".shellHelp("timeline.unreadable", about: L10n.t("timeline.unreadable.line"))"#))
    }

    @Test("A glyph-only control drawn its own way is named on hover and to VoiceOver")
    func glyphsAreNamed() throws {
        #expect(try source("Shell/TimelinePane.swift").contains(#".shellNamed("timeline.new.title")"#))
        #expect(try source("FediqoRootView.swift").contains(#".shellNamed("compose.title")"#))
        #expect(ShellIconButton.hover(name: L10n.t("compose.title", language: .english), help: nil) == "New post")
    }

    @Test("A key hint is drawn only where there is a keyboard, and a Mac always has one")
    func keyHintsNeedAKeyboard() throws {
        #expect(ShellKeyboard.present)
        for (path, key) in [
            ("Shell/PersonPane.swift", "person.leaveHint"), ("Shell/TagPane.swift", "person.leaveHint"),
            ("Shell/DummyThreadPane.swift", "thread.leaveHint"), ("Shell/ShellReader.swift", "link.reader.leaveHint"),
        ] {
            let text = try source(path)
            #expect(text.contains("ShellKeyHint(\"\(key)\")"), "\(path) draws its hint by hand")
            #expect(!text.contains("Text(L10n.t(\"\(key)\"))"))
        }
        #expect(try source("Shell/TimelineEditor.swift").contains("ShellWithKeyboard {"))
    }

    @Test("Escape away from the timeline sees none of the timeline's own layers")
    func escapeSeesOnlyWhatIsOnScreen() {
        let walked: Set<DummyLayer> = [.thread, .search, .selection]
        #expect(FediqoRootView.escapeSees(walked, place: .timeline) == walked)
        for place in [ShellPlace.usage, .preferences, .account, .notices] {
            #expect(FediqoRootView.escapeSees(walked, place: place) == [.selection])
            #expect(FediqoRootView.escapeSees([.person, .viewer], place: place) == [.viewer])
            #expect(FediqoRootView.escapeSees([.tag, .link, .shortcuts], place: place) == [.shortcuts])
        }
    }

    @Test("A line of work reached for another source names that source; its own host says nothing more")
    func workNamesTheSourceItIsFor() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let own = SourceWorkRow(id: "a", host: "cdn.example", purpose: .picture, count: 1, since: since)
        #expect(own.brief(language: .english) == own.purposeText(language: .english))
        let one = SourceWorkRow(
            id: "b", host: "cdn.example", source: "one.example", purpose: .picture, count: 1, since: since
        )
        let two = SourceWorkRow(
            id: "c", host: "cdn.example", source: "two.example", purpose: .picture, count: 1, since: since
        )
        #expect(one.brief(language: .english).hasSuffix("for one.example"))
        #expect(one.brief(language: .taiwanese).contains("one.example"))
        #expect(one.brief(language: .english) != two.brief(language: .english))
    }

    @Test("The switch's focus is bound to the switch itself, so Space still flips it")
    func theSwitchKeepsSpace() throws {
        let text = try source("Shell/AllowanceSection.swift")
        let body = try #require(text.range(of: "struct ReturnSwitches"))
        let rest = String(text[body.lowerBound...].prefix(900))
        #expect(!rest.contains(".focusable()"))
        #expect(rest.contains(".focused($focused)"))
    }

    @Test("Every new line is in all three languages")
    func stringsInEveryLanguage() throws {
        let resources = Self.shell.appendingPathComponent("Resources")
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            for key in ["search.empty.line", "notices.empty.line", "timeline.unreadable.line", "work.for"] {
                #expect(strings.contains("\"\(key)\" = "), "\(lproj) is missing \(key)")
            }
        }
    }
}
