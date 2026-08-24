import SwiftUI
import FediqoCore

/// Two columns: the action bar on the left, the display field on the right.
///
/// On a narrow screen — an iPhone — the destinations become a tab bar and New Post becomes
/// the button floating over it, which is the same arrangement as the rail: four places to
/// go, and one thing to do from wherever you are. The rail is a plain view rather than a
/// `NavigationSplitView` sidebar because a split view cannot be a fixed-width icon rail, and
/// how it collapses is the platform's decision rather than ours.
struct AppShell: View {
    @Environment(AppState.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var railWidth: CGFloat {
        app.preferences.railExpanded ? RailView.expandedWidth : RailView.collapsedWidth
    }

    var body: some View {
        // One clock for the whole shell, keyed to the feed being read — the page, and the
        // tab within it — and how often it is to be read. `.task(id:)` cancels the old one
        // and starts the new one on every change, and cancels it altogether when the shell
        // goes away — so there is never a second one, and never one left running for a feed
        // nobody is looking at.
        layout.task(id: app.refreshKey) { await app.refreshWhileVisible() }
    }

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if sizeClass == .compact {
            tabbed
        } else {
            columns
        }
        #else
        columns
        #endif
    }

    private var columns: some View {
        HStack(spacing: 0) {
            RailView()
            Hairline(axis: .vertical)
            view(for: app.railItem)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.surface(colorScheme))
        }
        // The floor, and only the floor. Anything larger is the reader's business, and
        // anything that made this bigger than it needs to be was a bug.
        .frame(minWidth: 420, minHeight: 300)
        // Beside the bar, at the foot, next to the button that opened it.
        .composerPanel(
            alignment: .bottomLeading,
            inset: EdgeInsets(top: 0, leading: railWidth + 10, bottom: 10, trailing: 0)
        )
    }

    #if os(iOS)
    private var tabbed: some View {
        @Bindable var app = app
        return TabView(selection: $app.railItem) {
            ForEach(RailItem.allCases) { item in
                view(for: item)
                    .background(Palette.surface(colorScheme))
                    .tabItem { Label(t(item.titleKey), systemImage: item.symbolName) }
                    .tag(item)
            }
        }
        .overlay(alignment: .bottomTrailing) { composeButton }
        .composerPanel(
            alignment: .bottomTrailing,
            inset: EdgeInsets(top: 0, leading: 0, bottom: 140, trailing: 16)
        )
    }

    private var composeButton: some View {
        Button { app.toggleComposer() } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(Circle().fill(Palette.accent))
                .foregroundStyle(Color.black.opacity(0.85))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
        .padding(.bottom, 72)
        .accessibilityLabel(Text(t("rail.compose")))
    }
    #endif

    @ViewBuilder
    private func view(for item: RailItem) -> some View {
        switch item {
        // A tab is its own screen, not the same screen handed different posts: the identity
        // is the tab's, so neither feed inherits the other's scroll position or its open
        // menus. What outlives the swap is what should — the two `FeedModel`s, which the app
        // holds rather than the screen, so nothing is re-asked and nothing is thrown away.
        //
        // The price is paid in both directions, and it is the price we chose. Going back to
        // a tab builds it afresh: its `.task` runs again — which asks the model nothing it
        // has already been asked — and the scroll position and any open sheet are gone.
        // Remembering where each tab was left is not something anybody asked for, and it
        // would cost the clean swap above; if it is ever wanted, it is state to hold beside
        // the feeds rather than a reason to drop this `.id`.
        case .timeline: FeedScreen(mode: app.feedTab).id(app.feedTab)
        case .kept: KeptView()
        case .statistics: StatisticsView()
        case .settings: SettingsView()
        }
    }
}
