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
    /// and what it draws while it waits is `TimelinePane.reloadMark`'s business.
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
        /// A fetch for this timeline is on the wire, and the list in front has no rows yet.
        case arriving
        /// Posts this device already holds. Drawn at once — a skeleton on top of them would hide
        /// what is already here.
        case held
        /// Nothing on the wire, or a search, or nobody joined: today's empty notice.
        case empty
    }

    /// Arriving only while a reload is on the wire and the list in front is empty.
    ///
    /// **Held wins.** What is already here is read at once; only what has not arrived waits.
    /// **Search is not a timeline wait.** An empty search already has its own indexing and empty
    /// notices; turning it into waiting rows would be a second vocabulary for a local miss.
    /// **No sources is empty, never waiting.** There is nobody to ask, so a plate standing for a
    /// row that will never come is a wait that never ends.
    static func standing(
        running: Bool,
        hasItems: Bool,
        searching: Bool,
        hasSources: Bool
    ) -> Standing {
        if hasItems { return .held }
        if searching || !hasSources { return .empty }
        return running ? .arriving : .empty
    }

    /// The header plate is silent while the stream is arriving: the group below is already that
    /// sentence, and saying it twice is two waiting places for one wait.
    static func headerWaitingSpeaks(standing: Standing) -> Bool {
        standing != .arriving
    }

    private var stream: Standing {
        Self.standing(
            running: session.reload.running,
            hasItems: !items.isEmpty,
            searching: search?.isSearching == true,
            hasSources: !session.sources.isEmpty
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
            } else {
                switch stream {
                case .held: list
                case .arriving: TimelineWaiting()
                case .empty: empty
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(ShellType.meta)
                    .padding(.horizontal, ShellSpace.step)
                    .padding(.vertical, ShellSpace.snug)
                    .background(ShellChrome.well(colorScheme), in: Capsule())
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .padding(.bottom, ShellSpace.pad)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
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
            if let line = session.reload.line {
                Text(line)
                    .font(ShellType.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    /// `r`'s mark — or, while a reload is running, the plate every waiting thing in this app
    /// wears (#64) in the same box.
    ///
    /// **A control that cannot act stops looking like one.** `canReload` stays true while a
    /// reload runs on purpose: a mark that blinked out from under the finger that pressed it is
    /// worse than one that stays. But `r` pressed then is taken and does nothing, so a glyph that
    /// looks live and answers nothing is exactly the dead control decision 4 rules out — the one
    /// case where "absent rather than dead" has no absence to offer. The box keeps its place and
    /// its size and what is in it changes: a plate is not a button, a press on it does nothing,
    /// and nothing moves under the finger. That is `r`'s own answer while one runs, drawn.
    ///
    /// A screen reader is told "on its way" rather than offered a Reload button that would refuse
    /// it — unless the stream itself is arriving, in which case that sentence is the group's
    /// below. What is *on* the wire is still said in words on the line below the tabs.
    @ViewBuilder
    private var reloadMark: some View {
        if ways.canReload {
            if session.reload.running {
                ShellWaiting(speaks: Self.headerWaitingSpeaks(standing: stream))
                    .frame(width: touch, height: touch)
            } else {
                headerMark("arrow.clockwise", says: "shortcut.reload", action: ways.onReload)
            }
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

    @ViewBuilder
    private var empty: some View {
        if let search, search.isSearching, !search.isIndexed {
            ShellNotice(
                symbol: "magnifyingglass",
                title: L10n.t("search.indexing.title"),
                detail: L10n.t("search.indexing.detail")
            )
        } else if search?.isSearching == true {
            ShellNotice(
                symbol: "magnifyingglass",
                title: L10n.t("search.empty.title"),
                detail: L10n.t("search.empty.detail")
            )
        } else {
            timelineEmpty
        }
    }

    private var timelineEmpty: some View {
        ShellNotice(
            symbol: "list.bullet.rectangle",
            title: L10n.t("\(timeline.emptyKey).title"),
            detail: L10n.t("\(timeline.emptyKey).detail")
        )
    }
}

/// DummyItemRow's place, taken before the row is there, at the height that row will have.
///
/// DummyItemRow names four bands; the decorator is drawn only when a post has something to say
/// there. A waiting place that held it open would be taller than the typical row that replaces
/// it, which is the one thing this place is not allowed to be. Headline, words and marks are
/// the three that every row keeps. Compact drops the thumb column, because DummyItemRow does.
struct TimelineWaiting: View {
    /// A small run of places, not a list of forty.
    static let places = 6
    /// Silent so the group is the only thing a reader lands on.
    static let plateSpeaks = false
    /// DummyItemRow's finger floor at the standard type size, so this place is that row's height.
    static let marks: CGFloat = 32
    /// Three placeholder lines, the typical compact words band: not the thumb, which that
    /// layout does not keep.
    static let compactWords: CGFloat = ShellSpace.snug * 3 + ShellSpace.tight * 2

    static var spoken: String { ShellWaiting.spoken }

    /// The plates' clock is the shell's, so Reduce Motion stops them the same way.
    static func clock(reduceMotion: Bool) -> TimeInterval? {
        ShellWaiting.clock(reduceMotion: reduceMotion)
    }

    /// Compact sizes words to the lines, not the thumb slot DummyItemRow drops there.
    static func wordsHeight(narrow: Bool, thumb: CGFloat = DummyItemRow.Box.thumb) -> CGFloat {
        narrow ? compactWords : thumb
    }

    /// Headline at the avatar, words at `wordsHeight`, marks at a finger's floor, the row's
    /// padding and the gaps between bands. The view frames to this, so the place is this
    /// number rather than whatever the plates measure.
    static func rowHeight(
        narrow: Bool,
        avatar: CGFloat = DummyItemRow.Box.avatar,
        thumb: CGFloat = DummyItemRow.Box.thumb,
        marks: CGFloat = marks
    ) -> CGFloat {
        avatar
            + wordsHeight(narrow: narrow, thumb: thumb)
            + marks
            + ShellSpace.snug * 2
            + ShellSpace.step * 2
    }

    @ScaledMetric(relativeTo: .body) private var avatar: CGFloat = DummyItemRow.Box.avatar
    @ScaledMetric(relativeTo: .body) private var thumb: CGFloat = DummyItemRow.Box.thumb
    @ScaledMetric(relativeTo: .caption) private var touch: CGFloat = 32
    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// DummyItemRow's split: a phone upright has no room for the thumb column.
    private var narrow: Bool { sizeClass == .compact }
    #else
    private var narrow: Bool { false }
    #endif

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<Self.places, id: \.self) { index in
                    row
                    if index < Self.places - 1 {
                        Rectangle()
                            .fill(ShellChrome.hairline(colorScheme))
                            .frame(height: ShellSpace.hair)
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            headline
            mainBox
            marksBand
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .frame(height: Self.rowHeight(narrow: narrow, avatar: avatar, thumb: thumb, marks: touch))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headline: some View {
        HStack(alignment: .center, spacing: ShellSpace.snug) {
            plate(width: avatar, height: avatar)
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                plate(height: ShellSpace.snug)
                    .frame(maxWidth: 160, alignment: .leading)
                plate(height: ShellSpace.snug)
                    .frame(maxWidth: 96, alignment: .leading)
            }
            Spacer(minLength: ShellSpace.snug)
            plate(width: 72, height: ShellSpace.snug)
        }
        .frame(height: avatar)
    }

    @ViewBuilder
    private var mainBox: some View {
        let words = Self.wordsHeight(narrow: narrow, thumb: thumb)
        if narrow {
            wordPlates
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: words, alignment: .top)
        } else {
            HStack(alignment: .top, spacing: ShellSpace.step) {
                wordPlates
                    .frame(maxWidth: .infinity, alignment: .leading)
                plate(width: thumb, height: thumb)
            }
            .frame(height: words, alignment: .top)
            .clipped()
        }
    }

    private var wordPlates: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            plate(height: ShellSpace.snug)
            plate(height: ShellSpace.snug)
                .frame(maxWidth: 220, alignment: .leading)
            plate(height: ShellSpace.snug)
                .frame(maxWidth: 160, alignment: .leading)
        }
    }

    private var marksBand: some View {
        HStack(spacing: ShellSpace.snug) {
            ForEach(0..<4, id: \.self) { _ in
                plate(width: ShellSpace.room, height: ShellSpace.snug)
            }
            Spacer(minLength: 0)
            ForEach(0..<3, id: \.self) { _ in
                plate(width: ShellSpace.room, height: ShellSpace.snug)
            }
        }
        .frame(height: touch, alignment: .center)
    }

    private func plate(width: CGFloat? = nil, height: CGFloat) -> some View {
        ShellWaiting(speaks: Self.plateSpeaks)
            .frame(width: width, height: height)
    }
}
