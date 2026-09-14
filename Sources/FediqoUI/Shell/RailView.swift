import SwiftUI

/// The left bar: places, the account that is this timeline's source, and compose.
///
/// Visual: a milled chassis. Each action is a square well — the slots in the mark —
/// not a stretched pill. Opening the bar only reveals labels to the right of the well.
struct RailView: View {
    @Binding var place: ShellPlace
    @Binding var expanded: Bool
    var currentSource: DummySource
    var onCompose: () -> Void

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
            .padding(.bottom, Self.side)

            ForEach(ShellPlace.allCases) { item in
                RailButton(
                    symbol: item.symbolName,
                    title: item == .account ? accountTitle : item.title,
                    summary: item == .account ? accountSummary : item.summary,
                    selected: place == item,
                    expanded: expanded,
                    action: { place = item }
                )
            }

            Spacer(minLength: Self.pad)

            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: 1)
                .padding(.vertical, Self.pad)
                .padding(.horizontal, Self.well / 4)

            RailButton(
                symbol: "square.and.pencil",
                title: L10n.t("compose.title"),
                summary: L10n.t("compose.summary"),
                selected: false,
                expanded: expanded,
                action: onCompose
            )
        }
        .padding(.vertical, Self.pad)
        .padding(.horizontal, Self.side)
        .frame(width: expanded ? Self.expandedWidth : Self.collapsedWidth, alignment: .topLeading)
        .clipped()
        .background(ShellChrome.rail(colorScheme))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(width: 1)
        }
    }

    private var accountTitle: String {
        currentSource.account?.displayName ?? currentSource.host
    }

    private var accountSummary: String {
        currentSource.account?.handle ?? L10n.t("source.unsigned")
    }
}

private struct RailButton: View {
    let symbol: String
    let title: String
    let summary: String
    let selected: Bool
    let expanded: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: RailView.pad) {
                glyphView
                    .frame(width: RailView.well, height: RailView.well)
                labels
                    .opacity(expanded ? 1 : 0)
            }
            .frame(height: RailView.well, alignment: .leading)
            .frame(maxWidth: expanded ? .infinity : RailView.well, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RailView.wellRadius, style: .continuous)
                    .fill(rowFill)
            )
            .foregroundStyle(selected ? ShellChrome.selectInk(colorScheme) : Color.primary.opacity(0.84))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? summary : "\(title). \(summary)")
        .accessibilityLabel(title)
        .accessibilityHint(summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .lineLimit(1)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glyphView: some View {
        Image(systemName: symbol)
            .font(.system(size: RailView.iconSize, weight: selected ? .semibold : .regular))
            .symbolVariant(selected ? .fill : .none)
            .symbolRenderingMode(.hierarchical)
    }

    private var rowFill: Color {
        if selected { ShellChrome.selectFill(colorScheme) }
        else if hovering { ShellChrome.hoverFill(colorScheme) }
        else { .clear }
    }
}
