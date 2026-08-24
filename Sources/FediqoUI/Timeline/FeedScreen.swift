import SwiftUI
import FediqoCore

/// The right-hand column. Timeline and Trending are the same screen in a different mode, and
/// that is all they share: neither ever stands in for the other. A server that publishes no
/// public timeline contributes nothing to the timeline and says why, rather than being
/// quietly topped up with whatever else it was willing to hand over.
///
/// Everything the screen needs follows from the mode, so there is nothing to pass that could
/// disagree with it.
struct FeedScreen: View {
    let mode: FeedMode

    @Environment(AppState.self) private var app
    @State private var addingSource = false
    @State private var showingNotifications = false

    private var model: FeedModel { app.feed(for: mode) }
    private var titleKey: String { "\(mode.rawValue).title" }
    private var subtitleKey: String { "\(mode.rawValue).subtitle" }

    /// Sources, filter and notifications belong to the timeline. Trending is a place you go
    /// to look, so it carries none of them.
    private var showsTimelineControls: Bool { mode == .timeline }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            body(for: model.visible(preferences: app.preferences))
        }
        .task(id: app.servers) { await model.loadIfNeeded(servers: app.servers) }
        .sheet(isPresented: $addingSource) {
            ServerPickerView(socialProtocol: .mastodon) { addingSource = false }
                .fediqoChrome(app)
        }
        .sheet(isPresented: $showingNotifications) {
            NotificationsSheet { showingNotifications = false }
                .fediqoChrome(app)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(t(titleKey)).fediqoFont(20, weight: .semibold).lineLimit(1)
                if model.loading { ProgressView().controlSize(.small) }
                Spacer(minLength: 4)
                controls
            }
            Text(t(subtitleKey)).fediqoFont(11).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(HeaderBackground())
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 2) {
            if showsTimelineControls {
                IconButton(symbol: "bell", labelKey: "timeline.notifications") { showingNotifications = true }
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
    /// Most reasons mean that server handed nothing over. `.tokenRejected` and `.store` are
    /// the two that arrive alongside posts that did make it: they say the account, or the
    /// local store, wants attention — not that the column is empty. Either way it is a fact
    /// about one server, so it is said next to that server rather than across the top of
    /// everything. The button carries a mark when there is something to read here, because
    /// an empty timeline and no clue where to look is indistinguishable from a broken one.
    private var sourcesMenu: some View {
        let failures = model.result.failures
        return Menu {
            Button(t("timeline.addSource")) { addingSource = true }
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
                    ForEach(posts) { PostRow(post: $0) }
                }
                .padding(12)
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
                    Button(t("timeline.addSource")) { addingSource = true }
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
