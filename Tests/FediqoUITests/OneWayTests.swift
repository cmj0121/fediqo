import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// One kind of thing is drawn one way: the shared pieces the shell's pages are built from, each
/// held to the rule it states, and the pages held to using them.
///
/// What a test can reach: each piece's rule as a value, a row's height with and without its
/// chevron, and what the files say. **The sweep is a tripwire and not proof**: it catches the
/// spellings it lists, in `Shell/` and the root view, and a hand-drawn rule or corner spelled
/// any other way, or anywhere else, passes it. What it cannot: how any of it looks in a Form on a Mac or a
/// phone — that lives in view bodies.
@MainActor
@Suite("One kind of thing is drawn one way")
struct OneWayTests {
    private static func files() throws -> [String: String] {
        let shell = ShellSource.shell
        let names = try FileManager.default.contentsOfDirectory(atPath: shell.path).filter { $0.hasSuffix(".swift") }
        var files = try Dictionary(uniqueKeysWithValues: names.map {
            ($0, try String(contentsOf: shell.appendingPathComponent($0), encoding: .utf8))
        })
        let root = ShellSource.root.appendingPathComponent("FediqoRootView.swift")
        files["FediqoRootView.swift"] = try String(contentsOf: root, encoding: .utf8)
        return files
    }

    @Test("The corners are one ladder of four, and the two tables that named a rung read it from there")
    func radiusLadder() {
        let ladder = [ShellRadius.well, ShellRadius.chip, ShellRadius.field, ShellRadius.card]
        #expect(ladder == [3, 4, 6, 10])
        #expect(RailView.Metrics.wellRadius == ShellRadius.well)
    }

    @Test("A field is bordered only where it stands alone, and the way back is one glyph")
    func facesAreStated() {
        #expect(ShellFieldPlace.alone.bordered && !ShellFieldPlace.framed.bordered)
        #expect(ShellBackButton.symbol == "chevron.left")
        #expect(ShellGesture.back.symbol == ShellBackButton.symbol)
    }

    @Test("The code typed across a table is a role: the largest, rounded, and moved by the type size like every other")
    func codeRole() {
        #expect(ShellType.code.style == .largeTitle)
        #expect(ShellType.code.design == .rounded)
        #expect(ShellType.code.weight == .semibold)
    }

    @Test("A row that leads nowhere draws no chevron and is the height of one that does")
    func aRowThatLeadsNowhere() {
        func size(leads: Bool) -> CGSize {
            let face = ShellListRowFace(
                title: "mastodon.social", brief: "b", figure: nil, leads: leads, selected: false,
                mark: Image(systemName: "circle")
            )
            let host = NSHostingView(rootView: face.fixedSize())
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let (way, pick) = (size(leads: true), size(leads: false))
        #expect(way.height == pick.height)
        #expect(pick.width < way.width, "the chevron was drawn on a row that leads nowhere")
    }

    @Test("No page draws by hand what a shared piece draws: rules, corners, field styles, the back glyph, list-row insets")
    func nothingIsDrawnByHand() throws {
        for (name, text) in try Self.files() {
            if name != "ShellSpace.swift" {
                #expect(!text.contains(".fill(ShellChrome.hairline(colorScheme))"), "\(name) draws a rule by hand")
                #expect(!text.contains("\"chevron.left\"") && !text.contains("\"chevron.backward\""), "\(name) names the back glyph itself")
            }
            if name != "ShellField.swift" {
                #expect(!text.contains(".textFieldStyle("), "\(name) picks a field style itself")
            }
            if name != "ShellListRow.swift" {
                #expect(!text.contains(".listRowInsets(EdgeInsets())"), "\(name) insets a list row itself")
            }
            #expect(text.range(of: #"cornerRadius: \d"#, options: .regularExpression) == nil, "\(name) spells a corner as a number")
        }
    }

    @Test("The pages that drew their own now draw the shared piece")
    func pagesUseThePieces() throws {
        let files = try Self.files()
        func file(_ name: String) throws -> String { try #require(files[name]) }
        for (name, piece) in [
            ("ShellGesture.swift", "ShellSectionHead("), ("PreferencesPane.swift", "ShellSectionHead("),
            ("ActivityPanel.swift", ".shellFont(.pane)"),
            ("BoardPicker.swift", "ShellBandHead("), ("TimelineEditor.swift", "ShellBandHead("),
            ("CarrySection.swift", "ShellStatusLine("), ("NearbySection.swift", "ShellStatusLine("),
            ("NearbySection.swift", ".shellFont(.code)"), ("TimelineHead.swift", "ShellListRowFace("),
            ("OwnHostsSection.swift", "ShellHostField("), ("AccountPane.swift", "ShellHostField("),
        ] {
            #expect(try file(name).contains(piece), "\(name) does not draw \(piece)")
        }
        #expect(try file("NearbySection.swift").contains("leads: false"))
        #expect(try file("PageHead.swift").contains("leads: false"))
        for name in ["DummyThreadPane.swift", "ShellReader.swift", "ForumRefusal.swift", "TagPane.swift", "EarlierWordings.swift", "AccountPane.swift"] {
            #expect(try file(name).contains("ShellLinkButton("), "\(name) draws its own link")
        }
    }

    @Test("The two new headings are written in the language asked for", arguments: [DummyLanguage.english, .taiwanese])
    func headings(language: DummyLanguage) {
        for key in ["gesture.title", "prefs.look.head"] {
            #expect(L10n.t(key, language: language) != key, "\(key) is not written in \(language)")
        }
    }
}
