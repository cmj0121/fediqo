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
    /// Whether the reader has gone far enough down that going back up is a journey. The
    /// button to do it in one move only exists while that is true — an arrow pointing at
    /// where you already are is a button that does nothing.
    @State private var scrolledAway = false
    /// Whether the toast is up. The feed decides *that* the end was reached; how long a passing
    /// message stays and how it goes are the screen's, the way the scrolling already is.
    @State private var announcing = false
    /// The colour scheme, for the two marks drawn by hand at the foot of the list. Everything
    /// else here is `fediqoCard` or `Hairline`, which read it themselves.
    @Environment(\.colorScheme) private var colorScheme
    /// The app's language, carried down by `fediqoChrome`, so the date at the foot of the list
    /// is written the way the reader's own language writes one.
    @Environment(\.locale) private var locale
    /// A reader who asked for less movement. The toast still comes and still goes — it is the
    /// fade that is the decoration, not the message.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The nothing at the top of the list, so there is something to scroll back to. The
    /// first post cannot serve: it is replaced by every refresh, and the padding above it
    /// would be left off the top of the screen.
    private static let top = "feed.top"

    /// How long the toast stands. Long enough to read four words, short enough that a reader
    /// who was looking at the marker instead is not covered up for long.
    private static let announcementLasts = Duration.milliseconds(2500)

    private var fading: Animation? { reduceMotion ? nil : Motion.appearing }

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
            // brings it to the middle, so what you are reading has its own context above and
            // below it rather than sitting against an edge with the next post already gone.
            // Near either end there is not enough list to centre against and it settles for
            // as close as it can get, which is what a reader at the top or bottom expects
            // anyway.
            //
            // Only when the ring moves, so coming back to a tab does not scroll to the ring
            // that tab still holds: the list is built again at the top, the way every other
            // trip between pages and tabs already leaves it.
            .onChange(of: model.selection) { _, key in
                guard let key else { return }
                proxy.scrollTo(key, anchor: .center)
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

    /// The heading names the page, and the tabs beside it are the page's — so both come from
    /// `app.railItem` rather than from the feed. A tab does not know its own page.
    private var header: some View {
        @Bindable var app = app
        return PageHeader(titleKey: app.railItem.titleKey, subtitleKey: subtitleKey,
                          loading: model.loading) {
            SegmentedChoice(FeedMode.allCases, keyPrefix: "tab", selection: $app.feedTab)
        } controls: {
            controls
        }
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
    ///
    /// The stored timeline is the one line here that belongs to no server. A reach for the
    /// bottom reads it before anybody is asked, so a store that will not answer is a reason
    /// posts are not arriving — which is what this menu is for — and it is said on its own
    /// rather than pinned on whichever server was about to be asked next.
    private var sourcesMenu: some View {
        let failures = model.failures
        let storeFailure = model.storeFailure
        return Menu {
            Button(t("timeline.addSource")) { app.addingSource = true }
            Divider()
            if let storeFailure {
                Text(t("timeline.store.unreadable", message(for: storeFailure)))
                Divider()
            }
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
        .modifier(HeaderMenuChrome(labelKey: "timeline.sources",
                                   warning: !failures.isEmpty || storeFailure != nil))
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
                    // One foot, and it says one thing. A reach still out owns it — a bottom
                    // that merely sits there is indistinguishable from a finished one — and
                    // the end is what is left when nothing is coming.
                    if model.loadingOlder {
                        readingOn
                    } else if model.atTheEnd, let oldest = posts.last {
                        theEnd(readBackTo: oldest.createdAt)
                    }
                }
                .padding(12)
            }
            // Over the foot of the feed rather than in it: the marker is the place and this is
            // the moment, and a moment that pushed the list down would be a place too.
            .overlay(alignment: .bottom) {
                if announcing {
                    EndToast().padding(.bottom, 28)
                }
            }
            // Raised by the feed on the crossing and taken back down here — a reader who comes
            // back to the foot of the list later finds the marker, and is not told twice.
            // `initial` because the crossing can happen while nobody is looking: a reach
            // finishing after the reader has stepped to another tab leaves the flag raised,
            // and without this the returning screen never takes it down — so it would stay
            // raised, never change again, and that feed would never say this once.
            .onChange(of: model.announcingTheEnd, initial: true) { _, arrived in
                guard arrived else { return }
                model.saidTheEnd()
                withAnimation(fading) { announcing = true }
            }
            // Structured, so leaving the screen takes the toast with it rather than leaving a
            // sleep to wake up in a feed nobody is looking at.
            .task(id: announcing) {
                guard announcing else { return }
                try? await Task.sleep(for: Self.announcementLasts)
                guard !Task.isCancelled else { return }
                withAnimation(fading) { announcing = false }
            }
            // Half a screen, rather than a number of points: what counts as far enough to
            // want a way back depends on how much of the list you can see at once.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y > geometry.containerSize.height / 2
            } action: { _, away in
                withAnimation(Motion.appearing) { scrolledAway = away }
            }
            // Nearing the bottom asks for what came before, without the reader asking. Half a
            // screen again, and for the same reason the other one is: how near the bottom
            // counts as near depends on how much of the list you can see at once. Crossing it
            // once a frame is not a burst — the feed's own guard turns every crossing after
            // the first into nothing until the page it started comes back.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    > geometry.contentSize.height - geometry.containerSize.height / 2
            } action: { _, nearing in
                guard nearing else { return }
                Task { await model.loadOlder(servers: app.servers) }
            }
        }
    }

    /// That the reach for the bottom is still working. A cold start can take several rounds
    /// before a page lands below the reader, and a bottom that merely sits there is
    /// indistinguishable from one that is finished — which is a different sentence, and not
    /// this one's to say.
    private var readingOn: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(t("timeline.older")).fediqoFont(11).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    /// Where the timeline stops, and how far back that is.
    ///
    /// Every post in this app is a card, so the end of the list is the one place where the
    /// *shape* of a timeline can be shown rather than described: a hairline comes down off the
    /// last card, fades as it goes, and stops at a small filled dot. The line stops. No card, no
    /// icon and no third colour — a marker that read as a post would be a post that never
    /// arrived.
    ///
    /// The sentence says the reach rather than the absence. How far back a reader has got is
    /// the information; "no more posts" is the templated answer and tells them nothing they
    /// wanted. It is also the cue that does not depend on seeing a five-point dot, which is why
    /// the two lines are one thing to a screen reader and the drawing is nothing to it at all.
    private func theEnd(readBackTo oldest: Date) -> some View {
        VStack(spacing: 12) {
            theLineStopping.accessibilityHidden(true)
            VStack(spacing: 3) {
                Text(t("timeline.end.reached", reached(oldest))).fediqoFont(12)
                Text(t("timeline.end.note")).fediqoFont(11).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        // Nothing above it. The line has to leave the last card rather than start somewhere
        // below it — a gap between the two is a line that came from nowhere.
        .padding(.bottom, 24)
        .accessibilityElement(children: .combine)
    }

    /// The hairline down from the last card, fading, and the dot it stops at.
    ///
    /// The dot is drawn in `Palette.focus` rather than `Palette.accent` raw: they are the one
    /// colour, and `focus` is that colour at the weight a five-point mark needs to hold a white
    /// page — the reason it exists at all, and the same choice the ring already makes.
    private var theLineStopping: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient(colors: [Palette.hairline(colorScheme),
                                              Palette.hairline(colorScheme).opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1, height: 34)
            Circle()
                .fill(Palette.focus(colorScheme))
                .frame(width: 5, height: 5)
        }
    }

    /// The oldest post on the screen, as a date the reader's language would write.
    ///
    /// Spelled out rather than abbreviated, because this one is inside a sentence and not in a
    /// column of metrics. The locale is the app's own — a reader who chose zh-TW gets zh-TW
    /// dates whatever the machine is set to, which is what `fediqoChrome` carries it down for.
    private func reached(_ when: Date) -> String {
        when.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(locale))
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

/// The one line that says the reading is over as it happens, floating over the foot of the
/// feed and gone in two and a half seconds.
///
/// The app's own pill, because a first passing message should not invent a second container —
/// this is the same small capsule that marks a source or a state everywhere else. What it does
/// need that a pill in a row does not is something to be legible against: the pill's fill is a
/// hairline tint, which is a mark on a surface rather than a surface of its own, so the raised
/// colour goes behind it and the card's own shadow lifts it off the posts. Neither is a new
/// shape and neither is a new colour.
///
/// It says the short form of what the marker underneath it says, so the words a reader is
/// given for this are one set of words rather than two. Hidden from a screen reader for the
/// same reason: the marker carries the sentence, and it will still be there in a moment.
private struct EndToast: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // A shade heavier than the pills that sit inside a row of other words. For two and a
        // half seconds these are the only words there are, and a reader who has to look twice
        // has already missed them.
        Text(t("timeline.end.toast"))
            .fediqoFont(12, weight: .medium)
            .fediqoPill()
            // A pill is usually a label beside something louder, so it speaks quietly. This
            // one is the whole of what is being said, and for two and a half seconds only.
            .foregroundStyle(.primary)
            .background {
                Capsule()
                    .fill(Palette.raised(colorScheme))
                    // The card's shadow, drawn closer in. Eighteen points of blur is the lift
                    // a panel the width of the window needs; under something this small it is
                    // a smudge rather than a shadow.
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.55 : 0.22),
                            radius: 10, y: 4)
            }
            .accessibilityHidden(true)
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
