import SwiftUI

// `…` as a panel of its own (#385): one list, each act its icon and its name, what takes
// something away last under a divider and red. Beside `…` on a wide page, rising from the bottom
// on a narrow one; `…` and a long press on the row open the same panel, from the same value.

/// The panel's list, as a value a test can walk without drawing it: the items in the order they
/// are drawn — ordinary first, then the ones that take something away — and where the divider is.
struct ShellMorePanelRows {
    let items: [ShellMoreItem]
    /// The index the divider stands before; nothing where there are not both kinds.
    let divider: Int?

    init(_ more: ShellMore) {
        let ordinary = more.ordinary
        items = ordinary + more.dangers
        divider = more.divides ? ordinary.count : nil
    }

    /// Where the keyboard stands when the panel opens: the first item that answers a press.
    var first: Int? { items.indices.first { items[$0].answers } }

    /// The next item that answers a press, from `index`, a step up or down; where there is none
    /// that way, it stays where it is.
    func step(from index: Int?, up: Bool) -> Int? {
        guard let index else { return first }
        let way: [Int] = up ? Array(items.indices.prefix(index).reversed()) : Array(items.indices.dropFirst(index + 1))
        return way.first { items[$0].answers } ?? index
    }
}

/// One opening of the panel, from the press that opens it to the moment it has gone: what was
/// chosen in it, and **done once it has closed**, so a question an item that takes something away
/// puts — or the sheet it opens — comes after the panel and never over it.
///
/// **One choice an opening, and only while it is up.** A press that lands as the panel is going,
/// or after it has gone, chooses nothing; Escape, a press outside and a swipe down choose nothing;
/// and an opening starts with nothing chosen, so nothing from one opening is done at the close of
/// another.
struct ShellMorePending {
    private(set) var item: ShellMoreItem?
    private(set) var open = false

    /// The panel is up: an opening of its own, with nothing chosen.
    mutating func opened() {
        open = true
        item = nil
    }

    /// `chosen` was pressed. Whether the panel is to close for it: only the first choice of an
    /// opening that is still up.
    mutating func choose(_ chosen: ShellMoreItem) -> Bool {
        guard open, item == nil else { return false }
        item = chosen
        open = false
        return true
    }

    /// Closed without a choice: Escape, a press outside, a swipe down.
    mutating func dismissed() {
        open = false
    }

    /// The panel has gone: what was chosen is pressed now, once, its question handed to `put`.
    @MainActor
    mutating func release(put: @escaping @MainActor (ShellMoreAsk) -> Void) {
        open = false
        guard let chosen = item else { return }
        item = nil
        chosen.press(put: put)
    }
}

/// The switch a row's long press shares with the `…` inside it (`ShellMoreHold`): **on only where
/// a panel is there to take it.** A row whose `…` is not drawn — a person's head with no acts, a
/// hashtag's line with nothing to offer — keeps the switch off at a long press, and turns it off
/// when the last panel that could take it goes, so no panel opens later that nobody asked for.
struct ShellMoreSwitch {
    private(set) var held = false
    private(set) var taken = false

    /// A long press on the row.
    mutating func pressed() {
        held = taken
    }

    /// Set from the panel or its `…`: on as it opens, off as it closes. A press on `…` is proof a
    /// panel is there, so this follows `on` whether or not the row has heard so yet.
    mutating func set(_ on: Bool) {
        held = on
    }

    /// Whether a panel inside the row is there to take the switch, as the row last laid out.
    mutating func presenters(_ present: Bool) {
        taken = present
        if !present { held = false }
    }
}

/// Whether a panel stands inside a view: what `ShellMoreHold` reads to know a long press has
/// somewhere to go.
struct ShellMorePresented: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// The panel itself: the items, each a press of its icon and name.
///
/// **One element the keyboard stands on, and the rows inside it**: ↑ and ↓ walk the items that
/// answer a press, Return chooses the one lit, Escape closes. The list is focusable as a whole
/// rather than row by row, so the walk works with or without the system's full keyboard access.
/// A listener lands on each row, which says what it is, and that it takes something away.
struct ShellMorePanel: View {
    let more: ShellMore
    /// What the panel is called to a listener: `…`'s own name.
    let label: String
    /// Whether it is drawn in a sheet, which scrolls, rather than a popover, which sizes to it.
    var scrolls = false
    let choose: (ShellMoreItem) -> Void
    let close: () -> Void

    @State private var lit: Int?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let rows = ShellMorePanelRows(more)
        Group {
            if scrolls {
                ScrollView { list(rows) }
            } else {
                list(rows)
            }
        }
        .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
        .background(ShellChrome.floatFill(colorScheme))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            lit = rows.first
            focused = true
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            lit = rows.step(from: lit, up: press.key == .upArrow)
            return .handled
        }
        .onKeyPress(.return) {
            guard let lit, rows.items.indices.contains(lit), rows.items[lit].answers else { return .ignored }
            choose(rows.items[lit])
            return .handled
        }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func list(_ rows: ShellMorePanelRows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.items.enumerated()), id: \.offset) { index, item in
                if index == rows.divider { Divider().padding(.vertical, ShellSpace.tight) }
                row(item, lit: index == lit)
            }
        }
        .padding(.vertical, ShellSpace.tight)
    }

    private func row(_ item: ShellMoreItem, lit: Bool) -> some View {
        Button {
            choose(item)
        } label: {
            HStack(spacing: ShellSpace.step) {
                Image(systemName: item.drawn)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(item.title())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .shellFont(.body)
            .foregroundStyle(Self.ink(item, colorScheme))
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.step)
            .background(lit ? ShellChrome.hoverFill(colorScheme) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.answers)
        .help(item.hint ?? "")
        .accessibilityHint(Text(Self.hint(item)))
    }

    /// The ink of an item: the alarm where it takes something away, a dim mark's ink where it does
    /// nothing here, the words' own otherwise.
    static func ink(_ item: ShellMoreItem, _ scheme: ColorScheme) -> Color {
        if !item.answers { return ShellChrome.markDim(scheme) }
        return item.isDanger ? ShellChrome.alarm(scheme) : ShellChrome.ink(scheme)
    }

    /// What a listener is told beyond the item's name: that it takes something away and asks
    /// first, where it does, and its own hint.
    static func hint(_ item: ShellMoreItem, language: DummyLanguage? = nil) -> String {
        let danger = item.isDanger ? L10n.t("mark.more.danger", language: language) : nil
        return [danger, item.hint].compactMap { $0 }.joined(separator: " ")
    }
}

/// Opens the panel while `shown` is on: a popover anchored on the view it is hung on where the
/// page is wide, a sheet at medium height rising from the bottom where it is narrow. Choosing an
/// item closes it, and the item is pressed once it has closed (`ShellMorePending`) — its question
/// handed to `asked`.
struct ShellMorePresenter: ViewModifier {
    @Binding var shown: Bool
    @Binding var asked: ShellMoreAsk?
    let label: String
    let build: () -> ShellMore

    @State private var pending = ShellMorePending()
    @Environment(\.shellLayout) private var shellLayout

    private var narrow: Bool { shellLayout == .narrow }

    func body(content: Content) -> some View {
        content
            .popover(isPresented: Binding(get: { shown && !narrow }, set: { shown = $0 }), arrowEdge: .bottom) {
                panel(scrolls: false)
                    .presentationCompactAdaptation(.popover)
                    // A popover has no dismissal to wait on but its content's: it has gone when the
                    // panel has, and only then is what was chosen done.
                    .onDisappear(perform: release)
            }
            .sheet(isPresented: Binding(get: { shown && narrow }, set: { shown = $0 }), onDismiss: release) {
                panel(scrolls: true)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .preference(key: ShellMorePresented.self, value: true)
    }

    private func panel(scrolls: Bool) -> some View {
        ShellMorePanel(more: build(), label: label, scrolls: scrolls, choose: { item in
            if pending.choose(item) { shown = false }
        }, close: {
            pending.dismissed()
            shown = false
        })
        .onAppear { pending.opened() }
        // The panel is a place of its own: a long press inside it opens nothing of the row's.
        .environment(\.shellMoreHeld, nil)
    }

    private func release() {
        pending.release { asked = $0 }
    }
}

extension EnvironmentValues {
    /// Whether a long press on the row around a `…` has asked for its panel (#385): the one
    /// switch the row's long press and its `…` share, so both open the one panel. Nothing where
    /// no row holds one, and `…` keeps its own.
    @Entry var shellMoreHeld: Binding<Bool>? = nil
}

/// A long press on this view opens the panel of the `…` inside it — the same panel, from the
/// same value, that a press on `…` opens.
///
/// `presenting` is for a row that draws no `…` where it is narrow (a notice's line): the row then
/// opens the panel itself, at the bottom of the page, as `…` would there.
struct ShellMoreHold: ViewModifier {
    var presenting: (label: String, build: () -> ShellMore, asked: Binding<ShellMoreAsk?>)?

    @State private var held = ShellMoreSwitch()

    @ViewBuilder
    func body(content: Content) -> some View {
        let state = $held
        let shown = Binding(get: { state.wrappedValue.held }, set: { state.wrappedValue.set($0) })
        Group {
            if let presenting {
                content.modifier(ShellMorePresenter(
                    shown: shown, asked: presenting.asked, label: presenting.label, build: presenting.build
                ))
            } else {
                content
            }
        }
        .environment(\.shellMoreHeld, shown)
        .onPreferenceChange(ShellMorePresented.self) { present in
            MainActor.assumeIsolated { state.wrappedValue.presenters(present) }
        }
        // Read here, and no further: a hold around this one is not told this one's panel is its.
        .transformPreference(ShellMorePresented.self) { $0 = false }
        .onLongPressGesture { held.pressed() }
    }
}

extension View {
    /// A long press here opens the panel of the `…` inside (`ShellMoreHold`).
    func shellMoreHeld() -> some View {
        modifier(ShellMoreHold())
    }
}
