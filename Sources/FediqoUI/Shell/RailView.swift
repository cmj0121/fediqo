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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RailButton(
                symbol: expanded ? "sidebar.leading" : "sidebar.trailing",
                title: L10n.t(expanded ? "rail.collapse.title" : "rail.open.title"),
                summary: L10n.t(expanded ? "rail.collapse.summary" : "rail.open.summary"),
                selected: false,
                expanded: expanded,
                action: {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                }
            )
            .padding(.bottom, Metrics.side)

            ForEach(ShellPlace.allCases) { item in
                // A place that cannot be entered says why on the bar itself. It used to
                // say it only to a pointer that stopped over it, which on a touch screen
                // is nobody.
                let plain = item == .account ? accountSummary : item.summary
                let summary = availability.reasonKey(for: item).map { L10n.t($0) } ?? plain
                RailButton(
                    symbol: item.symbolName,
                    title: item.title,
                    summary: summary,
                    selected: place == item,
                    expanded: expanded,
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
                enabled: availability.canCompose,
                action: onCompose
            )
        }
        .padding(.vertical, Metrics.pad)
        .padding(.horizontal, Metrics.side)
        .frame(width: expanded ? Metrics.expandedWidth : Metrics.collapsedWidth, alignment: .topLeading)
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
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: RailView.Metrics.pad) {
                glyphView
                    .frame(width: RailView.Metrics.well, height: RailView.Metrics.well)
                labels
                    .opacity(expanded ? 1 : 0)
            }
            .frame(height: RailView.Metrics.well, alignment: .leading)
            .frame(maxWidth: expanded ? .infinity : RailView.Metrics.well, alignment: .leading)
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
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glyphView: some View {
        Image(systemName: symbol)
            .font(.system(size: RailView.Metrics.iconSize, weight: selected ? .semibold : .regular))
            .symbolVariant(selected ? .fill : .none)
            .symbolRenderingMode(.hierarchical)
    }

    private var rowFill: Color {
        hovering ? ShellChrome.hoverFill(colorScheme) : .clear
    }
}
