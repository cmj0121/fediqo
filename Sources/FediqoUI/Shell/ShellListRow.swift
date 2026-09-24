import SwiftUI

/// How a list answers the reader (#232) — **rule 3 of #231, as a rule and not a copy.**
///
/// The timeline's rule, made to take any id: a press on a row that is not lit lights it, and a
/// press on the lit row opens it. `DummyCommand.tapped` asks this, so the stream and every other
/// list cannot come to answer a press differently. Return is `ShellListRow.enter()`'s.
enum ShellListEntry {
    typealias Tap = DummyRowTap

    /// What a press on `id` does, given the row that is lit.
    static func pressed<ID: Equatable>(_ id: ID, selected: ID?) -> Tap {
        selected == id ? .open : .select
    }
}

/// One row of a list (#232): a mark, a title, a brief line, and the figure that matters most —
/// and a way in to the rest. The rest is the row's detail, and entering the row opens it.
///
///     [mark]  title                              figure  ›  [control]
///             a brief line, two at most
///
/// **Entering, three ways, one outcome.** A press lights the row and a second press opens it
/// (`ShellListEntry.pressed`). Return opens the lit row, and ↑ and ↓ hand the list a step where
/// it takes one (`onStep`); the keyboard's focus follows the lamp. VoiceOver, whose reader activates once,
/// opens in one — the row's default action. Focus does not light a row, because a click focuses
/// before it presses and would turn every first press into an open; a focused row wears the hover
/// plate instead.
///
/// **The chevron is what says there is more.** A row that opens nothing is not this row. A control
/// of the row's own — a switch, a clear — sits after it, outside what a press on the row enters,
/// and is spoken as itself rather than folded into the row.
///
/// Lit on the lamp's wash with the lamp in its margin, the way the rail and the stream say where
/// the reader is; the plate is `RailView`'s radius, so the list is machined like the rest.
struct ShellListRow<ID: Hashable, Mark: View, Control: View>: View {
    let id: ID
    let title: String
    let brief: String?
    let figure: String?
    /// What VoiceOver says for the row where its parts read together would not say it whole — a
    /// rule's kind, which the row shows only as its mark. Nothing reads the parts.
    let spoken: String?
    @Binding var selection: ID?
    let onOpen: () -> Void
    /// ↑ is −1 and ↓ is +1. Nothing where the list walks itself.
    let onStep: ((Int) -> Void)?
    let mark: Mark
    let control: Control

    @FocusState private var focused: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    init(
        id: ID, title: String, brief: String? = nil, figure: String? = nil, spoken: String? = nil,
        selection: Binding<ID?>, onOpen: @escaping () -> Void, onStep: ((Int) -> Void)? = nil,
        @ViewBuilder mark: () -> Mark, @ViewBuilder control: () -> Control
    ) {
        self.id = id
        self.title = title
        self.brief = brief
        self.figure = figure
        self.spoken = spoken
        _selection = selection
        self.onOpen = onOpen
        self.onStep = onStep
        self.mark = mark()
        self.control = control()
    }

    private var selected: Bool { selection == id }

    var body: some View {
        HStack(spacing: 0) {
            entry
            control
                .padding(.trailing, ShellSpace.step)
        }
        .background(plate)
        .overlay(alignment: .leading) { lamp }
        .onHover { hovering = $0 }
    }

    private var entry: some View {
        ShellListRowFace(title: title, brief: brief, figure: figure, selected: selected, mark: mark)
            .contentShape(Rectangle())
            .onTapGesture(perform: press)
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            // The keyboard follows the lamp: a row lit by ↓ takes the focus, so Return is heard
            // by the row that is lit and not by the one the step left.
            .onChange(of: selected) { _, now in if now { focused = true } }
            .onKeyPress(.return) { enter() ? .handled : .ignored }
            .onKeyPress(keys: [.upArrow, .downArrow]) { key in
                step(up: key.key == .upArrow) ? .handled : .ignored
            }
            .accessibilityElement(children: .combine)
            .modifier(ShellSpokenLabel(spoken: spoken))
            .accessibilityAddTraits(traits)
            .accessibilityHint(L10n.t("list.open.hint"))
            .accessibilityAction { onOpen() }
    }

    /// A row is a press, and the lit one says so.
    private var traits: AccessibilityTraits {
        selected ? [.isButton, .isSelected] : .isButton
    }

    /// A press: light the row, or open the row already lit.
    func press() {
        switch ShellListEntry.pressed(id, selected: selection) {
        case .select: selection = id
        case .open: onOpen()
        }
    }

    /// Return: the lit row opens. A row that holds the keyboard opens too, but only in a list that
    /// does not walk by `onStep` — there the lamp is the one answer to "which row", and a focus
    /// left behind by a step is not.
    func enter() -> Bool {
        guard selected || (onStep == nil && focused) else { return false }
        onOpen()
        return true
    }

    /// ↑ or ↓: handed to the list, which knows what is next. Refused where it walks itself.
    func step(up: Bool) -> Bool {
        guard let onStep else { return false }
        onStep(up ? -1 : 1)
        return true
    }

    private var plate: some View {
        RoundedRectangle(cornerRadius: RailView.Metrics.wellRadius, style: .continuous)
            .fill(plateFill)
    }

    private var plateFill: Color {
        if selected { return ShellChrome.selectFill(colorScheme) }
        return hovering || focused ? ShellChrome.hoverFill(colorScheme) : .clear
    }

    @ViewBuilder
    private var lamp: some View {
        if selected {
            Rectangle()
                .fill(ShellChrome.phosphor(colorScheme))
                .frame(width: ShellSpace.hair * 2)
        }
    }
}

/// A row's own spoken label, where it has one; otherwise its parts are read as they are.
private struct ShellSpokenLabel: ViewModifier {
    let spoken: String?

    func body(content: Content) -> some View {
        if let spoken {
            content.accessibilityLabel(spoken)
        } else {
            content
        }
    }
}

extension ShellListRow where Control == EmptyView {
    /// A row with nothing of its own after the chevron.
    init(
        id: ID, title: String, brief: String? = nil, figure: String? = nil, spoken: String? = nil,
        selection: Binding<ID?>, onOpen: @escaping () -> Void, onStep: ((Int) -> Void)? = nil,
        @ViewBuilder mark: () -> Mark
    ) {
        self.init(
            id: id, title: title, brief: brief, figure: figure, spoken: spoken, selection: selection,
            onOpen: onOpen, onStep: onStep, mark: mark, control: { EmptyView() }
        )
    }
}

/// What a row shows, apart from how it is entered: small enough for a type checker, and drawn by
/// a test without a list round it.
///
/// **At the accessibility sizes the figure goes under the title**, where it has the row's width,
/// rather than taking the width the title needs beside it.
struct ShellListRowFace<Mark: View>: View {
    let title: String
    let brief: String?
    let figure: String?
    let selected: Bool
    let mark: Mark

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ShellMetric(relativeTo: .callout) private var side: CGFloat = 28

    /// Whether the figure is stacked under the title rather than set beside it.
    static func stacks(at size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    var body: some View {
        let stacked = Self.stacks(at: typeSize)
        HStack(alignment: .center, spacing: ShellSpace.step) {
            plate
            words(stacked: stacked)
            Spacer(minLength: ShellSpace.snug)
            if !stacked { figureText }
            Image(systemName: "chevron.right")
                .shellFont(.mark, weight: .semibold)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ShellSpace.step)
        .padding(.vertical, ShellSpace.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var figureText: some View {
        if let figure {
            Text(figure)
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var plate: some View {
        mark
            .foregroundStyle(selected ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: RailView.Metrics.wellRadius, style: .continuous)
                    .fill(ShellChrome.well(colorScheme))
            )
            .accessibilityHidden(true)
    }

    private func words(stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: ShellSpace.hair) {
            Text(title)
                .shellFont(.name)
                .foregroundStyle(selected ? ShellChrome.selectInk(colorScheme) : ShellChrome.ink(colorScheme))
                .lineLimit(2)
            if let brief {
                Text(brief)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(2)
            }
            if stacked { figureText }
        }
    }
}
