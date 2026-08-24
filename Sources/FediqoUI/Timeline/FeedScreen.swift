import SwiftUI
import FediqoCore

/// The Timeline page, showing one of its two tabs. Public and Trending are the same screen
/// in a different mode, and that is all they share: neither ever stands in for the other. A
/// server that publishes no public timeline contributes nothing to the timeline and says
/// why, rather than being quietly topped up with whatever else it was willing to hand over.
///
/// `mode` says which feed is being read, and everything about the feed follows from it: its
/// posts, the line describing it, and which of the header controls belong to it. What a feed
/// cannot say is where it sits — so the heading, which names the page, and the list of tabs
/// beside it both come from `app.railItem` instead. A tab does not know its own page.
struct FeedScreen: View {
    let mode: FeedMode

    @Environment(AppState.self) private var app
    /// Whether there is one column's worth of room here rather than two. The shell decides
    /// it — it is the one place that knows what the platform will say — and this reads the
    /// answer rather than asking the platform a second time.
    @Environment(\.fediqoCompact) private var compact
    /// Whether the reader has gone far enough down that going back up is a journey. The
    /// button to do it in one move only exists while that is true — an arrow pointing at
    /// where you already are is a button that does nothing.
    @State private var scrolledAway = false

    /// The nothing at the top of the list, so there is something to scroll back to. The
    /// first post cannot serve: it is replaced by every refresh, and the padding above it
    /// would be left off the top of the screen.
    private static let top = "feed.top"

    private var model: FeedModel { app.feed(for: mode) }
    private var subtitleKey: String { "\(mode.rawValue).subtitle" }

    /// Sources, filter and notifications belong to the timeline. Trending is a place you go
    /// to look, so it carries none of them.
    private var showsTimelineControls: Bool { mode == .timeline }

    /// The sheets are still drawn here, over the screen they belong to. What moved is only
    /// the fact of whether they are up: a menu item and a key have to be able to ask for
    /// one from outside this screen, and a `@State` inside it can be reached by nothing.
    var body: some View {
        @Bindable var app = app
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header
                Hairline()
                body(for: model.visible)
            }
            // The ring is moved by a key, and a key can move it past the bottom of the
            // screen — which is most of what holding `j` is for. Without an anchor the list
            // moves the least it can to bring the row into view, so stepping between two
            // rows that are both already on the screen does not throw the page about.
            //
            // Only when the ring moves, so coming back to a tab does not scroll to the ring
            // that tab still holds: the list is built again at the top, the way every other
            // trip between pages and tabs already leaves it.
            .onChange(of: model.selection) { _, key in
                guard let key else { return }
                proxy.scrollTo(key)
            }
            // Back to the top, however it was asked for — the key or the button — and with
            // no animation on the way: a reader a thousand posts down asked to be at the
            // top, not to watch the thousand go past.
            .onChange(of: model.topRequests) { _, _ in
                proxy.scrollTo(Self.top, anchor: .top)
            }
        }
        .task(id: app.servers) { await model.loadIfNeeded(servers: app.servers) }
        .sheet(isPresented: $app.addingSource) {
            ServerPickerView(socialProtocol: .mastodon) { app.addingSource = false }
                .fediqoChrome(app)
        }
        .sheet(isPresented: $app.showingNotifications) {
            NotificationsSheet { app.showingNotifications = false }
                .fediqoChrome(app)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(t(app.railItem.titleKey)).fediqoFont(20, weight: .semibold).lineLimit(1)
                if model.loading { ProgressView().controlSize(.small) }
                Spacer(minLength: 4)
                controls
            }
            tabsAndSubtitle
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(HeaderBackground())
    }

    /// Which tab is showing, and the line saying what that tab is.
    ///
    /// Given a window's width they sit on one line, the control no wider than its two words
    /// need. A phone has no such width: the control there would take what it was given and
    /// leave the description a couple of characters, so the two go one above the other and
    /// the control spreads across the row, which is how a segmented control looks on iOS
    /// anyway.
    @ViewBuilder
    private var tabsAndSubtitle: some View {
        if compact {
            tabs
            subtitle
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                tabs.fixedSize()
                subtitle
            }
        }
    }

    /// The page's sub-categories, in the same segmented control the preferences use — one
    /// row of named choices where exactly one is true, which is what this is. The two feeds
    /// are the two tabs, in the order `FeedMode` lists them, which is the order the rest of
    /// the app rotates through them in.
    private var tabs: some View {
        @Bindable var app = app
        return SegmentedChoice(FeedMode.allCases, keyPrefix: "tab", selection: $app.feedTab)
    }

    /// Beside the control it is given whatever is left of the row, so it is held to two
    /// lines rather than pushing the header down. On its own row it has the width to say the
    /// whole sentence, and a sentence cut off mid-word reads as a fault rather than a note.
    private var subtitle: some View {
        Text(t(subtitleKey))
            .fediqoFont(11)
            .foregroundStyle(.secondary)
            .lineLimit(compact ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 2) {
            // Back to the top in one move. It lives with the other controls rather than
            // floating over the posts, where the composer already is on the narrow layout.
            // It asks the app rather than scrolling the list itself, so that the button and
            // `g` are one thing: both let the ring go, and both land in the same place.
            if scrolledAway {
                IconButton(symbol: "arrow.up", labelKey: "timeline.top") { app.perform(.backToTop) }
                    .transition(.opacity)
            }
            if showsTimelineControls {
                IconButton(symbol: "bell", labelKey: "timeline.notifications") { app.showingNotifications = true }
                filterMenu
                sourcesMenu
            }
            IconButton(symbol: "arrow.clockwise", labelKey: "timeline.refresh") {
                Task { await model.load(servers: app.servers) }
            }
        }
    }

    private var filterMenu: some View {
        @Bindable var preferences = app.preferences
        return Menu {
            Toggle(t("timeline.filter.boosts"), isOn: $preferences.showBoosts)
            Toggle(t("timeline.filter.mediaOnly"), isOn: $preferences.showMediaOnly)
            Divider()
            Text(t("timeline.filter.note"))
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .modifier(HeaderMenuChrome(labelKey: "timeline.filter", warning: false))
    }

    /// The sources, and what each one had to say for itself.
    ///
    /// A reason stays up until the server answers or stops being one of ours, rather than
    /// only for the loads that asked it — a server inside its backoff is a server still
    /// wanting attention, not one that quietly fixed itself for a cycle.
    ///
    /// Most reasons mean that server handed nothing over. `.tokenRejected` and `.store` are
    /// the two that arrive alongside posts that did make it: they say the account, or the
    /// local store, wants attention — not that the column is empty. Either way it is a fact
    /// about one server, so it is said next to that server rather than across the top of
    /// everything. The button carries a mark when there is something to read here, because
    /// an empty timeline and no clue where to look is indistinguishable from a broken one.
    private var sourcesMenu: some View {
        let failures = model.failures
        return Menu {
            Button(t("timeline.addSource")) { app.addingSource = true }
            Divider()
            ForEach(app.servers) { server in
                Menu {
                    if let failure = failures[server.endpoint] {
                        Text(message(for: failure))
                        Divider()
                    }
                    Button(t("timeline.remove"), role: .destructive) { app.remove(server) }
                } label: {
                    if failures[server.endpoint] == nil {
                        Text(server.host)
                    } else {
                        Label(server.host, systemImage: "exclamationmark.triangle")
                    }
                }
            }
            Divider()
            Text(t("timeline.addSource.hint"))
        } label: {
            Image(systemName: "server.rack")
        }
        .modifier(HeaderMenuChrome(labelKey: "timeline.sources", warning: !failures.isEmpty))
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for posts: [Post]) -> some View {
        if posts.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    Color.clear.frame(height: 0).id(Self.top)
                    // The id `ForEach` gives a row is the post's own `mergeKey`, and that is
                    // what the selection is written in — so scrolling to the ring is
                    // scrolling to that id, and there is no second identity to keep in step
                    // with the first.
                    ForEach(posts) { post in
                        PostRow(post: post, selected: post.mergeKey == model.selection)
                    }
                }
                .padding(12)
            }
            // Half a screen, rather than a number of points: what counts as far enough to
            // want a way back depends on how much of the list you can see at once.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y > geometry.containerSize.height / 2
            } action: { _, away in
                withAnimation(Motion.appearing) { scrolledAway = away }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let hiddenByRules = !model.result.posts.isEmpty
        VStack(spacing: 10) {
            if model.loading {
                ProgressView()
                Text(t("timeline.loading")).fediqoFont(12).foregroundStyle(.secondary)
            } else {
                Image(systemName: "tray").font(.system(size: 26, weight: .light)).foregroundStyle(.tertiary)
                Text(t(hiddenByRules ? "timeline.empty.filtered" : "timeline.empty"))
                    .fediqoFont(12)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if showsTimelineControls {
                    Button(t("timeline.addSource")) { app.addingSource = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .fediqoFont(12)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A menu button dressed as one of the plain icon buttons beside it — without this the
/// platform paints it in the accent colour and it reads as the only live control there.
private struct HeaderMenuChrome: ViewModifier {
    let labelKey: String
    let warning: Bool

    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .frame(width: 24, height: 24)
            .help(t(labelKey))
            .accessibilityLabel(Text(t(labelKey)))
    }
}

private struct HeaderBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Palette.raised(colorScheme).opacity(0.6)
    }
}

/// Notifications live inside the timeline. There is nothing to show until #9 lands, and the
/// reason there will never be a push server is worth saying on the screen that would want one.
struct NotificationsSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(t("timeline.notifications")).fediqoFont(17, weight: .semibold)
                Spacer()
                Button(t("common.close"), action: onClose).buttonStyle(.plain).fediqoFont(12).foregroundStyle(.secondary)
            }
            Text(t("timeline.notifications.empty"))
                .fediqoFont(12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 320, minHeight: 180)
    }
}
