import SwiftUI

/// The left bar: places, the account (empty until a source is joined), and compose.
///
/// Visual: a milled chassis. Each action is a square well — the slots in the mark —
/// not a stretched pill. Opening the bar only reveals labels to the right of the well.
struct RailView: View {
    @Binding var place: ShellPlace
    @Binding var expanded: Bool
    var availability: ShellAvailability
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
        static let iconSize: CGFloat = 20
        static let wellRadius: CGFloat = 3
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
    @ScaledMetric(relativeTo: .callout) private var well: CGFloat = Metrics.well
    @ScaledMetric(relativeTo: .callout) private var glyph: CGFloat = Metrics.iconSize
    @ScaledMetric(relativeTo: .callout) private var labelWidth: CGFloat = 148

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

            ForEach(ShellPlace.allCases) { item in
                // A place that cannot be entered is marked as closed at every width,
                // and says why wherever there is room for a sentence: the label beside
                // the glyph when the bar is open, the tooltip and the accessibility
                // hint when it is not. Collapsed, the bar has room for a mark and for
                // nothing else — no row shows any text there, closed or open.
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
                    action: { place = availability.placing(place, as: item) }
                )
            }

            Spacer(minLength: Metrics.pad)

            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: 1)
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
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(width: 1)
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
            .foregroundStyle(selected ? ShellChrome.selectInk(colorScheme) : ShellChrome.ink(colorScheme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(expanded ? helpText : "\(title). \(helpText)")
        .accessibilityLabel(title)
        .accessibilityHint(helpText)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
    }

    private var helpText: String { hint ?? summary }

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
                .font(selected ? ShellType.name : .callout)
                .lineLimit(1)
            Text(summary)
                .font(ShellType.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glyphView: some View {
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: selected ? .semibold : .regular))
            .symbolVariant(selected ? .fill : .none)
            .symbolRenderingMode(.hierarchical)
            .overlay { closedMark }
    }

    /// Closed, said in the space a collapsed bar actually has.
    ///
    /// It is a line struck through the glyph and not a mark in its corner. A small
    /// filled shape at the bottom-right of a bell is the one thing every reader
    /// already knows how to read, and what it says is "two of something is waiting" —
    /// the exact opposite of a place with nothing in it that cannot be opened.
    @ViewBuilder
    private var closedMark: some View {
        if !enabled {
            ZStack {
                strike(ShellChrome.rail(colorScheme), thickness: ShellSpace.tight)
                strike(ShellChrome.inkDim(colorScheme), thickness: ShellSpace.hair * 1.5)
            }
            .rotationEffect(.degrees(-45))
            .accessibilityHidden(true)
        }
    }

    private func strike(_ color: Color, thickness: CGFloat) -> some View {
        Capsule(style: .continuous)
            .fill(color)
            .frame(width: glyph * 1.2, height: thickness)
    }

    private var rowFill: Color {
        hovering ? ShellChrome.hoverFill(colorScheme) : .clear
    }
}
