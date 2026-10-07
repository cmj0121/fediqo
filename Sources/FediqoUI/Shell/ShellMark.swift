import SwiftUI

/// How a control is drawn: **two looks and no third.** Live, in the hue that says what a press
/// on it is, or dim, with the reason it cannot be pressed for what it stands for.
///
/// A row's controls are a fixed list in a fixed order, and none is left out for a protocol or a
/// state: what a source lacks is drawn dim in the same place, so every row of a list has the same
/// shape and a reader learns it once.
///
/// **The look decides the ink and what a press is, and nothing about the glyph.** Which symbol is
/// drawn is the act's own, and whether it is the filled twin is the mark's state (`ShellMark.on`)
/// — so a bookmark that is on stays `bookmark.fill` when it goes dim, and one that is off is the
/// outline in both looks. Grey and not grey are the same icon in two colours.
///
/// **Neither look is the alarm**: a press that takes something away is an item of the `…` menu
/// (`ShellMoreItem.danger`) and never a mark. The one stated exception is an ink handed to
/// `ShellMarkButton` over the look's own — the source row's permission glyph
/// (`SourceRow.permissionInk`), which is in the alarm where a write was turned away: it says
/// something happened to a press, and offers none that takes anything.
enum MarkLook: Equatable {
    /// There to be pressed, and saying nothing else — but for being switched on, which is the
    /// mark's state (`ShellMark.on`) and not a look.
    case live
    case dim(DimReason)
}

/// Why a mark is dim. One look for three different facts would be one silence, so the reason goes
/// wherever the look cannot be seen or is not enough: the pointer's help, VoiceOver, and the head
/// of the row's `…` menu.
///
/// `never` and not `none`, which an optional reason would read as its own nothing.
enum DimReason: Equatable, CaseIterable {
    /// This source has no such thing: a forum has no boost, a protocol has no sign-in.
    case never
    /// It has, and not at this moment: busy, offline, a post that is gone.
    case notNow
    /// The sign-in must be asked again before this is offered.
    case askAgain

    var key: String {
        switch self {
        case .never: "mark.dim.never"
        case .notNow: "mark.dim.notNow"
        case .askAgain: "mark.dim.askAgain"
        }
    }
}

/// One control of a row, as a value: its glyph, what it is called, whether it is switched on, how
/// it is drawn, and the count beside it where it has one. `ShellMarkButton` draws it; the rules it
/// is drawn by are the statics here, so a test reads them without a screen.
struct ShellMark: Equatable {
    /// The act's own symbol, unfilled: `drawn(_:on:)` fills it where the mark is on.
    let symbol: String
    /// What it is called, already in words — most carry a host or a post's author.
    let name: String
    let look: MarkLook
    /// Switched on by the reader: the filled twin where the glyph has one, in either look, and
    /// the warm hue while it is live. The one place "on" is said.
    var on: Bool
    var count: Int?

    init(_ symbol: String, _ name: String, look: MarkLook, on: Bool = false, count: Int? = nil) {
        self.symbol = symbol
        self.name = name
        self.look = look
        self.on = on
        self.count = count
    }

    /// What a press on a mark is.
    enum Press: Equatable {
        /// The act itself.
        case acts
        /// Only the question that asks the sign-in again; the act waits for its yes.
        case asks
        /// Taken, and nothing happens: the mark keeps its place and its focus, and says why.
        case nothing
    }

    /// The glyphs that have a filled twin a mark wears once it is on.
    static let filled: Set<String> = ["key", "star", "bookmark", "archivebox"]

    /// The ink of a glyph. A live mark that is on is the warm hue and one that is off the quiet;
    /// dim is one ink whatever the reason and whether or not it is on — the reason is said, not
    /// coloured, and on is still read off the filled glyph.
    static func ink(_ look: MarkLook, on: Bool, _ scheme: ColorScheme) -> Color {
        switch look {
        case .dim: ShellChrome.markDim(scheme)
        case .live: on ? ShellChrome.filament(scheme) : ShellChrome.inkDim(scheme)
        }
    }

    /// The ink of the count beside a glyph. **A count is text, and text has a higher floor than a
    /// glyph**: beside a dim mark it is `inkFaint`, the faintest ink this shell writes in, and
    /// not `markDim`, which is held only to a graphical object's 3:1. Live, it is the glyph's.
    static func countInk(_ look: MarkLook, on: Bool, _ scheme: ColorScheme) -> Color {
        if case .dim = look { return ShellChrome.inkFaint(scheme) }
        return ink(look, on: on, scheme)
    }

    /// The symbol as drawn: the filled twin where the mark is on and the glyph has one, the act's
    /// own symbol otherwise. **The look is not asked**, so live and dim cannot draw two glyphs.
    static func drawn(_ symbol: String, on: Bool) -> String {
        on && filled.contains(symbol) ? "\(symbol).fill" : symbol
    }

    /// What the pointer is shown and VoiceOver hears: the name, and for a dim mark its reason
    /// after it — one sentence for the two, in the shape `ShellIconButton.hover` gives a name and
    /// its help.
    static func spoken(name: String, look: MarkLook, language: DummyLanguage? = nil) -> String {
        guard case .dim(let reason) = look else { return name }
        return said(name, L10n.t(reason.key, language: language), language: language)
    }

    /// A name and what is said of it, joined as the language joins two sentences — the table's
    /// (`mark.dim.said`), since a full stop and a space are English's and not Chinese's.
    static func said(_ name: String, _ why: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("mark.dim.said", language: language), name, why)
    }

    /// What a press on a mark of this look is. **A dim mark never acts**: one that only needs
    /// asking again puts its question, which is itself the asking first, and the other two take
    /// the press and do nothing.
    static func press(_ look: MarkLook) -> Press {
        switch look {
        case .live: .acts
        case .dim(.askAgain): .asks
        case .dim: .nothing
        }
    }

    /// A press, sent where the look says it goes: to `act` for a live mark, to `ask` for one that
    /// must be asked again, and nowhere otherwise.
    static func pressed(_ look: MarkLook, act: () -> Void, ask: (() -> Void)?) {
        switch press(look) {
        case .acts: act()
        case .asks: ask?()
        case .nothing: break
        }
    }

    var drawn: String { Self.drawn(symbol, on: on) }
    var spoken: String { Self.spoken(name: name, look: look) }
}

/// One mark, drawn — in `ShellGlyphBox`, the box every glyph-only control has, and in the look
/// the mark carries.
///
/// **Dim is not disabled.** A disabled control is skipped by the keyboard and said only as
/// "dimmed"; this one keeps its place in the focus order and its sentence, so a listener hears
/// the same reason a pointer is shown. Its press is taken and goes nowhere, or to `ask` where the
/// reason is that the sign-in must be asked again.
struct ShellMarkButton: View {
    let mark: ShellMark
    /// An ink for the glyph over the look's own — `MarkLook`'s one stated exception, and nothing
    /// else hands one in.
    let ink: Color?
    let act: () -> Void
    let ask: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    /// `act` is the press of a live mark; `ask` puts the question a dim mark asks first, and is
    /// never called for any other look.
    init(_ mark: ShellMark, ink: Color? = nil, ask: (() -> Void)? = nil, act: @escaping () -> Void) {
        self.mark = mark
        self.ink = ink
        self.act = act
        self.ask = ask
    }

    var body: some View {
        Button {
            ShellMark.pressed(mark.look, act: act, ask: ask)
        } label: {
            HStack(spacing: ShellSpace.tight) {
                Image(systemName: mark.drawn)
                    .foregroundStyle(ink ?? ShellMark.ink(mark.look, on: mark.on, colorScheme))
                if let count = mark.count {
                    Text(L10n.compact(count))
                        .foregroundStyle(ShellMark.countInk(mark.look, on: mark.on, colorScheme))
                }
            }
            .modifier(ShellGlyphBox())
        }
        .buttonStyle(.plain)
        .help(mark.spoken)
        .accessibilityLabel(mark.spoken)
        .accessibilityValue(mark.count.map { L10n.compact($0) } ?? "")
        // Said as selected where the mark is switched on — dim or not, since on is its state.
        .accessibilityAddTraits(mark.on ? .isSelected : [])
    }
}

// MARK: - The `…` menu

/// A destructive item that was chosen and has not been answered: its question and what a yes does.
///
/// **Only the question's yes acts.** A question may offer more than one choice; the yes is the
/// one its chord gives (`ShellConfirmation.chorded`: the destructive choice, or the keyed one
/// where the act is not a loss, as Clear's is), and any other choice changes nothing here.
struct ShellMoreAsk {
    let question: ShellConfirmation
    let act: () -> Void

    /// The question was answered with the choice `id`.
    func answered(_ id: String) {
        guard id == question.chorded?.id else { return }
        act()
    }
}

/// One item of a `…` menu. **The only type with a destructive form, and that form cannot be built
/// without its question**: `danger` takes it, nothing else makes an item red, and choosing one
/// hands back the question rather than acting — so an act that takes something away is offered in
/// one place and always asks first.
struct ShellMoreItem {
    let symbol: String
    let name: String
    let look: MarkLook
    /// Switched on, as a mark is: the filled twin tells it from one that is off.
    let on: Bool
    private let asking: Asking
    private let act: () -> Void
    private let ask: (() -> Void)?

    /// What an item asks before it acts. **Built when the item is chosen and not when the menu
    /// is**, so a list of rows that is drawn again builds no question nobody is shown, and the
    /// question reads as things stand at the press.
    private enum Asking {
        /// An ordinary item: it acts.
        case none
        /// A destructive item's question, put at the press.
        case now(() -> ShellConfirmation)
        /// A destructive item's question that has to be counted first; nothing where the count
        /// finds nothing to ask about.
        case counted(@MainActor () async -> ShellConfirmation?)
    }

    private init(
        symbol: String, name: String, look: MarkLook, on: Bool = false, asking: Asking,
        act: @escaping () -> Void, ask: (() -> Void)? = nil
    ) {
        self.symbol = symbol
        self.name = name
        self.look = look
        self.on = on
        self.asking = asking
        self.act = act
        self.ask = ask
    }

    /// An item that takes nothing away, and is always there to be chosen.
    static func plain(_ symbol: String, _ name: String, act: @escaping () -> Void) -> Self {
        Self(symbol: symbol, name: name, look: .live, asking: .none, act: act)
    }

    /// The item that does what a row's mark does, from the mark itself: one glyph, one name, one
    /// look and one state for the two. `ask` puts the question a dim item asks first where its
    /// reason is that the sign-in must be asked again.
    static func plain(_ mark: ShellMark, ask: (() -> Void)? = nil, act: @escaping () -> Void) -> Self {
        Self(symbol: mark.symbol, name: mark.name, look: mark.look, on: mark.on, asking: .none, act: act, ask: ask)
    }

    /// An item that takes something away: `asks` is put first, and `act` is what its yes does.
    /// Dim where there is nothing to take — no password held — and then it neither asks nor acts.
    /// The question must have a yes (`ShellConfirmation.chorded`), since only that acts.
    ///
    /// `asks` is not evaluated here: it is kept and built when the item is chosen.
    static func danger(
        _ symbol: String, _ name: String, look: MarkLook = .live,
        asks: @autoclosure @escaping () -> ShellConfirmation, act: @escaping () -> Void
    ) -> Self {
        Self(symbol: symbol, name: name, look: look, asking: .now(asks), act: act)
    }

    /// The same, from a mark: its glyph, its name and its look.
    static func danger(
        _ mark: ShellMark, asks: @autoclosure @escaping () -> ShellConfirmation, act: @escaping () -> Void
    ) -> Self {
        Self(symbol: mark.symbol, name: mark.name, look: mark.look, asking: .now(asks), act: act)
    }

    /// An item that takes something away **and whose question names a count only the press can
    /// take**: choosing it runs `counts`, and the question that comes back is put at once — so the
    /// number asked about is the number at the press, never one drawn before the store moved.
    /// Where the count finds nothing to take, `counts` says so itself and hands back nothing: no
    /// question is put and `act` is not reached. Either way a press is answered.
    static func danger(
        _ symbol: String, _ name: String, look: MarkLook = .live,
        counts: @escaping @MainActor () async -> ShellConfirmation?, act: @escaping () -> Void
    ) -> Self {
        Self(symbol: symbol, name: name, look: look, asking: .counted(counts), act: act)
    }

    /// The symbol as drawn — a mark's rule, so the menu and the row draw one glyph for one state.
    var drawn: String { ShellMark.drawn(symbol, on: on) }

    /// What a destructive item asks, built now; nothing for an ordinary one, or for one whose
    /// question is counted (`counted()`).
    var question: ShellConfirmation? {
        if case .now(let asks) = asking { asks() } else { nil }
    }

    var isDanger: Bool {
        if case .none = asking { false } else { true }
    }

    /// Whether the item's question is counted at the press.
    var isCounted: Bool {
        if case .counted = asking { true } else { false }
    }

    /// A counted item's count, taken now: the question to put — or nothing, where the item is
    /// dim, is not counted, or the count found nothing to ask about.
    @MainActor
    func counted() async -> ShellMoreAsk? {
        guard case .counted(let counts) = asking, ShellMark.press(look) == .acts,
              let question = await counts()
        else { return nil }
        return asks(question)
    }

    private func asks(_ question: ShellConfirmation) -> ShellMoreAsk {
        assert(question.chorded != nil, "a destructive item's question needs a yes")
        return ShellMoreAsk(question: question, act: act)
    }

    /// What the item reads: its name, and its reason after it where it is dim. A menu draws no
    /// colour of ours, so the words carry the look.
    func title(language: DummyLanguage? = nil) -> String {
        headed ? name : ShellMark.spoken(name: name, look: look, language: language)
    }

    /// Whether the menu's head already says why this item is dim (`ShellMore.reasons`), so its
    /// title is its name alone and the reason is said once.
    private(set) var headed = false

    /// The same item in a menu whose head names it under its reason.
    var underHead: Self {
        var item = self
        item.headed = true
        return item
    }

    /// Whether choosing it does anything. A menu's own way of drawing an item that does not is
    /// what a dim mark's ink is on a row, so here — and only here — dim is disabled.
    var answers: Bool {
        switch ShellMark.press(look) {
        case .acts: true
        case .asks: ask != nil
        case .nothing: false
        }
    }

    /// The item was chosen — the one way anything it holds is reached. An ordinary one acts; a
    /// destructive one only hands `put` its question, **at the press** where the question is
    /// there to build, and once it is counted where it is not (the count's task is handed back
    /// for whoever waits on it); a dim one asks again where that is its reason, and otherwise
    /// does nothing.
    @MainActor
    @discardableResult
    func press(put: @escaping @MainActor (ShellMoreAsk) -> Void) -> Task<Void, Never>? {
        switch ShellMark.press(look) {
        case .acts:
            switch asking {
            case .none: act()
            case .now(let question): put(asks(question()))
            case .counted: return Task { if let ask = await counted() { put(ask) } }
            }
        case .asks: ask?()
        case .nothing: break
        }
        return nil
    }
}

/// What a row's `…` holds, as a value — so the menu under `…` and the one under a long press are
/// made from the same thing and cannot differ.
///
/// **One order whatever order it was built in**: the head lines — what the row has to say, and
/// each dim mark's reason, the only place a finger reads it — then the ordinary items, a divider,
/// and the destructive ones last.
struct ShellMore {
    let head: [String]
    let items: [ShellMoreItem]

    init(head: [String] = [], items: [ShellMoreItem]) {
        self.head = head
        self.items = items
    }

    /// A menu ending in an item that may be dim for a reason the three shared ones do not say:
    /// `reason`, in the menu's own words, stands at the head and the item under it says its name
    /// alone. Nothing to say, and the menu is its items.
    static func ending(
        in item: ShellMoreItem, dimFor reason: String?, after items: [ShellMoreItem] = []
    ) -> Self {
        guard let reason else { return Self(items: items + [item]) }
        return Self(head: [reason], items: items + [item.underHead])
    }

    /// Why each dim mark of a row is dim — the only place a finger reads it, since a phone has no
    /// hover. One line a reason, in the order the marks first give them, **each naming the marks it is
    /// about**: "<name>, <name>. <reason>", the shape `ShellMark.spoken` gives one mark — so a
    /// line read on its own says what is dim as well as why, and six marks dim for one reason
    /// still say it once.
    static func reasons(of marks: [ShellMark], language: DummyLanguage? = nil) -> [String] {
        var seen: [(reason: DimReason, names: [String])] = []
        for mark in marks {
            guard case .dim(let reason) = mark.look else { continue }
            if let at = seen.firstIndex(where: { $0.reason == reason }) {
                seen[at].names.append(mark.name)
            } else {
                seen.append((reason, [mark.name]))
            }
        }
        guard !seen.isEmpty else { return [] }
        let between = L10n.t("mark.dim.names", language: language)
        return seen.map {
            ShellMark.said($0.names.joined(separator: between), L10n.t($0.reason.key, language: language), language: language)
        }
    }

    static let symbol = "ellipsis"

    var ordinary: [ShellMoreItem] { items.filter { !$0.isDanger } }
    var dangers: [ShellMoreItem] { items.filter(\.isDanger) }

    /// A divider stands between the two kinds, and only where there are both.
    var divides: Bool { !ordinary.isEmpty && !dangers.isEmpty }

    /// What `…` is called. A menu of one item names it, so the one press it hides is not hidden
    /// from a pointer or a listener.
    func label(language: DummyLanguage? = nil) -> String {
        Self.label(only: items.count == 1 ? items.first?.name : nil, language: language)
    }

    /// What `…` is called on a row that has something to say: its name, and then that there is
    /// something to read behind it — the words for what `ShellMoreButton.ink` says in colour.
    func label(saying: ShellMoreSaying, language: DummyLanguage? = nil) -> String {
        Self.label(only: items.count == 1 ? items.first?.name : nil, saying: saying, language: language)
    }

    /// The same, without the menu in hand: `only` is the name of its one item, where it has one
    /// and no more. What a row whose menu always holds several calls its `…` before building it.
    static func label(
        only: String? = nil, saying: ShellMoreSaying = .nothing, language: DummyLanguage? = nil
    ) -> String {
        let more = L10n.t("mark.more", language: language)
        let name = only.map { String(format: L10n.t("mark.more.one", language: language), $0) } ?? more
        guard saying != .nothing else { return name }
        return ShellMark.said(name, L10n.t("mark.more.said", language: language), language: language)
    }
}

/// Whether the head of a row's `…` has something the reader has not been shown. `…` is one glyph
/// whatever this is: it is said in colour and in the menu's name.
enum ShellMoreSaying: Equatable {
    /// Nothing to read beyond what the menu always holds.
    case nothing
    /// Only that the row is waiting on something.
    case waits
    /// Something went wrong, or is owed.
    case warns
}

/// The inside of a `…` menu: what goes in a `Menu` or a `.contextMenu`. A destructive item that
/// is chosen is handed to `asked`, which `ShellMoreAsks` puts as a question.
///
/// **The menu is built in `body`** — which a `Menu` asks for when it is opened, where its content
/// closure is run every time the row around it is drawn.
struct ShellMoreItems: View {
    let build: () -> ShellMore
    @Binding var asked: ShellMoreAsk?

    init(more: ShellMore, asked: Binding<ShellMoreAsk?>) {
        self.init(asked: asked) { more }
    }

    init(asked: Binding<ShellMoreAsk?>, build: @escaping () -> ShellMore) {
        self.build = build
        _asked = asked
    }

    var body: some View {
        let more = build()
        let ordinary = more.ordinary
        let dangers = more.dangers
        if !more.head.isEmpty {
            Section {
                ForEach(Array(more.head.enumerated()), id: \.offset) { _, line in Text(line) }
            }
        }
        rows(ordinary)
        if !ordinary.isEmpty, !dangers.isEmpty { Divider() }
        rows(dangers)
    }

    private func rows(_ items: [ShellMoreItem]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Button(role: item.isDanger ? .destructive : nil) {
                item.press { asked = $0 }
            } label: {
                Label(item.title(), systemImage: item.drawn)
            }
            .disabled(!item.answers)
        }
    }
}

/// Puts the question of the destructive item that was chosen, and acts only on its yes
/// (`ShellMoreAsk.answered`) — through
/// `.shellConfirm`, the one way a question is put. A modifier of its own, so a view that offers
/// the menu under a long press hangs it beside the menu in one line.
struct ShellMoreAsks: ViewModifier {
    @Binding var asked: ShellMoreAsk?

    func body(content: Content) -> some View {
        content.shellConfirm($asked, question: \.question) { ask, id in ask.answered(id) }
    }
}

/// `…`: the last control of a row, always the same glyph, opening the row's menu. Named by what
/// it holds (`ShellMore.label`) to the pointer and to VoiceOver alike.
///
/// **Colour is the only signal, as on a mark**: quiet, and the alarm where the row's menu has
/// something at its head that went wrong (`ShellMoreSaying.warns`). It is not a mark — it offers
/// nothing itself — so the alarm here says there is something to read and never that the press
/// takes something away.
///
/// **The menu is built when it is opened** (`ShellMoreItems`), so a list of rows that is drawn
/// again builds no menu nobody opened.
struct ShellMoreButton: View {
    let label: String
    let saying: ShellMoreSaying
    let more: () -> ShellMore
    /// Where a chosen item's question is put when the view around the button puts it too — it
    /// then hangs the one `ShellMoreAsks`, and the button none.
    let asks: Binding<ShellMoreAsk?>?

    @State private var asked: ShellMoreAsk?
    @Environment(\.colorScheme) private var colorScheme

    /// A menu already in hand, named by what it holds.
    init(_ more: ShellMore, saying: ShellMoreSaying = .nothing, asks: Binding<ShellMoreAsk?>? = nil) {
        self.init(label: more.label(saying: saying), saying: saying, asks: asks) { more }
    }

    /// A menu built when it is opened, under a name known without it.
    init(
        label: String, saying: ShellMoreSaying = .nothing, asks: Binding<ShellMoreAsk?>? = nil,
        more: @escaping () -> ShellMore
    ) {
        self.label = label
        self.saying = saying
        self.asks = asks
        self.more = more
    }

    /// The ink of `…`: the alarm only where the row warns; waiting keeps the quiet ink.
    static func ink(_ saying: ShellMoreSaying, _ scheme: ColorScheme) -> Color {
        saying == .warns ? ShellChrome.alarm(scheme) : ShellChrome.inkDim(scheme)
    }

    var body: some View {
        if asks == nil {
            menu.modifier(ShellMoreAsks(asked: $asked))
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            ShellMoreItems(asked: asks ?? $asked, build: more)
        } label: {
            Image(systemName: ShellMore.symbol)
                .foregroundStyle(Self.ink(saying, colorScheme))
                .modifier(ShellGlyphBox())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(label)
        .accessibilityLabel(label)
    }
}
