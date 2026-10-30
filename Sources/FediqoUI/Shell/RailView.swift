import SwiftUI

/// The left bar: places, the account (empty until a source is joined), and compose.
///
/// Visual: a milled chassis. Each action is a square well — the slots in the mark —
/// not a stretched pill. Opening the bar only reveals labels to the right of the well.
struct RailView: View {
    @Binding var place: ShellPlace
    @Binding var expanded: Bool
    var availability: ShellAvailability
    /// What waits at a place, counted: the notices told since that page was last in front (#324).
    var counts: [ShellPlace: Int] = [:]
    /// The place already in front, pressed again: the top of its list, as `g` goes (glacial's
    /// sidebar does the same).
    var onAgain: () -> Void = {}
    var onCompose: () -> Void

    /// Layout numbers. Here rather than as statics on the View: a View's static is
    /// main-actor isolated on the runner's Swift, and the tests that hold these
    /// numbers are not.
    enum Metrics {
        /// 1rem = 16pt.
        static let rem: CGFloat = 16
        static let pad: CGFloat = rem * 0.3
        static let side: CGFloat = rem * 0.5
        /// The square plate the glyph sits on. Row height equals this, so open/collapse does not jump.
        static let well: CGFloat = 32
        /// **`well - snug`, and not a literal.** The row already states this rule for its own
        /// controls — `SourceRow.symbolPoints` is `touch - snug`, "leaving `ShellSpace.snug` of
        /// the target around it" — and applied here it gives 24, which is
        /// `SourceRow.markBase`, the base `SourceRowView.mark` grows from. **One number, three surfaces: every mark in this app is
        /// 24pt at the default rung.** A mark at the full 32 would fill its plate edge to edge.
        ///
        /// **No metric moves with it.** The glyph lives inside a `well`-sized frame, so
        /// `collapsedWidth` stays 48, `expandedWidth` stays 201, the row stays 32 tall, and the
        /// macOS minimum page stays 318.
        static let iconSize: CGFloat = well - ShellSpace.snug
        static let wellRadius = ShellRadius.well
        static let rowInnerHeight: CGFloat = well
        static let collapsedWidth: CGFloat = side + well + side
        static let expandedWidth: CGFloat = side + well + pad + 148 + side
    }

    @Environment(\.colorScheme) private var colorScheme

    /// The base numbers above are what the bar measures at the standard type size.
    /// These are what it measures at the reader's. The bar used to be fixed, which
    /// was fine while the label was one line of the system's default; a step up the
    /// type ladder made two lines of it, and two lines do not fit in 32 points — the
    /// rows overlapped each other rather than the bar getting taller.
    @ShellMetric(relativeTo: .callout) private var well: CGFloat = Metrics.well
    @ShellMetric(relativeTo: .callout) private var glyph: CGFloat = Metrics.iconSize
    @ShellMetric(relativeTo: .callout) private var labelWidth: CGFloat = 148

    private var collapsedWidth: CGFloat { Metrics.side + well + Metrics.side }
    private var expandedWidth: CGFloat {
        Metrics.side + well + Metrics.pad + labelWidth + Metrics.side
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RailButton(
                symbol: expanded ? "sidebar.leading" : "sidebar.trailing",
                title: L10n.t(expanded ? "rail.collapse.title" : "rail.open.title"),
                summary: L10n.t(expanded ? "rail.collapse.summary" : "rail.open.summary"),
                selected: false,
                expanded: expanded,
                well: well,
                glyph: glyph,
                action: {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                }
            )
            .padding(.bottom, Metrics.side)

            ForEach(availability.railPlaces) { item in
                // A place that cannot be entered is drawn grey at every width, its mark
                // unchanged, and says why wherever there is room for a sentence: the
                // label beside the glyph when the bar is open, the tooltip and the
                // accessibility hint when it is not.
                let plain = item == .account ? accountSummary : item.summary
                let summary = availability.reasonKey(for: item).map { L10n.t($0) } ?? plain
                RailButton(
                    symbol: item.symbolName,
                    title: item.title,
                    summary: summary,
                    selected: place == item,
                    expanded: expanded,
                    well: well,
                    glyph: glyph,
                    enabled: availability.allows(item),
                    count: counts[item] ?? 0,
                    action: {
                        if place == item { onAgain() } else { place = availability.placing(place, as: item) }
                    }
                )
            }

            Spacer(minLength: Metrics.pad)

            ShellRule()
                .padding(.vertical, Metrics.pad)
                .padding(.horizontal, Metrics.well / 4)

            RailButton(
                symbol: "square.and.pencil",
                title: L10n.t("compose.title"),
                summary: L10n.t("compose.summary"),
                hint: L10n.t(availability.composeHintKey),
                selected: false,
                expanded: expanded,
                well: well,
                glyph: glyph,
                enabled: availability.canCompose,
                action: onCompose
            )
        }
        .padding(.vertical, Metrics.pad)
        .padding(.horizontal, Metrics.side)
        .frame(width: expanded ? expandedWidth : collapsedWidth, alignment: .topLeading)
        .clipped()
        .background(ShellChrome.rail(colorScheme))
        .overlay(alignment: .trailing) {
            ShellRule(.vertical)
        }
    }

    private var accountSummary: String {
        L10n.t("account.rail.empty")
    }
}

private struct RailButton: View {
    let symbol: String
    let title: String
    let summary: String
    var hint: String? = nil
    let selected: Bool
    let expanded: Bool
    let well: CGFloat
    let glyph: CGFloat
    var enabled: Bool = true
    /// How many wait there (#324): a mark in the glyph's corner, said as the row's value.
    var count = 0
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: RailView.Metrics.pad) {
                glyphView
                    .frame(width: well, height: well)
                // Built only when the bar is open. Drawn at zero opacity it still
                // takes the room it needs, which is what a collapsed bar has none of.
                if expanded { labels }
            }
            .frame(minHeight: well, alignment: .leading)
            .frame(maxWidth: expanded ? .infinity : well, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RailView.Metrics.wellRadius, style: .continuous)
                    .fill(rowFill)
            )
            .overlay(alignment: .leading) { lamp }
            .foregroundStyle(ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(expanded ? helpText : "\(title). \(helpText)")
        .accessibilityLabel(title)
        .accessibilityHint(helpText)
        .accessibilityValue(count > 0 ? L10n.count("rail.count", count) : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
    }

    private var helpText: String { hint ?? summary }

    /// Closed is grey and nothing else (2026-10-30): the mark stays the place's own, as the
    /// person knows it, and is only drawn in the dim ink.
    private var ink: Color {
        if selected { return ShellChrome.selectInk(colorScheme) }
        return enabled ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme)
    }

    /// Where the reader is, drawn in the rail's own margin so that selecting a row
    /// moves nothing. The lamp is the only phosphor on the bar.
    @ViewBuilder
    private var lamp: some View {
        if selected {
            Rectangle()
                .fill(ShellChrome.phosphor(colorScheme))
                .frame(width: ShellSpace.hair * 2)
                .offset(x: -RailView.Metrics.side)
        }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: ShellSpace.hair) {
            Text(title)
                // `name` is `callout` at semibold, so the selected/unselected pair is one role
                // at two weights rather than two fonts — which is also what lets it move with
                // the type-size preference (#96).
                .shellFont(.name, weight: selected ? .semibold : .regular)
                .lineLimit(1)
            Text(summary)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glyphView: some View {
        Image(systemName: ShellGlyph.drawn(symbol, chosen: selected))
            .font(.system(size: glyph, weight: selected ? .semibold : .regular))
            .symbolRenderingMode(.hierarchical)
            .overlay(alignment: .topTrailing) { countMark }
    }

    /// The count, in the corner a count is read in: "so many wait here".
    @ViewBuilder
    private var countMark: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: glyph * 0.42, weight: .semibold).monospacedDigit())
                .foregroundStyle(ShellChrome.page(colorScheme))
                .padding(.horizontal, ShellSpace.hair * 2)
                .background(Capsule(style: .continuous).fill(ShellChrome.phosphor(colorScheme)))
                .offset(x: glyph * 0.2, y: -glyph * 0.15)
                .accessibilityHidden(true)
        }
    }

    private var rowFill: Color {
        hovering ? ShellChrome.hoverFill(colorScheme) : .clear
    }
}
