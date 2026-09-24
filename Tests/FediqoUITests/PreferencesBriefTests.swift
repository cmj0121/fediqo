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
        let back = ShellIconButton("chevron.left", name: "detail.back") {}
        #expect(back.name == L10n.t("detail.back") && back.name != "detail.back")
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
}
