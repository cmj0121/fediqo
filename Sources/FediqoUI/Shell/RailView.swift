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
    /// The box the open-and-close control is, which is wider than a row's icon and shorter
    /// than a row: it is the one thing in the bar that is about the bar rather than a place.
    private static let toggleTile = CGSize(width: 34, height: 30)

    var body: some View {
        let expanded = app.preferences.railExpanded

        VStack(alignment: .leading, spacing: Space.tight) {
            toggle(expanded: expanded)
                .padding(.bottom, Space.snug)

            ForEach(RailItem.allCases) { item in
                button(item, expanded: expanded)
            }

            Spacer(minLength: Space.step)

            Hairline().padding(.bottom, Space.snug)

            yourPageButton(expanded: expanded)
            composeButton(expanded: expanded)
        }
        .padding(.horizontal, Space.step)
        .padding(.vertical, Space.mid)
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
                .fediqoSymbol(Glyph.lead, weight: .medium)
                .frame(width: Self.toggleTile.width, height: Self.toggleTile.height)
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
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .fill(selected ? Palette.accent.opacity(colorScheme == .dark ? 0.22 : 0.18) : .clear)
            )
            .foregroundStyle(selected ? Palette.accent : Color.primary.opacity(0.75))
        }
        .buttonStyle(.plain)
        .help(t(item.titleKey))
        .accessibilityLabel(Text(t(item.titleKey)))
        .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
    }

    /// The way to your own page (#110).
    ///
    /// #88 built the page and the only way in was pressing an author on a row — so to see your
    /// own you had to happen across one of your own posts in a timeline you were reading. A door
    /// rather than a coincidence.
    ///
    /// **One per account, because a reader signed in to three servers is three people.** Each
    /// has their own page, asked of the server that account is on, and their own unsent posts.
    /// With one there is nothing to choose and it is a button; with several it is a menu that
    /// names them, because "your page" would be a question the app answered on their behalf.
    @ViewBuilder
    private func yourPageButton(expanded: Bool) -> some View {
        let accounts = app.yourAccounts
        if accounts.count == 1, let only = accounts.first {
            Button { app.openYourPage(only) } label: {
                rowLabel(symbol: "person.crop.circle", titleKey: "rail.me", expanded: expanded, weight: .regular)
            }
            .buttonStyle(.plain)
            .help(t("rail.me"))
            .accessibilityLabel(Text(t("rail.me")))
        } else if accounts.count > 1 {
            Menu {
                ForEach(accounts, id: \.self) { handle in
                    Button(handle) { app.openYourPage(handle) }
                }
            } label: {
                rowLabel(symbol: "person.crop.circle", titleKey: "rail.me", expanded: expanded, weight: .regular)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(t("rail.me"))
            .accessibilityLabel(Text(t("rail.me")))
        }
    }

    private func composeButton(expanded: Bool) -> some View {
        Button {
            app.toggleComposer()
        } label: {
            rowLabel(symbol: "square.and.pencil", titleKey: "rail.compose", expanded: expanded, weight: .semibold)
                .background(
                    RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
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
        HStack(spacing: Space.mid) {
            Image(systemName: symbol)
                // The bar is icons and nothing else when it is closed, so the icon is the
                // whole of what a reader has to aim at and to recognise. Drawn at the size a
                // toolbar icon is rather than the size a word is: it is not sitting beside
                // text here, it is standing in for it.
                .fediqoSymbol(Glyph.lead, weight: weight)
                .frame(width: Size.iconColumn)
            if expanded {
                Text(t(titleKey))
                    .fediqoFont(TypeScale.body, weight: weight)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: expanded ? Self.expandedWidth - Space.pad * 2 : Size.wideIconColumn,
               alignment: expanded ? .leading : .center)
        .padding(.vertical, Space.step)
        .padding(.horizontal, expanded ? 7 : 0)
        .contentShape(Rectangle())
    }
}
