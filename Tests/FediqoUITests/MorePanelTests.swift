import Foundation
import SwiftUI
import Synchronization
import Testing
#if os(macOS)
import AppKit
#endif
@testable import FediqoUI

/// #385, the panel: `…` and a long press open one list — icon and name, what takes something
/// away last under a divider and red — that a keyboard walks, Return chooses from, and that has
/// closed before a chosen item's question is put.
@Suite("`…` opens a panel of its own", .serialized)
@MainActor
struct MorePanelTests {
    init() {
        L10n.language = .english
    }

    private static let question = ShellQuestion.dropCopies(language: .english)

    private static func menu(acted: @escaping (String) -> Void = { _ in }) -> ShellMore {
        ShellMore(items: [
            .danger("trash", "Remove", asks: question) { acted("Remove") },
            .plain("pencil", "Change") { acted("Change") },
            .plain(ShellMark("checklist", "Boards", look: .dim(.never))) { acted("Boards") },
            .plain("list.bullet", "Lists") { acted("Lists") },
        ])
    }

    @Test("The panel lists the ordinary items first and what takes something away last, a divider between")
    func oneList() {
        let rows = ShellMorePanelRows(Self.menu())
        #expect(rows.items.map(\.name) == ["Change", "Boards", "Lists", "Remove"])
        #expect(rows.divider == 3)
        #expect(ShellMorePanelRows(ShellMore(items: [.plain("pencil", "Change") {}])).divider == nil)
    }

    @Test("The keyboard starts on the first item that answers and walks only those, up and down, stopping at the ends")
    func theKeyboardWalks() {
        let rows = ShellMorePanelRows(Self.menu())
        #expect(rows.first == 0)
        #expect(rows.step(from: 0, up: false) == 2, "the dim item is stepped over")
        #expect(rows.step(from: 2, up: false) == 3)
        #expect(rows.step(from: 3, up: false) == 3, "it stops at the last")
        #expect(rows.step(from: 2, up: true) == 0)
        #expect(rows.step(from: 0, up: true) == 0, "and at the first")
        #expect(rows.step(from: nil, up: false) == 0)
    }

    @Test("A chosen item is done only once the panel has closed: an ordinary one acts then, one that takes something away puts its question then, and only its yes acts")
    func doneAfterItCloses() throws {
        var acted: [String] = []
        let rows = ShellMorePanelRows(Self.menu { acted.append($0) })
        var pending = ShellMorePending()
        pending.opened()
        let chose1 = pending.choose(rows.items[0])
        #expect(chose1, "the first choice closes the panel")
        #expect(acted.isEmpty, "nothing while the panel is still up")
        var put: [ShellMoreAsk] = []
        pending.release { put.append($0) }
        #expect(acted == ["Change"] && put.isEmpty)
        pending.release { put.append($0) }
        #expect(acted == ["Change"], "released once")

        pending.opened()
        let chose2 = pending.choose(rows.items[3])
        #expect(chose2)
        pending.release { put.append($0) }
        #expect(acted == ["Change"] && put.count == 1, "the red item put its question, and did nothing")
        put[0].answered("not the yes")
        #expect(acted == ["Change"])
        put[0].answered(try #require(put[0].question.chorded?.id))
        #expect(acted == ["Change", "Remove"])
    }

    @Test("A choice made as the panel goes, or after, is nothing: it is not done at the next close, even one by Escape")
    func aLateChooseIsNothing() {
        var acted: [String] = []
        let rows = ShellMorePanelRows(Self.menu { acted.append($0) })
        var pending = ShellMorePending()
        pending.opened()
        let chose3 = pending.choose(rows.items[0])
        #expect(chose3)
        let chose4 = pending.choose(rows.items[2])
        #expect(!chose4, "a second press as it goes chooses nothing")
        pending.release { _ in }
        #expect(acted == ["Change"])
        let chose5 = pending.choose(rows.items[2])
        #expect(!chose5, "the panel is shut")
        #expect(pending.item == nil)
        // Opened again and closed by Escape: nothing from before, and nothing now.
        pending.opened()
        pending.dismissed()
        pending.release { _ in }
        #expect(acted == ["Change"])
        let chose6 = pending.choose(rows.items[2])
        #expect(!chose6, "closed by Escape, it takes no choice")
    }

    @Test("Escape, a press outside, or a swipe down chooses nothing and presses nothing")
    func closingPressesNothing() {
        var acted: [String] = []
        let rows = ShellMorePanelRows(Self.menu { acted.append($0) })
        var pending = ShellMorePending()
        var put: [ShellMoreAsk] = []
        pending.opened()
        pending.dismissed()
        let chose7 = pending.choose(rows.items[3])
        #expect(!chose7, "a press landing as it closes chooses nothing")
        pending.release { put.append($0) }
        #expect(acted.isEmpty && put.isEmpty && pending.item == nil && !pending.open)
    }

    @Test("A long press turns the row's switch on only where a panel is there to take it, and the switch goes off when the last such panel goes")
    func theSwitchNeedsAPanel() {
        var held = ShellMoreSwitch()
        held.pressed()
        #expect(!held.held, "no `…` drawn: the press opens nothing, now or later")
        held.presenters(true)
        #expect(!held.held, "a panel that appears afterwards finds the switch off")
        held.pressed()
        #expect(held.held)
        held.set(false)
        #expect(!held.held)
        held.set(true)
        #expect(held.held)
        held.presenters(false)
        #expect(!held.held, "its `…` went, and the switch with it")
        held.pressed()
        #expect(!held.held, "a long press with nothing to take it")
        // A press on `…` is itself proof a panel is there, heard by the row or not yet.
        held.set(true)
        #expect(held.held)
    }

    @Test("What takes something away is red and says so to a listener; what does nothing here is drawn dim")
    func redAndSaid() {
        let rows = ShellMorePanelRows(Self.menu())
        for scheme in [ColorScheme.light, .dark] {
            #expect(ShellMorePanel.ink(rows.items[3], scheme) == ShellChrome.alarm(scheme))
            #expect(ShellMorePanel.ink(rows.items[1], scheme) == ShellChrome.markDim(scheme))
            #expect(ShellMorePanel.ink(rows.items[0], scheme) == ShellChrome.ink(scheme))
        }
        #expect(ShellMorePanel.hint(rows.items[3], language: .english) == L10n.t("mark.more.danger", language: .english))
        #expect(ShellMorePanel.hint(rows.items[0]).isEmpty)
        let hinted = ShellMoreItem.plain("circle", "Who may quote it: Anyone") {}.hinted("Quotes already made stay.")
        #expect(ShellMorePanel.hint(hinted) == "Quotes already made stay.")
        for language in [DummyLanguage.english, .taiwanese] {
            #expect(L10n.t("mark.more.danger", language: language) != "mark.more.danger")
        }
    }

    @Test("No `…` is a system menu any more: the dots open the panel, and a long press throws the switch they share")
    func theDotsOpenThePanel() throws {
        let mark = try ShellSource.shell("ShellMark")
        #expect(mark.contains(".modifier(ShellMorePresenter(shown: shown"))
        #expect(mark.contains("let shown = held ?? $open"))
        let notices = try ShellSource.shell("NoticeRow")
        #expect(notices.contains("ShellMoreHold(presenting: dotless"), "a line with no dots opens the panel itself")
        for held in ["SourceRow", "PersonHead", "Announcements", "QuotesSheet", "WaitingSheet", "KeptSection", "PersonAbout"] {
            #expect(try ShellSource.shell(held).contains(".shellMoreHeld()"), "\(held): a long press opens its panel")
        }
    }

    #if os(macOS)
    private final class Heard: Sendable {
        let present = Mutex<[Bool]>([])
    }

    /// What a view says of the panels inside it, read from outside it once it is laid out.
    private static func heard(_ view: some View) -> [Bool] {
        let heard = Heard()
        let host = NSHostingView(rootView: view.onPreferenceChange(ShellMorePresented.self) { present in
            heard.present.withLock { $0.append(present) }
        })
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 80)
        host.layoutSubtreeIfNeeded()
        return heard.present.withLock { $0 }
    }

    @Test("Drawn, a `…` says a panel is there, which is what a long press around it reads; the row's hold keeps that to itself")
    func aDrawnDotsIsTaken() {
        let dots = ShellMoreButton(Self.menu())
        #expect(Self.heard(HStack { Text("A row"); dots }).last == true, "the row hears its `…`")
        #expect(Self.heard(HStack { Text("A row"); dots }.shellMoreHeld()).last != true, "a hold around the row is not told")
        #expect(Self.heard(Text("No dots").shellMoreHeld()).last != true)
    }

    @Test("Drawn, the panel lays its items out with room for each")
    func drawn() {
        let host = NSHostingView(rootView: ShellMorePanel(more: Self.menu(), label: "More", choose: { _ in }, close: {}))
        let size = host.fittingSize
        #expect(size.width >= 220 && size.height > 4 * 20, "\(size)")
    }
    #endif
}
