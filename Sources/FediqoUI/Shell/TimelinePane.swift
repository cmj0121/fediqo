import AVKit
import FediqoCore
import SwiftUI

/// The two marks in the timeline's header, and whether either has anything to do (#33).
///
/// **Handed down rather than worked out here.** Whether the search may open and whether there is
/// anything to reload are the two functions `FediqoRootView` asks before it lets `/` and `r`
/// do anything, and a pane that decided it for itself would be the same rule written twice —
/// which is how a mark and the key it stands for come to disagree. This carries the answers and
/// the presses together, so a call site cannot pass one without the other.
struct TimelineWays {
    /// Whether the search can be opened from where the reader is. False draws no mark at all:
    /// decision 4's rule is a control that is absent rather than dead.
    var canSearch: Bool
    var onSearch: () -> Void
    /// Whether there is anything for `r` to ask for. A reload already running is still `true` —
    /// the mark keeps its place rather than blinking out from under the finger that pressed it,
    /// and stays the mark: a plate there would be a second loading animation beside the toast.
    var canReload: Bool
    var onReload: () -> Void
}

/// The timeline place: named queries, a brief rule, then the stream or a thread.
struct TimelinePane: View {
    @Bindable var session: ShellSession
    @Binding var selectedID: String?
    @Binding var openedID: String?
    /// Where every deck in this pane is turned to, and which rows the reader uncovered. Held by
    /// the app rather than here, because `m` and `s` are pressed where the keys are read.
    @Binding var decks: ShellDecks
    /// What is playing, and the one player in the app. Read here and written nowhere: the rule
    /// about what a press means lives beside the key that means it. See `ShellPlayback`.
    let playback: ShellPlayback
    /// A press on a card's own play mark, which the root answers under the same rule as `a`.
    var onPlayRow: (DummyItem) -> Void
    /// A press on a card, and a press on the counter in its corner: `v` and `m`, answered by the
    /// root under the same rules the keys are (#33).
    var onViewRow: (DummyItem) -> Void
    var onTurnRow: (DummyItem) -> Void
    /// A second press on the row the lamp is already on: `Return`. See `DummyCommand.tapped`.
    ///
    /// **The press says which post it means.** It used to say so by writing the lamp and calling
    /// this, which made the open depend on a `@State` write being readable by the very next
    /// statement — and where it is not, the root opens whatever was lit *before*, which is the
    /// wrong post on the one path built for a reader who cannot press twice. The id travels with
    /// the press instead, and the root lights it and opens it together.
    var onOpenThread: (String) -> Void
    var jumpToTop: Int
    var onPopThread: () -> Void
    /// The search and the reload, as a finger reaches them.
    var ways: TimelineWays
    /// While open, its results are the list and the timeline waits under it (#32).
    var search: ShellSearch?
    @State private var marks: [String: DummyMarks] = [:]
    /// Bumped once each server's emoji catalogue has landed, so the rows already on screen ask
    /// again. Per host and not one counter for the pane: see `waitForCatalogues`.
    @State private var settledHosts: Set<String> = []
    @State private var toast: String?
    @State private var toastTick = 0
    /// What a finger gets on the header's marks, whatever the glyph inside measures. The row's
    /// own marks are held open the same way — see `DummyItemRow.touch`.
    @ScaledMetric(relativeTo: .caption) private var touch: CGFloat = 32
    @Environment(\.colorScheme) private var colorScheme
    @Environment(DummyPrefs.self) private var prefs

    private var timeline: TimelineQuery { session.currentTimeline }

    private var items: [DummyItem] {
        search?.items(
            from: session.notes, revision: session.notesRevision, sources: session.sources, latest: prefs.latestDate
        )
            ?? session.timelineItems(latest: prefs.latestDate)
    }

    /// What the stream in front is, from facts a test can name without drawing the pane.
    enum Standing: Equatable, Sendable {
        /// Posts this device already holds. Drawn at once — a skeleton on top of them would hide
        /// what is already here.
        case held
        /// Nothing in the list: `EmptyNotice`. A wait and a miss are the toast, not this
        /// standing; the distinctions inside empty — rules, held, answered, search — live on
        /// that notice.
        case empty
    }

    /// Held or empty. A wait and a miss are the bottom toast, so they do not take the stream.
    ///
    /// **Held wins.** What is already here is read at once, including while a reload runs.
    /// **Empty stays empty.** Running, a failed source, a search, and nobody joined are all
    /// empty when there are no rows: waiting rows would be a wait that never ended, and a
    /// pane-sized failure would hide that this timeline has nothing to show.
    static func standing(
        running _: Bool,
        hasItems: Bool,
        searching _: Bool,
        hasSources _: Bool,
        failed _: [String] = []
    ) -> Standing {
        hasItems ? .held : .empty
    }

    private var stream: Standing {
        Self.standing(
            running: session.reload.running,
            hasItems: !items.isEmpty,
            searching: search?.isSearching == true,
            hasSources: !session.sources.isEmpty,
            failed: session.reload.failed
        )
    }

    /// Running first; a live note replaces a leftover line; otherwise the reload
    /// line. Loading and a miss do not auto-dismiss: a 2s flash is a fact the
    /// reader has to act on, gone.
    private var banner: TimelineToast? {
        TimelineToast.shown(
            running: session.reload.running,
            line: session.reload.line,
            stopped: session.reload.stopped,
            note: toast
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, ShellSpace.pad)
                .padding(.top, ShellSpace.step)
                .padding(.bottom, ShellSpace.snug)

            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: ShellSpace.hair)

            if let opened = openedItem {
                DummyThreadPane(
                    root: opened,
                    catalogues: session.emoji,
                    catalogueSettled: settledHosts.contains(opened.source.host),
                    posts: session.posts,
                    conversations: session.conversations,
                    onAskAround: { Task { await session.conversations.again(opened, in: session) } },
                    selectedID: $selectedID,
                    marks: markBinding,
                    decks: $decks,
                    playback: playback,
                    onPlayRow: onPlayRow,
                    onViewRow: onViewRow,
                    onTurnRow: onTurnRow,
                    onOpenThread: onOpenThread,
                    jumpToTop: jumpToTop,
                    onToast: showToast,
                    onBack: onPopThread
                )
                // One pane per thread, so going back from a nested one draws its parent afresh.
                .id(opened.id)
                // **The ask is the pane opening** — #90. A microblog thread is one request about
                // the post the reader has just pressed Return on, so nothing asks them a second
                // time for a thing they have already said they want. It is the pane's own
                // `.task`, so closing the thread cancels a read still on the wire, and asked
                // once per post per run: reopening draws what is already held.
                .task(id: opened.id) { await session.conversations.open(opened, in: session) }
            } else {
                switch stream {
                case .held: list
                case .empty: empty
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let banner {
                TimelineToastBanner(toast: banner)
                    .padding(.bottom, ShellSpace.pad)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: banner)
        .task(id: catalogueHosts) { await waitForCatalogues() }
        .onChange(of: session.toast) { _, toast in
            if let toast { showToast(toast.text) }
        }
        .onChange(of: session.timelineID) { _, _ in
            if let selectedID, !items.contains(where: { $0.id == selectedID }) {
                self.selectedID = nil
            }
            openedID = nil
        }
    }

    private var catalogueHosts: [String] { session.sources.map(\.host).sorted() }

    /// Waits for every joined server's catalogue at once, telling the rows as each one answers.
    ///
    /// **The wait lives here and not on a row.** A catalogue asked for at join is usually still
    /// on the wire when the first rows draw, so somebody has to wait — but `settle(host:)` awaits
    /// a `Task<Void, Never>`, and awaiting one of those ignores the waiting task's own
    /// cancellation. On a row that is a suspended task per row ever scrolled past, held until the
    /// server answers. This view lives as long as the place does, so here it is one per server.
    ///
    /// **Concurrently, and the answer is per host.** Waited in a row, one slow instance withheld
    /// every other instance's emoji: `URLRequest`'s default timeout is sixty seconds of *idle*,
    /// so a server dripping a byte a minute never times out, and a single counter bumped after
    /// the last wait would never have been bumped at all. A host that has settled is also a fact
    /// rather than a signal, so a wait that was superseded can only insert something true — the
    /// spurious bump a counter would have produced on its way out has nowhere to land.
    ///
    /// **And it asks, where nothing else would.** `refresh` had one call site in the whole
    /// product — the join — so a catalogue the reader dropped never came back for the life of
    /// the process: their pictures returned on the next pass through the timeline and that
    /// server's names stayed letters and colons until the app was relaunched. The twenty-four
    /// hour life cannot save it either, because staleness is a question about a catalogue that
    /// is *there*. A timeline is the other place a catalogue is wanted, so it is the other place
    /// that asks for one.
    ///
    /// **Guarded, and the guard that matters is the store's.** `needsFetch` is asked first
    /// because a catalogue already held and still young should not cost an allocation and a
    /// closure on every pass — but it is not what keeps a timeline load from racing the join
    /// into two requests for one host. `refresh` is: it re-reads what is in flight and what is
    /// held from inside the actor, and registers its task before it suspends, so the loser of
    /// that race returns having started nothing. Read as a guard against the race, this line
    /// would be two hops with a network in between, which is the shape the store's own note
    /// says a caller cannot get right.
    ///
    /// What is left is the leak: a superseded child still cannot be cancelled out of `settle`,
    /// so it stays parked against a dripping server. Closing that means a cancellation-aware
    /// `settle`, which is not this file.
    private func waitForCatalogues() async {
        // Captured before the group: the children are `@Sendable` and the store is an actor,
        // which is reachable from one; `session` is not. The client is built per host inside
        // the child rather than passed in, because it is a host and a transport and nothing
        // else — the transport is what has to come from out here.
        let store = session.emoji
        let http = session.http
        await withTaskGroup(of: String.self) { group in
            for host in catalogueHosts {
                group.addTask { await Self.catalogue(host, in: store, over: http); return host }
            }
            // Marked as each one lands rather than after the last, which is the whole of the
            // fix: a server is only ever waited on by the rows that read through it.
            for await host in group { settledHosts.insert(host) }
        }
    }

    /// One server's share of that: ask if there is anything to ask for, then wait for whatever
    /// is on the wire — the join's fetch or this one.
    ///
    /// Lifted out of the group so a test can run it. The body of a `View` cannot be executed by
    /// anything in this package, so a call site left inside a closure inside `body`'s `.task` is
    /// a call site with no test — and "the timeline asks at all" is exactly the fact that was
    /// missing, not something the store can pin from its own side.
    static func catalogue(_ host: String, in store: EmojiCatalogueStore, over http: any HTTPClient) async {
        if await store.needsFetch(host: host) {
            await store.refresh(host: host) {
                try await MastodonClient(http: http, host: host).customEmojis()
            }
        }
        await store.settle(host: host)
    }

    private var openedItem: DummyItem? {
        guard let openedID else { return nil }
        return items.first { $0.id == openedID }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        DummyItemRow(
                            item: item,
                            catalogues: session.emoji,
                            catalogueSettled: settledHosts.contains(item.source.host),
                            posts: session.posts,
                            marks: markBinding(item),
                            selected: item.id == selectedID,
                            top: decks.top(of: item.id, of: item.attachments.count),
                            lifted: decks.isLifted(item.id),
                            player: player(of: item),
                            // A press lights the row; a second press on the row it is already on
                            // opens the conversation, which is what `Return` does (#33). The rule
                            // is `DummyCommand.tapped` and is read by both lists.
                            onSelect: {
                                switch DummyCommand.tapped(item.id, selected: selectedID) {
                                case .select: selectedID = item.id
                                case .open: onOpenThread(item.id)
                                }
                            },
                            // Lit and opened in one, for the reader who activates a row once —
                            // done by the root, in one turn, on the id this press carries.
                            onOpen: { onOpenThread(item.id) },
                            onToggleCover: { _ = decks.toggleCover(item.id) },
                            onPlay: { onPlayRow(item) },
                            onView: { onViewRow(item) },
                            onTurn: { onTurnRow(item) },
                            onEnded: { playback.stop() },
                            onToast: showToast
                        )
                        .id(item.id)
                        if index < items.count - 1 {
                            Rectangle()
                                .fill(ShellChrome.hairline(colorScheme))
                                .frame(height: ShellSpace.hair)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .onAppear {
                guard let id = DummyCommand.centredOnAppear(selected: selectedID) else { return }
                // A tick later: a lazy stack just built has not laid out the row to scroll to.
                Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // A reload lands newer rows above the selected one; it stays centred (#23, #29).
            .onChange(of: session.reload.landed) { _, _ in
                guard let selectedID else { return }
                proxy.scrollTo(selectedID, anchor: .center)
            }
            .onChange(of: jumpToTop) { _, _ in
                guard let first = items.first else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }

    /// The player for this row's slot, where this row's card is the thing that is playing. There
    /// is at most one in the app, so at most one row ever gets it back.
    private func player(of item: DummyItem) -> AVPlayer? {
        playback.player(
            for: ShellPlaying.playable(decks.showing(item.attachments, of: item.id)),
            of: item.id,
            on: .row
        )
    }

    private func markBinding(_ item: DummyItem) -> Binding<DummyMarks> {
        Binding(
            get: { marks[item.id] ?? item.marks },
            set: { marks[item.id] = $0 }
        )
    }

    private func showToast(_ text: String) {
        toastTick += 1
        let tick = toastTick
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if toastTick == tick { toast = nil }
        }
    }

    /// `[+]`, the queries, then the rule the current one is under — one line.
    ///
    /// `[+]` is pinned leading, outside the scroll, so adding is always in reach. It is a
    /// press, not a Tab stop: Tab rotates All, Trends and yours. The names scroll so a
    /// narrow window or a larger text size does not squeeze them; the rule keeps its own
    /// width on the trailing edge.
    private var header: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            HStack(alignment: .center, spacing: ShellSpace.step) {
                if !session.queries.isEmpty { addPill }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: ShellSpace.tight) {
                            ForEach(session.queries) { query in
                                queryPill(query)
                                    .id(query.id)
                            }
                        }
                        .padding(.vertical, ShellSpace.hair)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: session.timelineID) { _, query in
                        guard let query else { return }
                        withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(query.id) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if session.timelineID != nil {
                    Text(session.rule(of: timeline))
                        .font(ShellType.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .lineLimit(1)
                }
                searchMark
                reloadMark
            }
            if session.timelinesUnreadable {
                Text(L10n.t("timeline.unreadable"))
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let latest = prefs.latestDate {
                latestMark(latest)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Quiet word that newer posts are held back by the latest date in Preferences (#22), so a
    /// stream that stops short does not read as missing posts.
    private func latestMark(_ latest: LatestDate) -> some View {
        let day = latest.start().formatted(.dateTime.year().month().day().locale(L10n.locale()))
        return Label(String(format: L10n.t("timeline.latest"), day), systemImage: "calendar")
            .font(ShellType.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(1)
            .accessibilityLabel(String(format: L10n.t("timeline.latest.label"), day))
    }

    private func queryPill(_ query: TimelineQuery) -> some View {
        let selected = query == session.timelineID
        let missing = session.hasMissingRule(query)
        return Button {
            session.timelineID = query
        } label: {
            // One line at its own width; the row it sits in scrolls rather than squeezing it.
            HStack(spacing: ShellSpace.tight) {
                Text(session.name(of: query))
                    .lineLimit(1)
                    .fixedSize()
                if missing {
                    Image(systemName: "circle.dashed")
                        .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                        .accessibilityHidden(true)
                }
            }
            .font(ShellType.meta.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
            .padding(.horizontal, ShellSpace.snug)
            .padding(.vertical, ShellSpace.tight)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? ShellChrome.selectFill(colorScheme) : ShellChrome.well(colorScheme))
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { session.editTimeline(query) }
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in session.editTimeline(query) }
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(missing ? L10n.t("timeline.pill.missing.hint") : "")
        .accessibilityAction(named: Text(L10n.t("shortcut.edit"))) {
            session.editTimeline(query)
        }
    }

    /// `/` and `r`, for the reader holding no keyboard (#33).
    ///
    /// **On the trailing edge of the header, where the rule already is.** They are about the
    /// whole timeline rather than about any one tab, and the tabs themselves scroll — a mark
    /// among them would scroll off with them. `[+]` is pinned at the other end for that reason
    /// and these are its pair.
    ///
    /// **Absent rather than dead**, which is decision 4 and is why each of them is a `Bool` the
    /// root worked out with the same function the key asks: under an open thread there is no
    /// search to open, with no sources there is nothing to reload, and a mark that is drawn and
    /// refuses is a question about this app rather than an answer.
    ///
    /// **Both say what the keys list says.** The sentence on each is `shortcut.search` and
    /// `shortcut.reload` — the same string the written-down key is explained with, not a second
    /// wording of it, so the press and the key cannot come to describe themselves differently.
    @ViewBuilder
    private var searchMark: some View {
        if ways.canSearch {
            headerMark("magnifyingglass", says: "shortcut.search", action: ways.onSearch)
        }
    }

    /// `r`'s mark. Stays the mark while a reload runs: a plate here would be a second
    /// loading animation, and blinking the control out from under the finger that pressed
    /// it is the thing decision 4 refuses. A press then still does nothing (`r` already).
    @ViewBuilder
    private var reloadMark: some View {
        if ways.canReload {
            headerMark("arrow.clockwise", says: "shortcut.reload", action: ways.onReload)
        }
    }

    /// One glyph, quiet, with a finger's worth of room round it whatever size the glyph is drawn.
    private func headerMark(_ symbol: String, says key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(ShellType.meta.weight(.medium))
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .frame(minWidth: touch, minHeight: touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(key))
        .accessibilityLabel(L10n.t(key))
    }

    /// `[+]`: a new timeline. A press, not a selected tab.
    private var addPill: some View {
        Button {
            session.newTimeline()
        } label: {
            Image(systemName: "plus")
                .font(ShellType.meta.weight(.semibold))
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .padding(.horizontal, ShellSpace.snug)
                .padding(.vertical, ShellSpace.tight)
                .background(
                    Capsule(style: .continuous)
                        .fill(ShellChrome.well(colorScheme))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("timeline.new.title"))
    }

    private var empty: some View {
        ShellNotice(EmptyNotice.timeline(
            searching: search?.isSearching == true,
            indexed: search?.isIndexed ?? false,
            query: timeline,
            notes: session.notes,
            written: session.written,
            sources: session.sources,
            index: session.textIndex,
            latest: prefs.latestDate,
            // **"Asked, and there is genuinely nothing"** — which a run that skipped a source
            // cannot claim. A host that answered as something this app does not read leaves
            // `failed` empty (it did not fail to answer), so without the third clause an empty
            // timeline would read as settled under a toast saying one of its sources was never
            // spoken to (#86).
            asked: session.reload.landed > 0
                && session.reload.failed.isEmpty
                && session.reload.unspoken == nil
                && !session.reload.stopped
        ))
    }
}
