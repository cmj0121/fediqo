import SwiftUI

/// The keys, written down.
///
/// One view, and both places that show the keys show this one: the overlay `?` puts up, and
/// the card at the foot of Settings for a reader who has never pressed `?`. The lines come
/// from `KeyCommand.shortcuts` rather than from anything typed here, so the list cannot come
/// to disagree with the keys that actually work.
struct ShortcutList: View {
    private let groups = KeyCommand.ShortcutGroup.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: Space.pad) {
            // Said first, because it is the thing that decides whether any of the rest is
            // of use to the reader holding the screen.
            Text(t("shortcut.note"))
                .fediqoFont(TypeScale.minor)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // One grid for all three groups rather than one each, so the keys line up down
            // the whole list instead of forming three columns of different widths.
            Grid(alignment: .topLeading, horizontalSpacing: Space.gap, verticalSpacing: Space.step) {
                ForEach(groups) { group in
                    GridRow {
                        Text(t(group.titleKey))
                            .fediqoFont(TypeScale.caption, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            // Air above a heading that follows a group, and none above the
                            // first, which already has the card's padding over it.
                            .padding(.top, group == groups.first ? 0 : Space.snug)
                            .gridCellColumns(2)
                    }
                    ForEach(KeyCommand.byGroup[group] ?? []) { shortcut in
                        GridRow {
                            keys(of: shortcut)
                            Text(t(shortcut.detailKey))
                                .fediqoFont(TypeScale.small)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// The caps themselves, as the small capsules the rest of the app marks a thing with.
    private func keys(of shortcut: KeyCommand.Shortcut) -> some View {
        HStack(spacing: Space.tight) {
            ForEach(shortcut.keys, id: \.self) { cap in
                Text(cap).fediqoFont(TypeScale.minor, design: .monospaced).fediqoPill()
            }
        }
        .fixedSize()
    }
}

/// The list, over whatever you were looking at, and the sheet of nothing behind it.
///
/// The same arrangement as the composer's panel and for the same reason: where a platform
/// popover lands is the platform's decision, and this one has to land in the middle of the
/// window on both platforms. `Escape` closes it through `dismissFront`, so it joins the one
/// chain every dismissal in the app goes through rather than keeping a second one.
private struct ShortcutsOverlay: ViewModifier {
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        ZStack {
            content

            if app.showingShortcuts {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { app.setShowingShortcuts(false) }

                card
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            HStack {
                Text(t("shortcut.title")).fediqoFont(TypeScale.section, weight: .semibold)
                Spacer()
                Button(t("common.close")) { app.setShowingShortcuts(false) }
                    .buttonStyle(.plain)
                    .fediqoFont(TypeScale.small)
                    .foregroundStyle(.secondary)
            }
            // The card is as tall as the list and no taller — but a short window, or a
            // large text size, must not cut the last line off with no way to reach it, so
            // where the list does not fit it scrolls instead.
            ViewThatFits(in: .vertical) {
                ShortcutList()
                ScrollView {
                    ShortcutList()
                }
            }
        }
        .padding(Space.room)
        // Width only. A `maxHeight` here would be a height rather than a ceiling: given a
        // finite proposal the frame takes all of it, and the card would stand at its
        // ceiling with the list floating in the middle of it. The height is the list's, and
        // where the list has to scroll the branch above already fills what it is given.
        .frame(maxWidth: Size.prose)
        .fediqoCard(radius: Radius.panel, shadow: true)
        .padding(Space.band)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}

extension View {
    func shortcutsOverlay() -> some View {
        modifier(ShortcutsOverlay())
    }
}
