import SwiftUI

/// The action bar. Icon-only by default; the labels are there when it is opened, and the
/// same items become the tab bar on a narrow screen.
///
/// New Post sits at the foot, apart from the four destinations above it, because it is not
/// one: it opens over whatever you were already looking at and leaves again.
struct RailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    static let collapsedWidth: CGFloat = 52
    static let expandedWidth: CGFloat = 184

    var body: some View {
        let expanded = app.preferences.railExpanded

        VStack(alignment: .leading, spacing: 4) {
            toggle(expanded: expanded)
                .padding(.bottom, 6)

            ForEach(RailItem.allCases) { item in
                button(item, expanded: expanded)
            }

            Spacer(minLength: 8)

            Hairline().padding(.bottom, 6)

            composeButton(expanded: expanded)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 10)
        .frame(width: expanded ? Self.expandedWidth : Self.collapsedWidth, alignment: .leading)
        .background(Palette.raised(colorScheme))
    }

    private func toggle(expanded: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                app.preferences.railExpanded.toggle()
            }
        } label: {
            Image(systemName: expanded ? "sidebar.leading" : "sidebar.trailing")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(t(expanded ? "rail.collapse" : "rail.expand"))
        .accessibilityLabel(Text(t(expanded ? "rail.collapse" : "rail.expand")))
        .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
    }

    private func button(_ item: RailItem, expanded: Bool) -> some View {
        let selected = app.railItem == item
        return Button {
            app.railItem = item
        } label: {
            rowLabel(
                symbol: item.symbolName,
                titleKey: item.titleKey,
                expanded: expanded,
                weight: selected ? .semibold : .regular
            )
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Palette.accent.opacity(colorScheme == .dark ? 0.22 : 0.18) : .clear)
            )
            .foregroundStyle(selected ? Palette.accent : Color.primary.opacity(0.75))
        }
        .buttonStyle(.plain)
        .help(t(item.titleKey))
        .accessibilityLabel(Text(t(item.titleKey)))
        .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
    }

    private func composeButton(expanded: Bool) -> some View {
        Button {
            app.toggleComposer()
        } label: {
            rowLabel(symbol: "square.and.pencil", titleKey: "rail.compose", expanded: expanded, weight: .semibold)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.accent.opacity(colorScheme == .dark ? 0.20 : 0.16))
                )
                .foregroundStyle(Palette.accent)
        }
        .buttonStyle(.plain)
        .help(t("rail.compose"))
        .accessibilityLabel(Text(t("rail.compose")))
        .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
    }

    private func rowLabel(symbol: String, titleKey: String, expanded: Bool, weight: Font.Weight) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: weight))
                .frame(width: 20)
            if expanded {
                Text(t(titleKey))
                    .fediqoFont(13, weight: weight)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: expanded ? Self.expandedWidth - 28 : 30, alignment: expanded ? .leading : .center)
        .padding(.vertical, 7)
        .padding(.horizontal, expanded ? 7 : 0)
        .contentShape(Rectangle())
    }
}
