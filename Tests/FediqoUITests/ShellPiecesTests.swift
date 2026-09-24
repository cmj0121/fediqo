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
        let mark = ShellHelpButton(text: "The rest of it.", subject: "Ask again", shown: shown.binding)
        mark.press()
        #expect(shown.value)
        mark.press()
        #expect(!shown.value)
    }

    @Test("The (?) names its subject and speaks the whole explanation, by key or handed in")
    func helpSpeaksItsText() {
        let keyed = ShellHelp("prefs.latest.footer", about: "Latest date")
        #expect(keyed.text == L10n.t("prefs.latest.footer"))
        #expect(keyed.text != "prefs.latest.footer")
        #expect(ShellHelp(verbatim: "Twelve posts.", about: "Posts").text == "Twelve posts.")
        let name = ShellHelpButton(text: "", subject: "Ask again", shown: .constant(false)).name
        #expect(name.contains("Ask again"))
        #expect(name != "Ask again")
    }

    @Test("A press on a phone is a finger wide, whatever the glyph measures")
    func touchFloor() {
        #expect(ShellTouchFloor.spill(drawn: 24) == 10)
        #expect(ShellTouchFloor.spill(drawn: 32) == 6)
        #expect(ShellTouchFloor.spill(drawn: 60) == 0)
    }

    @Test("The (?), its lit mark and its bubble draw light and dark", arguments: [ColorScheme.light, .dark])
    func helpDraws(_ scheme: ColorScheme) throws {
        let text = L10n.t("prefs.latest.footer")
        try draws(Text(L10n.t("prefs.latest")).shellHelp("prefs.latest.footer", about: L10n.t("prefs.latest")), scheme)
        try draws(Text("Posts").shellHelp(verbatim: text, about: "Posts"), scheme)
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

    @Test("A pill says its name, says it is the page's, and speaks a hint only where it has one")
    func pillSpeaks() {
        let lit = ShellTabPill("Mine", symbol: "line.3.horizontal.decrease", selected: true) {}
        #expect(lit.title == "Mine")
        #expect(lit.traits.contains(.isSelected))
        let other = ShellTabPill("All", symbol: "tray.full", selected: false, accessory: "circle.dashed", hint: "Missing") {}
        #expect(!other.traits.contains(.isSelected))
        #expect(other.hint == "Missing")
        #expect(other.accessory == "circle.dashed")
    }

    @Test("Every migrated page's tabs lead with a glyph; a timeline's glyph says its kind")
    func migratedTabsHaveGlyphs() {
        let preferences = PreferencesPane.Purpose.allCases.map(\.symbol)
        let usage = UsagePane.Purpose.allCases.map(\.symbol)
        let guide = DummyShortcutGroup.allCases.map(\.symbol)
        // One glyph per kind of timeline: every written one shares its kind's, and the kinds differ.
        let written = TimelineQuery.written(UUID()).symbol
        #expect(TimelineQuery.written(UUID()).symbol == written)
        let timeline = [TimelineQuery.all.symbol, TimelineQuery.trends.symbol, written]
        for set in [preferences, usage, guide, timeline] {
            #expect(Set(set).count == set.count)
            #expect(set.allSatisfy { !$0.isEmpty })
        }
    }

    @Test("The tabs draw with their glyphs, light and dark", arguments: [ColorScheme.light, .dark])
    func tabsDraw(_ scheme: ColorScheme) throws {
        try draws(ShellTabs(Sample.allCases, selected: .second) { _ in }, scheme)
        try draws(ShellTabs(Sample.allCases, selected: .second) { _ in }, scheme, size: .accessibility5)
    }

    // MARK: The list row

    private static let ids = ["one", "two"]

    /// A row of a two-row list that walks by `onStep`: a step moves the lamp, as a list would.
    private func row(_ id: String, _ selection: Box<String?>, _ opened: Box<[String]>) -> ShellListRow<String, Image, EmptyView> {
        ShellListRow(
            id: id, title: "mastodon.social", brief: "12 posts, 3 pictures", figure: "4.2 MB",
            selection: selection.binding, onOpen: { opened.value.append(id) },
            onStep: { step in
                let at = Self.ids.firstIndex(of: selection.value ?? id) ?? 0
                selection.value = Self.ids[max(0, min(Self.ids.count - 1, at + step))]
            }
        ) {
            Image(systemName: "server.rack")
        }
    }

    @Test("A first press lights a row, a second opens it; Return opens the lit row and refuses the rest")
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

    @Test("After ↓ lights the next row, Return opens that row and not the one the step left")
    func stepThenEnter() {
        let selection = Box<String?>("one")
        let opened = Box<[String]>([])
        let one = row("one", selection, opened)
        let two = row("two", selection, opened)

        #expect(one.step(up: false))
        #expect(selection.value == "two")
        #expect(!one.enter())
        #expect(two.enter())
        #expect(opened.value == ["two"])

        #expect(two.step(up: true))
        #expect(selection.value == "one")
        #expect(!two.enter())
        #expect(one.enter())
        #expect(opened.value == ["two", "one"])
    }

    @Test("At the accessibility sizes a row's figure leaves the title's side for the line under it")
    func figureStacks() {
        #expect(!ShellListRowFace<Image>.stacks(at: .xxxLarge))
        #expect(ShellListRowFace<Image>.stacks(at: .accessibility1))
    }

    @Test("The stream and every list answer a press by one rule")
    func oneRule() {
        #expect(ShellListEntry.pressed(3, selected: nil) == .select)
        #expect(ShellListEntry.pressed(3, selected: 4) == .select)
        #expect(ShellListEntry.pressed(3, selected: 3) == .open)
        #expect(DummyCommand.tapped("a", selected: "a") == ShellListEntry.pressed("a", selected: "a"))
        #expect(DummyCommand.tapped("a", selected: "b") == ShellListEntry.Tap.select)
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
        let withControl = ShellListRow(
            id: "two", title: "forum.example", brief: "A brief line that runs on long enough to wrap to a second",
            selection: selection.binding, onOpen: {}
        ) {
            Image(systemName: "server.rack")
        } control: {
            Toggle("", isOn: .constant(true)).labelsHidden()
        }
        try draws(withControl, scheme)
        try draws(withControl, scheme, size: .accessibility5)
    }

    // MARK: The question before an undoable act

    private let removing = ShellConfirmation(
        symbol: "trash", title: "Remove mastodon.social?",
        line: "Its posts leave this device.", help: "Adding it again reads them afresh.",
        choices: [.init("remove", "Remove", role: .destructive)]
    )

    private let signingIn = ShellConfirmation(
        symbol: "key", title: "Sign in to mastodon.social",
        line: "Choose what Fediqo may do there.", help: nil,
        choices: [.init("read", "Read only", role: .plain), .init("write", "Read and write", role: .primary)]
    )

    private let notice = ShellConfirmation(
        symbol: "exclamationmark.triangle", title: "Written by a newer Fediqo",
        line: "Nothing here is saved until you update.", help: "The store stays as the newer build left it.",
        choices: [], cancel: "OK"
    )

    @Test("An answer takes the question down, and only a choice acts, on the value asked about")
    func confirmSettles() {
        let item = Box<Int?>(6)
        let acted = Box<[String]>([])
        ShellConfirmAnswer.settle(.cancel, asked: 6, item: item.binding) { value, id in acted.value.append("\(value) \(id)") }
        #expect(item.value == nil)
        #expect(acted.value.isEmpty)

        item.value = 3
        ShellConfirmAnswer.settle(.choice("remove"), asked: 6, item: item.binding) { value, id in
            acted.value.append("\(value) \(id)")
        }
        #expect(item.value == nil)
        #expect(acted.value == ["6 remove"])
    }

    @Test("A question is answered once: a second answer, or a yes after Cancel, acts on nothing")
    func confirmAnsweredOnce() {
        let item = Box<Int?>(6)
        let acted = Box<[String]>([])
        ShellConfirmAnswer.settle(.choice("remove"), asked: 6, item: item.binding) { value, id in
            acted.value.append("\(value) \(id)")
        }
        ShellConfirmAnswer.settle(.choice("remove"), asked: 6, item: item.binding) { value, id in
            acted.value.append("\(value) \(id)")
        }
        #expect(acted.value == ["6 remove"])

        item.value = 2
        ShellConfirmAnswer.settle(.cancel, asked: 2, item: item.binding) { value, id in
            acted.value.append("\(value) \(id)")
        }
        ShellConfirmAnswer.settle(.choice("remove"), asked: 2, item: item.binding) { value, id in
            acted.value.append("\(value) \(id)")
        }
        #expect(acted.value == ["6 remove"])
        #expect(item.value == nil)
    }

    @Test("A yes by key is heard only once the question has settled, and never from a held key")
    func chordsWait() {
        // A pointer or a finger waits for the question to settle too, as a key does.
        #expect(!ShellConfirmChord.heard(byKey: false, armed: false, repeating: false))
        #expect(ShellConfirmChord.heard(byKey: false, armed: true, repeating: false))
        #expect(!ShellConfirmChord.heard(byKey: true, armed: false, repeating: false))
        #expect(!ShellConfirmChord.heard(byKey: true, armed: true, repeating: true))
        #expect(ShellConfirmChord.heard(byKey: true, armed: true, repeating: false))
        #expect(!ShellConfirmChord.keyHeld(), "a Mac reads the repeat itself")
        // The key that asks to remove a timeline (⌘⌫) is not the key that answers.
        let destructive = ShellConfirmChord.chord(for: .destructive)
        #expect(destructive.key == "d" && destructive.modifiers == .command)
        #expect(destructive.key != .delete)
        #expect(EditorAction.from("d", command: true, stage: .rules, fieldFocused: false) != .removeTimeline)
        #expect(EditorAction.from(KeyEquivalent.delete.character, command: true, stage: .rules, fieldFocused: false)
            == .removeTimeline)
        #expect(ShellConfirmChord.chord(for: .primary).key == .return)
        #expect(ShellConfirmChord.chord(for: .primary).modifiers == .command)
    }

    @Test("The keyboard starts on Cancel, or else on the first choice that is not a loss")
    func confirmFocus() {
        #expect(removing.firstFocus == ShellConfirmCard.cancelFocus)
        var open = signingIn
        open.cancel = nil
        #expect(open.firstFocus == "read")
        #expect(notice.firstFocus == ShellConfirmCard.cancelFocus)
        #expect(!ShellConfirmation.wellFormed(choices: removing.choices, cancel: nil))
        #expect(ShellConfirmation.wellFormed(choices: signingIn.choices, cancel: nil))
    }

    @Test("A question warns and chords only where a choice is a loss; a yes is never bare Return")
    func confirmRoles() {
        #expect(removing.warns)
        #expect(removing.chorded?.id == "remove")
        #expect(!signingIn.warns)
        #expect(signingIn.chorded?.id == "write")
        #expect(!notice.warns)
        #expect(notice.chorded == nil)
        #expect(notice.cancel == "OK")
        #expect(removing.cancel == L10n.t("board.choose.cancel"))
    }

    @Test("Each question draws light and dark, and at the largest type", arguments: [ColorScheme.light, .dark])
    func confirmDraws(_ scheme: ColorScheme) throws {
        for question in [removing, signingIn, notice] {
            try draws(ShellConfirmCard(question: question) { _ in }, scheme)
            try draws(ShellConfirmCard(question: question) { _ in }, scheme, size: .accessibility5)
        }
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
            for key in ["help.about", "list.open.hint"] {
                #expect(strings.contains("\"\(key)\" = "), "\(lproj) is missing \(key)")
            }
        }
    }
}
