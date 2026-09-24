import Foundation
import SwiftUI
import Testing
@testable import FediqoUI

/// #232: the pieces every screen of #231 is built from, each shown working on its own.
///
/// **What this reaches, and what it does not.** Each piece is drawn by `ImageRenderer` in light
/// and dark and at the largest type size, and what it says to VoiceOver and to a pointer is read
/// off the same values the view hands to the modifiers. Presses are made through the function the
/// press itself calls. A popover or a sheet actually appearing needs a window, which no test here
/// makes.
@Suite("The shared pieces say the least first", .serialized)
@MainActor
struct ShellPiecesTests {
    /// Somewhere a `@MainActor` closure can write and a test can read back.
    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
        var binding: Binding<Value> {
            Binding(get: { self.value }, set: { self.value = $0 })
        }
    }

    enum Sample: String, ShellTab, CaseIterable {
        case first, second, third
        var id: Self { self }
        var titleKey: String { "prefs.tab.choices" }
        var symbol: String {
            switch self {
            case .first: "slider.horizontal.3"
            case .second: "info.circle"
            case .third: "network"
            }
        }
    }

    private func draws(_ view: some View, _ scheme: ColorScheme, size: DynamicTypeSize = .large) throws {
        let renderer = ImageRenderer(
            content: view
                .environment(\.colorScheme, scheme)
                .dynamicTypeSize(size)
                .frame(width: 360)
                .background(ShellChrome.page(scheme))
        )
        let image = try #require(renderer.cgImage)
        #expect(image.width > 0 && image.height > 0)
    }

    // MARK: The icon button

    @Test("An icon button names itself, and says what it does after its name on hover")
    func iconButtonNamesItself() {
        let bare = ShellIconButton("arrow.clockwise", name: "shortcut.reload") {}
        #expect(bare.name == L10n.t("shortcut.reload"))
        #expect(bare.name != "shortcut.reload")
        #expect(bare.help == nil)
        #expect(ShellIconButton.hover(name: bare.name, help: bare.help) == bare.name)

        let helped = ShellIconButton("magnifyingglass", name: "shortcut.search", help: "shortcut.reload") {}
        #expect(helped.help == L10n.t("shortcut.reload"))
        #expect(ShellIconButton.hover(name: "Search", help: "Find a post") == "Search. Find a post")
        #expect(ShellIconButton.hover(name: "Search", help: "") == "Search")
    }

    @Test("An icon button draws in every tone, light and dark", arguments: [ColorScheme.light, .dark])
    func iconButtonDraws(_ scheme: ColorScheme) throws {
        let row = HStack {
            ShellIconButton("magnifyingglass", name: "shortcut.search") {}
            ShellIconButton("line.3.horizontal.decrease", name: "shortcut.search", tone: .lit) {}
            ShellIconButton("trash", name: "shortcut.search", tone: .alarm) {}
        }
        try draws(row, scheme)
        try draws(row, scheme, size: .accessibility5)
    }

    // MARK: The (?)

    @Test("The (?) opens its bubble on a press and closes it on the next")
    func helpOpensAndCloses() {
        let shown = Box(false)
        let mark = ShellHelpButton(text: "The rest of it.", shown: shown.binding)
        mark.press()
        #expect(shown.value)
        mark.press()
        #expect(!shown.value)
    }

    @Test("The (?) speaks the whole explanation, looked up by key or handed in")
    func helpSpeaksItsText() {
        #expect(ShellHelp("prefs.latest.footer").text == L10n.t("prefs.latest.footer"))
        #expect(ShellHelp("prefs.latest.footer").text != "prefs.latest.footer")
        #expect(ShellHelp(verbatim: "Twelve posts.").text == "Twelve posts.")
        #expect(L10n.t("help.more") != "help.more")
    }

    @Test("The (?), its lit mark and its bubble draw light and dark", arguments: [ColorScheme.light, .dark])
    func helpDraws(_ scheme: ColorScheme) throws {
        let text = L10n.t("prefs.latest.footer")
        try draws(Text(L10n.t("prefs.latest")).shellHelp("prefs.latest.footer"), scheme)
        try draws(HStack { ShellHelpMark(lit: false); ShellHelpMark(lit: true) }, scheme)
        try draws(ShellHelpBubble(text: text), scheme)
        try draws(ShellHelpBubble(text: text), scheme, size: .accessibility5)
    }

    // MARK: The tabs

    @Test("A press and Tab's rotation land on the tab the pills light")
    func tabsSwitch() {
        let chosen = Box(Sample.first)
        let tabs = ShellTabs(Sample.allCases, selected: chosen.value) { chosen.value = $0 }
        tabs.onSelect(.third)
        #expect(chosen.value == .third)
        // Tab is the page's own key; it moves the same state the pills read, by the one rule.
        chosen.value = DummyCommand.advanced(Sample.allCases, from: chosen.value, by: 1)
        #expect(chosen.value == .first)
        #expect(ShellTabs(Sample.allCases, selected: chosen.value) { _ in }.selected == .first)
    }

    @Test("The tabs draw with their glyphs, light and dark", arguments: [ColorScheme.light, .dark])
    func tabsDraw(_ scheme: ColorScheme) throws {
        try draws(ShellTabs(Sample.allCases, selected: .second) { _ in }, scheme)
        try draws(ShellTabs(Sample.allCases, selected: .second) { _ in }, scheme, size: .accessibility5)
    }

    // MARK: The list row

    private func row(_ id: String, _ selection: Box<String?>, _ opened: Box<[String]>) -> ShellListRow<String, Image> {
        ShellListRow(
            id: id, title: "mastodon.social", brief: "12 posts, 3 pictures", figure: "4.2 MB",
            selection: selection.binding, onOpen: { opened.value.append(id) }
        ) {
            Image(systemName: "server.rack")
        }
    }

    @Test("A first press lights a row, a second opens it; Return opens only the lit row")
    func rowEnters() {
        let selection = Box<String?>(nil)
        let opened = Box<[String]>([])
        let one = row("one", selection, opened)
        let two = row("two", selection, opened)

        #expect(!one.enter())
        one.press()
        #expect(selection.value == "one")
        #expect(opened.value.isEmpty)
        one.press()
        #expect(opened.value == ["one"])

        #expect(!two.enter())
        #expect(one.enter())
        #expect(opened.value == ["one", "one"])

        two.press()
        #expect(selection.value == "two")
        #expect(two.enter())
        #expect(opened.value == ["one", "one", "two"])
    }

    @Test("The stream and every list answer a press by one rule")
    func oneRule() {
        #expect(ShellListEntry.pressed(3, selected: nil) == .select)
        #expect(ShellListEntry.pressed(3, selected: 4) == .select)
        #expect(ShellListEntry.pressed(3, selected: 3) == .open)
        #expect(DummyCommand.tapped("a", selected: "a") == ShellListEntry.pressed("a", selected: "a"))
        #expect(L10n.t("list.open.hint") != "list.open.hint")
    }

    @Test("A row draws lit and unlit, light and dark", arguments: [ColorScheme.light, .dark])
    func rowDraws(_ scheme: ColorScheme) throws {
        let face = VStack(spacing: 0) {
            ShellListRowFace(title: "mastodon.social", brief: "12 posts", figure: "4.2 MB", selected: true,
                             mark: Image(systemName: "server.rack"))
            ShellListRowFace(title: "forum.example", brief: nil, figure: nil, selected: false,
                             mark: Image("KindDiscuzSmall", bundle: .module).resizable().scaledToFit())
        }
        try draws(face, scheme)
        try draws(face, scheme, size: .accessibility5)
        let selection = Box<String?>("one")
        try draws(row("one", selection, Box([])), scheme)
    }

    // MARK: The question before an undoable act

    private let question = ShellConfirmation(
        symbol: "trash", title: "Remove mastodon.social?",
        line: "Its posts leave this device.", help: "Adding it again reads them afresh.",
        confirm: "Remove"
    )

    @Test("Only a clear yes acts; Cancel and Escape change nothing")
    func confirmActsOnlyOnYes() {
        let acted = Box(0)
        ShellConfirmAnswer.settle(.cancel) { acted.value += 1 }
        #expect(acted.value == 0)
        ShellConfirmAnswer.settle(.confirm) { acted.value += 1 }
        #expect(acted.value == 1)
        #expect(L10n.t("confirm.cancel") != "confirm.cancel")
    }

    @Test("The question draws light and dark, and at the largest type", arguments: [ColorScheme.light, .dark])
    func confirmDraws(_ scheme: ColorScheme) throws {
        try draws(ShellConfirmCard(question: question) { _ in }, scheme)
        try draws(ShellConfirmCard(question: question) { _ in }, scheme, size: .accessibility5)
        var bare = question
        bare.help = nil
        try draws(ShellConfirmCard(question: bare) { _ in }, scheme)
    }

    // MARK: Nothing new is spoken in one language only

    @Test("Every string the pieces speak is in all three languages")
    func stringsInEveryLanguage() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FediqoUI/Resources")
        for lproj in ["en", "zh-TW", "zh-Hant"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(lproj).lproj/Localizable.strings"), encoding: .utf8
            )
            for key in ["help.more", "list.open.hint", "confirm.cancel"] {
                #expect(strings.contains("\"\(key)\" = "), "\(lproj) is missing \(key)")
            }
        }
    }
}
