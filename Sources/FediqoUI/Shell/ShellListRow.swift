import SwiftUI

/// How a list answers the reader (#232) — **rule 3 of #231, as a rule and not a copy.**
///
/// The timeline's rule, made to take any id: a press on a row that is not lit lights it, a press
/// on the lit row opens it, and Return opens the lit row. `DummyCommand.tapped` asks this, so the
/// stream and every other list cannot come to answer a press differently.
enum ShellListEntry {
    /// What a press on `id` does, given the row that is lit.
    static func pressed<ID: Equatable>(_ id: ID, selected: ID?) -> DummyRowTap {
        selected == id ? .open : .select
    }
}

/// One row of a list (#232): a mark, a title, one brief line, and the figure that matters most —
/// and a way in to the rest. The rest is the row's detail, and entering the row opens it.
///
///     [mark]  title                              figure  ›
///             one brief line
///
/// **Entering, three ways, one outcome.** A press lights the row and a second press opens it
/// (`ShellListEntry.pressed`); Return opens the lit row; and
/// VoiceOver, whose reader activates once, opens in one — the row's default action. A row the
/// keyboard is on wears the hover plate and opens on Return too; focus does not light it, because
/// a click focuses before it presses and would turn every first press into an open.
///
/// **The chevron is what says there is more.** A row that opens nothing is not this row.
///
/// Lit on the lamp's wash with the lamp in its margin, the way the rail and the stream say where
/// the reader is; the plate is `RailView`'s radius, so the list is machined like the rest.
struct ShellListRow<ID: Hashable, Mark: View>: View {
    let id: ID
    let title: String
    let brief: String?
    let figure: String?
    @Binding var selection: ID?
    let onOpen: () -> Void
    let mark: Mark

    @FocusState private var focused: Bool
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    init(
        id: ID, title: String, brief: String? = nil, figure: String? = nil,
        selection: Binding<ID?>, onOpen: @escaping () -> Void, @ViewBuilder mark: () -> Mark
    ) {
        self.id = id
        self.title = title
        self.brief = brief
        self.figure = figure
        _selection = selection
        self.onOpen = onOpen
        self.mark = mark()
    }

    private var selected: Bool { selection == id }

    var body: some View {
        ShellListRowFace(title: title, brief: brief, figure: figure, selected: selected, mark: mark)
            .background(plate)
            .overlay(alignment: .leading) { lamp }
            .contentShape(Rectangle())
            .onTapGesture(perform: press)
            .onHover { hovering = $0 }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.return) { enter() ? .handled : .ignored }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(L10n.t("list.open.hint"))
            .accessibilityAction { onOpen() }
    }

    /// A press: light the row, or open the row already lit.
    func press() {
        switch ShellListEntry.pressed(id, selected: selection) {
        case .select: selection = id
        case .open: onOpen()
        }
    }

    /// Return: the lit row opens, or the row the keyboard is on. Refused on any other row.
    func enter() -> Bool {
        guard selected || focused else { return false }
        onOpen()
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

/// What a row shows, apart from how it is entered: small enough for a type checker, and drawn by
/// a test without a list round it.
struct ShellListRowFace<Mark: View>: View {
    let title: String
    let brief: String?
    let figure: String?
    let selected: Bool
    let mark: Mark

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .callout) private var side: CGFloat = 28

    var body: some View {
        HStack(alignment: .center, spacing: ShellSpace.step) {
            plate
            words
            Spacer(minLength: ShellSpace.snug)
            if let figure {
                Text(figure)
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(1)
                    .fixedSize()
            }
            Image(systemName: "chevron.right")
                .shellFont(.mark, weight: .semibold)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, ShellSpace.step)
        .padding(.vertical, ShellSpace.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var words: some View {
        VStack(alignment: .leading, spacing: ShellSpace.hair) {
            Text(title)
                .shellFont(.name)
                .foregroundStyle(selected ? ShellChrome.selectInk(colorScheme) : ShellChrome.ink(colorScheme))
                .lineLimit(2)
            if let brief {
                Text(brief)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(1)
            }
        }
    }
}
