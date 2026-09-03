import SwiftUI
import FediqoCore

/// The Timeline page, showing one of the reader's timelines. Every one of them is this same
/// screen asking a different question, and no two ever stand in for one another: a server
/// that publishes no public timeline contributes nothing and says why, rather than being
/// quietly topped up with whatever else it was willing to hand over.
///
/// `timeline` says what is being read, and everything about the page follows from it: its
/// posts, its order, the line under its name, and which of the header controls belong to it.
/// What a timeline cannot say is where it sits — so the heading, which names the page, comes
/// from `app.railItem` instead. A timeline does not know its own page.
struct FeedScreen: View {
    let timeline: Timeline

    @Environment(AppState.self) private var app
    /// Whether the reader has gone far enough down that going back up is a journey. The
    /// button to do it in one move only exists while that is true — an arrow pointing at
    /// where you already are is a button that does nothing.
    @State private var scrolledAway = false
    @State private var editing: TimelineEditor.Subject?
    /// How wide this screen is. The width itself and not the answer worked out from it: the
    /// answer also depends on the reader's text size, which changes without the screen being
    /// resized, and a stored `Bool` would go on saying what it said at the old size until
    /// somebody dragged a window.
    @State private var width: CGFloat = 0
    /// Whether the list of what the rules kept off this page is up.
    @State private var showingHidden = false
    /// The colour scheme, for the two marks drawn by hand at the foot of the list. Everything
    /// else here is `fediqoCard` or `Hairline`, which read it themselves.
    @Environment(\.colorScheme) private var colorScheme
    /// The reader's text size, because the width at which a row can hold two columns depends
    /// on it: the deck's share of that width is a picture and the rest of it is words.
    @Environment(\.fediqoTextScale) private var scale
    /// The app's language, carried down by `fediqoChrome`, so the date at the foot of the list
    /// is written the way the reader's own language writes one.
    @Environment(\.locale) private var locale
    /// A reader who asked for less movement. The toast still comes and still goes — it is the
    /// fade that is the decoration, not the message.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What a load is of: these servers, asked this question. Two of them being equal is the
    /// whole of "nothing has changed, do not read it again".
    private struct Reading: Equatable {
        let servers: [Server]
        let query: TimelineQuery
    }

    /// The nothing at the top of the list, so there is something to scroll back to. The
    /// first post cannot serve: it is replaced by every refresh, and the padding above it
    /// would be left off the top of the screen.
    static let top = "feed.top"


    /// Whether a row is an answer, and whose — as much as a timeline can honestly say.
    ///
    /// A reply carries the address of what it answers and nothing about who wrote it, so the
    /// name has to come from somewhere that holds the parent. Two places do, and they are asked
    /// in this order because the first is free: the page itself, where the parent happens to be
    /// on it, and then the store, read once for the whole page beside the marks.
    ///
    /// **Never from the post's own mentions**, which is where the name looks like it is. A
    /// reply's first mention is usually the person it answers, and usually is not good enough
    /// to print under somebody else's name — a row that is right most of the time about who
    /// somebody was talking to is a row that is quietly wrong about it the rest of the time.
    /// Where neither place holds the parent, the row says it is an answer and stops, and the
    /// rest is one press away.
    static func answering(_ post: Post, among posts: [Post],
                          orKnown known: [String: String] = [:]) -> Answering {
        guard let parent = post.inReplyToURI else { return .nothing }
        if let above = posts.first(where: { $0.uri == parent }) { return .handle(above.authorHandle) }
        if let handle = known[parent] { return .handle(handle) }
        return .somebody
    }

    private var fading: Animation? { reduceMotion ? nil : Motion.appearing }

    private var model: FeedModel { app.feed(for: timeline) }

    /// Sources, filter and notifications belong to a timeline that is a thread of time. A
    /// ranked list is a place you go to look at what a server put in order, so it carries
    /// none of them.
    private var showsTimelineControls: Bool { timeline.source.isThreadOfTime }

    /// Which timeline the editor is open on, and whether it is open at all. It belongs to the
    /// screen rather than to the app: nothing outside this page asks for it, and a key that
    /// wanted it would be asking for a sheet over a page it is not on.

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
            // Measured once here and read by every row: a row asking the geometry for itself
            // is the same question answered once per row on screen, and they all answer the
            // same. Below this there is no room to spend on an empty attachment column.
            //
            // The threshold S9 allows, and the comparison is made here rather than in the
            // closure so that it is remade whenever the reader's text size changes — see
            // `Size.wideRows(at:)` for why the answer moves with it.
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.width
            } action: { width in
                self.width = width
            }
            .environment(\.fediqoWideRows, width >= Size.wideRows(at: scale))
            // A run told to open a post does it as soon as there is one to open, and never
            // again — `expand` clears the stack, so a second attempt would throw away
            // whatever the reader had walked into. Nothing at all on a reader's own run.
            .task(id: model.visible.isEmpty) {
                guard let wanted = app.openingPost, app.expanded == nil,
                      let post = model.visible.first(where: { $0.mergeKey.hasSuffix(wanted) })
                else { return }
                app.expand(post)
            }
            // And the author of the first post, for a run told to open a person. The same shape
            // and the same reason: a page reached only by pressing something cannot be
            // photographed where nothing may press (#30).
            .task(id: model.visible.isEmpty) {
                guard app.openingPerson, app.person == nil, let post = model.visible.first
                else { return }
                app.openPerson(of: post)
            }
            // And the composer as an answer to it, which is a different screen from the composer
            // as a new post and so is a picture of its own.
            .task(id: model.visible.isEmpty) {
                guard app.openingReply, !app.composing, let post = model.visible.first
                else { return }
                app.reply(to: post)
            }
            // The opened post, over the list rather than instead of it: underneath, the
            // scroll position and the ring stay exactly where the reader left them.
            .overlay {
                if let opened = app.expanded {
                    PostPage(post: opened) { app.perform(.dismiss) }
                        .transition(.opacity)
                }
            }
            // A person over the post as well as over the list: the author is pressable on an
            // opened post too, and what was underneath keeps its place either way.
            .overlay {
                if let person = app.person {
                    PersonPage(model: person) { app.closePerson() }
                        .transition(.opacity)
                }
            }
            // And one of their two lists over that, because a list of somebody's followers is
            // somewhere you go from their page and come back to it from (#90).
            .overlay {
                if let people = app.people {
                    PeopleList(model: people) { app.closePeople() }
                        .transition(.opacity)
                }
            }
            // Where the reader is taken, watched somewhere that is not this body. `onChange`
            // reads its value while the body is being built, so watching the ring here made
            // every press of `j` a rebuild of the whole screen (#71).
            .background {
                ScrollDirector(place: model.place, proxy: proxy)
            }
        }
        // Keyed to the reading as well as to the servers: editing a timeline's rules is a
        // different question, and the answer on screen is still the old one until somebody
        // asks the new one.
        .task(id: Reading(servers: app.servers, query: timeline.query)) {
            await model.loadIfNeeded(servers: app.servers)
        }
        .sheet(isPresented: $app.addingSource) {
            ServerPickerView(socialProtocol: .mastodon) { app.addingSource = false }
                .fediqoChrome(app)
        }
        .sheet(isPresented: $app.showingNotifications) {
            NoticesSheet(model: app.notices, onClose: { app.showingNotifications = false },
                         onAsk: { await app.askForNotices() })
                .fediqoChrome(app)
        }
        .sheet(item: $editing) { subject in
            TimelineEditor(subject: subject) { editing = nil }
                .fediqoChrome(app)
        }
    }

    // MARK: - Header

    /// The heading names the page, and the tabs beside it are the page's — so both come from
    /// `app.railItem` rather than from the feed. A tab does not know its own page.
    private var header: some View {
        // The reader's own sentence, and the template's where they have not written one. A
        // page with tabs always has this line — two words of name are not an explanation —
        // and a timeline made in a hurry should not leave it blank.
        FeedHeader(paging: model.paging,
                   titleKey: app.railItem.titleKey,
                   subtitle: timeline.displaySummary.isEmpty ? t("timeline.noDescription")
                                                             : timeline.displaySummary) {
            TimelineChips(editing: $editing)
        } controls: {
            controls
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: Space.hair) {
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
            // The third of the standing ones, and the odd one out: the other two decide which
            // posts are here, this one decides how the ones that are here arrive. It sits with
            // them because to a reader they are the same shelf — "what am I being shown".
            Toggle(t("timeline.filter.sensitive"), isOn: $preferences.showSensitive)
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
                LazyVStack(spacing: Space.step) {
                    Color.clear.frame(height: 0).id(Self.top)
                    // The id `ForEach` gives a row is the post's own `mergeKey`, and that is
                    // what the selection is written in — so scrolling to the ring is
                    // scrolling to that id, and there is no second identity to keep in step
                    // with the first.
                    ForEach(posts) { post in
                        RingedRow(post: post, place: model.place,
                                  answering: Self.answering(post, among: posts,
                                                            orKnown: app.parentHandles))
                    }
                    // What this device already knows about the page: what each account did to
                    // these posts, and which of them are being kept here. One read for the
                    // page rather than forty, and again whenever the page changes.
                    .task(id: posts.map(\.mergeKey)) { await app.loadMarks(for: posts) }
                    // One foot, and it says one thing. A reach still out owns it — a bottom
                    // that merely sits there is indistinguishable from a finished one — and
                    // the end is what is left when nothing is coming.
                    // What the reader's own rules kept off this page, said where the page
                    // ends — which is where somebody notices a post they expected is missing.
                    whatIsMissing
                    FeedFoot(paging: model.paging, oldest: posts.last?.createdAt)
                }
                .padding(Space.gap)
            }
            // Over the foot of the feed rather than in it: the marker is the place and this is
            // the moment, and a moment that pushed the list down would be a place too.
            // Read and not held. The moment belongs to the feed, which starts it on the
            // crossing and ends it when it is over — so a screen that was on another tab while
            // it happened has nothing left to take down when it comes back, and one that is
            // rebuilt mid-moment shows what is still true rather than saying it again.
            .overlay(alignment: .bottom) {
                EndAnnouncement(paging: model.paging, fading: fading)
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

    /// How many posts the reader's own rules kept off this page, and what each of them was.
    ///
    /// #6's last promise: every hidden post can say which rule hid it. A rule that removes
    /// things silently is one nobody can check, and four of that issue's other lines are rules
    /// this app follows silently — so this is the one that makes them checkable.
    ///
    /// Only ever the reader's own doing. A post a server never handed over is not here to say
    /// anything about, and that is said elsewhere: a server that gave nothing is a line of its
    /// own above, and one that was never asked is not a fault at all.
    @ViewBuilder
    private var whatIsMissing: some View {
        let hidden = model.hidden
        if !hidden.isEmpty {
            Button { showingHidden = true } label: {
                Label(t("timeline.hidden", String(hidden.count)), systemImage: "eye.slash")
                    .fediqoFont(TypeScale.minor)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, Space.snug)
            .sheet(isPresented: $showingHidden) {
                hiddenList(hidden).fediqoChrome(app)
            }
        }
    }

    /// One line per post: what it says, and the rule that kept it off.
    private func hiddenList(_ hidden: [Hidden]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(t("timeline.hidden.title")).fediqoFont(TypeScale.lead, weight: .semibold)
                Spacer()
                Button(t("common.close")) { showingHidden = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(Space.pad)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.gap) {
                    ForEach(Array(hidden.enumerated()), id: \.offset) { _, one in
                        VStack(alignment: .leading, spacing: Space.tight) {
                            Text(one.post.text).fediqoFont(TypeScale.small).lineLimit(2)
                            Text(Self.why(one.because))
                                .fediqoFont(TypeScale.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.mid)
                        .fediqoCard(radius: Radius.inner, raised: false)
                    }
                }
                .padding(Space.pad)
            }
        }
        .frame(minWidth: Size.prose, minHeight: Size.prose)
    }

    /// The reason, in the reader's language. A rule names what it is about, because "a rule"
    /// is not an answer to "why is this post missing".
    private static func why(_ because: Hidden.Because) -> String {
        switch because {
        case .boostsHidden: t("timeline.hidden.boosts")
        case .mediaOnly: t("timeline.hidden.media")
        case .rule(let rule):
            t(rule.negate ? "timeline.hidden.without" : "timeline.hidden.only",
              t("filter.kind.\(rule.kind.rawValue)"), rule.value)
        }
    }

    /// Not `@ViewBuilder`: it works out two facts first and then returns one view, and a
    /// builder turned off by the `return` that follows it is a warning rather than a shape.
    private var emptyState: some View {
        let hiddenByRules = !model.result.posts.isEmpty
        // A home timeline on a device nobody is signed in on is not an empty timeline: there
        // is nothing wrong and nothing to wait for, and "no posts" would have the reader
        // looking for a fault. It says what is missing instead.
        let needsAccount = !app.isReadable(timeline)
        return VStack(spacing: Space.mid) {
            if model.loading {
                ProgressView()
                Text(t("timeline.loading")).fediqoFont(TypeScale.small).foregroundStyle(.secondary)
            } else {
                Image(systemName: needsAccount ? "person.crop.circle.badge.questionmark" : "tray")
                    .fediqoSymbol(Glyph.big, weight: .light).foregroundStyle(.tertiary)
                Text(t(needsAccount ? "timeline.empty.needsAccount"
                                    : hiddenByRules ? "timeline.empty.filtered" : "timeline.empty"))
                    .fediqoFont(TypeScale.small)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if showsTimelineControls {
                    Button(t("timeline.addSource")) { app.addingSource = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .fediqoFont(TypeScale.small)
                }
            }
        }
        .padding(Space.room)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A menu button dressed as one of the plain icon buttons beside it — without this the
/// platform paints it in the accent colour and it reads as the only live control there.
///
/// Shared with the row of timelines, whose overflow menu sits in the same header and has to
/// be the same button as the two beside it.
struct HeaderMenuChrome: ViewModifier {
    let labelKey: String
    let warning: Bool

    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .frame(width: Size.iconColumn, height: Size.iconColumn)
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
/// The foot of the list, and the one thing it says.
///
/// Its own view, and that is the point of it (#70). While this lived inside `FeedScreen.body`,
/// the body read `bottom` — which changes several times a second through a cold start — so a
/// spinner appearing rebuilt the header, the tabs and every row of the list. Here the only view
/// that depends on the foot is the foot.
///
/// One foot, and it says one thing. A reach still out owns it — a bottom that merely sits there
/// is indistinguishable from a finished one — and the end is what is left when nothing is
/// coming.
/// One row, and whether the ring is on it.
///
/// A thin view between the list and the row, and the whole of what it is for is where the ring
/// is read (#71). While `FeedScreen.body` asked "is this the selected one?" for every row, a
/// press of `j` — twenty a second with the key held — invalidated the screen: the heading, the
/// tabs, the foot and every row, to move a ring between two of them.
///
/// Here the ring is read one row at a time, so a press rebuilds these — a comparison each — and
/// then only the rows whose answer actually changed.
///
/// The three media counters come with it, and for the same reason: they are only ever read
/// through the ring, so `m` on one row used to redraw the screen as surely as `j` did.
private struct RingedRow: View {
    let post: Post
    let place: FeedPlace
    /// What this row says about the post being an answer. The list's fact, not the ring's, so
    /// it is worked out once where the list is and handed in.
    let answering: Answering

    @Environment(AppState.self) private var app

    var body: some View {
        let ringed = post.mergeKey == place.selection
        PostRow(post: post,
                selected: ringed,
                // Only the row the reader is on hears `m`; every other deck stays where its
                // own reader left it.
                turns: ringed ? app.mediaTurns : 0,
                plays: ringed ? app.mediaPlays : 0,
                covers: ringed ? app.mediaCovers : 0,
                revealed: app.preferences.showSensitive,
                answering: answering,
                // A click on the words says which post the reader means even where it opens
                // nothing — selectable text takes the press before the row behind it ever
                // sees it.
                focus: { place.select(post) },
                openAuthor: { app.openPerson(of: post) },
                open: { app.expand(post) })
    }
}

/// Where the reader is taken, and nothing drawn for it.
///
/// The three moves the list makes on its own: to the ring when a key moves it, to the ring once
/// on the way in, and to the top when it is asked for. Each is an `onChange`, and an `onChange`
/// reads its value as the body around it is built — so while these were written on the screen's
/// own body, the screen depended on the ring and every press rebuilt all of it (#71).
///
/// Nothing is drawn here. It is a view because that is what it takes to have a body of one's
/// own, which is the whole point: what these watch changes twenty times a second under a held
/// key, and what is rebuilt for it should be this and not a timeline.
/// Not private: the page about somebody is a list with the same ring in it, and a reader taken
/// to the ring on one screen and left behind it on the other has learned two things (#94).
struct ScrollDirector: View {
    let place: FeedPlace
    let proxy: ScrollViewProxy

    /// Whether the reader has been put back on the post they were on. One screen, one
    /// restoring: the ring is remembered for as long as the app runs, and this is only the
    /// once-per-arrival act of scrolling to it.
    @State private var restored = false

    var body: some View {
        Color.clear
            // The ring is moved by a key, and a key can move it past the bottom of the
            // screen — which is most of what holding `j` is for. Without an anchor the list
            // brings it to the middle, so what you are reading has its own context above and
            // below it rather than sitting against an edge with the next post already gone.
            // Near either end there is not enough list to centre against and it settles for
            // as close as it can get, which is what a reader at the top or bottom expects
            // anyway.
            .onChange(of: place.selection) { _, key in
                guard let key else { return }
                proxy.scrollTo(key, anchor: .center)
            }
            // And once on the way in, to the post the reader was already on.
            //
            // The ring itself was never lost: it lives on the feed, and the feeds outlive the
            // screens that show them. What was lost was the place — `AppShell` gives the
            // screen the timeline's own id, so coming back builds a new scroll view at the top
            // of the list while the ring sits wherever the reader left it. Somebody who
            // stepped away to look at something else and came back was being told two
            // different places at once.
            //
            // Watched rather than done on arrival, because on arrival the answer is not ready:
            // the ring names a post, and whether this list has that post is a question about a
            // list a load may still be replacing. `selectedPost` is that question asked
            // properly — it resolves through the same rules the rows are drawn from — so a
            // ring on a post the filters now hide scrolls nowhere, and the reader simply
            // starts at the top, which is where a list with no ring in it starts anyway.
            //
            // Once per screen, and then never again. After the first one this is the reader's
            // own list, and every move in it belongs to the change above.
            .onChange(of: place.selectedPost?.mergeKey, initial: true) { _, key in
                guard !restored, let key else { return }
                restored = true
                proxy.scrollTo(key, anchor: .center)
            }
            // Back to the top, however it was asked for — the key or the button — and with
            // no animation on the way: a reader a thousand posts down asked to be at the
            // top, not to watch the thousand go past.
            .onChange(of: place.topRequests) { _, _ in
                proxy.scrollTo(FeedScreen.top, anchor: .top)
            }
    }
}

/// The page's heading, with the feed's own spinner in it.
///
/// A thin thing to be a view, and the reason is the same as `FeedFoot`'s (#70): `loading` is
/// read here rather than in `FeedScreen.body`, so the spinner beside the title coming and going
/// redraws the heading and not the list under it. The tabs and the controls are handed in
/// already built, so they are not rebuilt for it either.
private struct FeedHeader<Tabs: View, Controls: View>: View {
    let paging: FeedPaging
    let titleKey: String
    let subtitle: String
    @ViewBuilder var tabs: Tabs
    @ViewBuilder var controls: Controls

    var body: some View {
        PageHeader(titleKey: titleKey, subtitle: subtitle, loading: paging.loading) {
            tabs
        } controls: {
            controls
        }
    }
}

private struct FeedFoot: View {
    let paging: FeedPaging
    /// The oldest post on the screen, or nothing where there is no list to have an end. Handed
    /// in rather than read, because it is the list's fact and the list is somebody else's.
    let oldest: Date?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    /// The line under the last post: a hairline that fades out, ending in a dot.
    private static let stopLine: CGFloat = 34

    @ViewBuilder
    var body: some View {
        if paging.bottom.isReading {
            readingOn
        } else if paging.bottom.isTheEnd, let oldest {
            theEnd(readBackTo: oldest)
        }
    }

    /// That the reach for the bottom is still working. A cold start can take several rounds
    /// before a page lands below the reader, and a bottom that merely sits there is
    /// indistinguishable from one that is finished — which is a different sentence, and not
    /// this one's to say.
    private var readingOn: some View {
        HStack(spacing: Space.step) {
            ProgressView().controlSize(.small)
            Text(t("timeline.older")).fediqoFont(TypeScale.minor).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.gap)
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
        VStack(spacing: Space.gap) {
            theLineStopping.accessibilityHidden(true)
            VStack(spacing: Space.tight) {
                Text(t("timeline.end.reached", reached(oldest))).fediqoFont(TypeScale.small)
                Text(t("timeline.end.note")).fediqoFont(TypeScale.minor).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        // Nothing above it. The line has to leave the last card rather than start somewhere
        // below it — a gap between the two is a line that came from nowhere.
        .padding(.bottom, Space.band)
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
                .frame(width: Size.hairline, height: Self.stopLine)
            Circle()
                .fill(Palette.focus(colorScheme))
                .frame(width: Size.dot, height: Size.dot)
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
}

/// The moment at the end of the reading, said once.
///
/// Read and not held. The moment belongs to the feed, which starts it on the crossing and ends
/// it when it is over — so a screen that was on another tab while it happened has nothing left
/// to take down when it comes back, and one that is rebuilt mid-moment shows what is still true
/// rather than saying it again.
///
/// Its own view for the same reason `FeedFoot` is: the toast is over the foot of the feed and
/// the list is not what changes when it comes and goes.
private struct EndAnnouncement: View {
    let paging: FeedPaging
    let fading: Animation?

    var body: some View {
        ZStack {
            if paging.bottom == .arrived {
                EndToast().padding(.bottom, Space.band)
            }
        }
        .animation(fading, value: paging.bottom)
    }
}

private struct EndToast: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // A shade heavier than the pills that sit inside a row of other words. For two and a
        // half seconds these are the only words there are, and a reader who has to look twice
        // has already missed them.
        Text(t("timeline.end.toast"))
            .fediqoFont(TypeScale.small, weight: .medium)
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
