import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// #235: the account page and adding a source say the least first — the list of sources and
/// adding one are two tabs, and every explanation is a short line with its (?).
@MainActor
@Suite("The account page says the least first")
struct AccountTabsTests {
    private static let alpha = Source(host: "alpha.test", kind: .mastodon)

    @Test("Tabs are drawn only where something is joined")
    func tabsNeedAList() {
        #expect(!AccountPane.tabbed(sources: 0))
        #expect(AccountPane.tabbed(sources: 1))
        #expect(AccountPane.Purpose.allCases == [.sources, .add])
        for purpose in AccountPane.Purpose.allCases {
            #expect(!purpose.symbol.isEmpty)
            #expect(L10n.t(purpose.titleKey, language: .taiwanese) != purpose.titleKey)
        }
    }

    @Test("Tab rotates Account's two tabs, and is the platform's while nothing is joined")
    func tabRotates() {
        let session = ShellSession(http: FixtureHTTP())
        #expect(session.accountPurpose == .sources)
        #expect(!session.rotateAccountTab(by: 1), "a page with no tabs took the Tab key")
        #expect(session.accountPurpose == .sources)

        session.sources = [Self.alpha]
        #expect(session.rotateAccountTab(by: 1))
        #expect(session.accountPurpose == .add)
        #expect(session.rotateAccountTab(by: 1))
        #expect(session.accountPurpose == .sources)
        #expect(session.rotateAccountTab(by: -1))
        #expect(session.accountPurpose == .add)
        #expect(session.usagePurpose == .source, "Account's tabs are its own, not Usage's")
    }

    /// No view inspector, so the page is pinned by what its files say: the shell's Tab reaches
    /// Account, the page draws the shared tabs, and no explanation is drawn as a line of its own.
    @Test("The page is wired to the shared pieces, and draws no explanation by default")
    func wired() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI")
        let root = try String(contentsOf: ui.appendingPathComponent("FediqoRootView.swift"), encoding: .utf8)
        let pane = try String(contentsOf: ui.appendingPathComponent("Shell/AccountPane.swift"), encoding: .utf8)
        #expect(root.contains("case .account: session.rotateAccountTab(by: step)"))
        #expect(pane.contains("ShellTabs(Purpose.allCases, selected: session.accountPurpose)"))
        #expect(pane.contains("ShellIconButton(\"books.vertical\", name: \"account.browse.label\")"))
        for key in ["account.hero.detail", "account.add.detail", "account.sources.detail",
                    "account.sources.marks", "account.sources.writing"] {
            #expect(!pane.contains("Text(L10n.t(\"\(key)\"))"), "\(key) is drawn as a line again")
        }
    }

    @Test("The list's (?) says what the list is and what its marks mean")
    func sourcesHelp() {
        for language in [DummyLanguage.english, .taiwanese] {
            let help = AccountPane.sourcesHelp(language: language)
            #expect(help.contains(L10n.t("account.sources.detail", language: language)))
            #expect(help.contains(L10n.t("account.sources.marks", language: language)))
        }
    }

    @Test("A turned-away caution is one line before a press, and whole on a detail")
    func cautionLine() {
        let joined = PreviewOrigin.joined(Self.alpha)
        #expect(SourcePreviewView.cautionLineKey(.turnedAway, for: .field) == "join.preview.turnedAway.line")
        #expect(SourcePreviewView.cautionLineKey(.turnedAway, for: joined) == nil)
        #expect(SourcePreviewView.cautionLineKey(.needsAccount, for: .field) == nil)
        #expect(SourcePreviewView.cautionLineKey(.needsAccount, for: joined) == nil)
    }

    @Test("The browser check is one line, with the rest behind its (?)")
    func wallLine() {
        for stop in ForumSignInStop.allKinds {
            if case .wall = stop {
                #expect(stop.explanationKey == "forum.stop.wall.line")
                #expect(stop.moreKey == "forum.stop.wall")
            } else {
                #expect(stop.moreKey == nil, "\(stop) grew a (?) nobody wrote")
            }
        }
    }

    @Test("Saving the password says what it does in one line, and the whole promise behind (?)")
    func saveLine() {
        #expect(ForumSignInSheet.saveKeys(saving: true) == ("forum.signin.save.line.on", "forum.signin.save.on"))
        #expect(ForumSignInSheet.saveKeys(saving: false) == ("forum.signin.save.line.off", "forum.signin.save.off"))
    }

    /// Every short line this task put on a screen: translated, and a line rather than a paragraph.
    @Test("Every short line is in every language, and short")
    func linesAreShort() {
        let keys = [
            "account.hero.line", "account.add.line", "account.sources.line",
            "account.sources.writing.line", "account.sources.writing.again.line",
            "join.preview.unread.line", "join.preview.turnedAway.line", "forum.stop.wall.line",
            "forum.signin.save.line.on", "forum.signin.save.line.off", "refusal.password.line",
        ]
        for key in keys {
            for language in [DummyLanguage.english, .taiwanese] {
                let said = L10n.t(key, language: language)
                #expect(said != key && !said.isEmpty, "\(key) is missing in \(language)")
                #expect(said.count <= 72, "\(key) is longer than a line in \(language): \(said)")
            }
        }
        #expect(L10n.t("account.browse", language: .english) == "account.browse", "Browse's caption is still shipped")
    }
}
