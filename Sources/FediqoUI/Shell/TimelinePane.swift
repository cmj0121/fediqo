import AVKit
import FediqoCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The two marks in the timeline's header, and whether either has anything to do (#33).
///
/// **Handed down rather than worked out here.** Whether the search may open and whether there is
/// anything to reload are the two functions `FediqoRootView` asks before it lets `/` and `r`
/// do anything, and a pane that decided it for itself would be the same rule written twice —
/// which is how a mark and the key it stands for come to disagree. This carries the answers and
/// the presses together, so a call site cannot pass one without the other.
struct TimelineWays {
    /// Whether the search can be opened from where the reader is. False draws no mark at all:
    /// the head's own rule, and not a row's — a row's marks are all drawn, dim where they cannot
    /// be pressed.
    var canSearch: Bool
    var onSearch: () -> Void
    /// Whether there is anything for `r` to ask for. A reload already running is still `true` —
    /// the mark keeps its place rather than blinking out from under the finger that pressed it,
    /// and stays the mark: a plate there would be a second loading animation beside the toast.
    var canReload: Bool
    var onReload: () -> Void
}

/// The timeline place: named queries, a brief rule, then the stream or a thread — and Trends,
/// whose Posts are the same stream on the `.trends` query (DESIGN-trends, option C), drawn
/// under Trends' own tabs and not under the timelines' names.
struct TimelinePane: View {
    @Bindable var session: ShellSession
    @Binding var selectedID: String?
    /// The step of the walk the reader is standing on, where they have walked anywhere (#122):
    /// a conversation, or somebody's page. Held by the app, because leaving it is `Escape` and
    /// `q` — which are read where the keys are.
    ///
    /// **One value where there were two bindings.** A person and a thread were held here as two
    /// optionals and drawn by an `if`/`else if` whose order was the layer order restated; the
    /// walk says which is in front, and this pane draws whatever that is.
    var standing: ShellStep?
    /// A press on a face or a name, answered by the root under the walk's own rule.
    var onOpenPerson: (DummyPerson) -> Void
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
    /// A press to leave whatever is in front: one step back out of the walk. Both panes press
    /// it, because both are steps of the same walk.
    var onBack: () -> Void
    /// The search and the reload, as a finger reaches them.
    var ways: TimelineWays
    /// While open, its results are the list and the timeline waits under it (#32).
    var search: ShellSearch?
    /// What sources say of the people whose pages are opened (#310), held by the app beside the
    /// walk. Nothing where the pane is drawn with none: every page is then what this device
    /// holds, and nobody is asked.
    var people: ShellPersonPages?
    /// A row of a list of people opened (#311), answered by the root: it lights the row and
    /// takes the step together, so leaving that person's page gives the row back.
    var onOpenListed: (Person) -> Void = { _ in }
    /// A row of the hashtags followed opened (#318), answered by the root: a hashtag's page.
    var onOpenRisingRow: (RisingRow) -> Void = { _ in }
    /// A row of a tab of what is rising on Trends opened (#320), answered by the root: a
    /// hashtag's page, or a link through the door a post's link goes through, of the first
    /// source that named it.
    var onOpenRising: (RisingListed) -> Void = { _ in }
    /// The page of a rising link whose posts are open (#379), answered by the root: through the
    /// door a post's link goes through, of the first source that named it.
    var onOpenSharedPage: (SharedLink) -> Void = { _ in }
    /// A report's own page on the server tended (#381), answered by the root: through the door a
    /// post's link goes through, of that source.
    var onOpenServerPage: (URL, String) -> Void = { _, _ in }
    /// A tab of a server tended pressed or swiped to, answered by the root: the step turned in place.
    var onTurnTending: (TendingTab) -> Void = { _ in }
    /// A row of what a search found at a source opened (#319), answered by the root: somebody's
    /// page, a hashtag's, or the page of all of one kind.
    var onOpenFound: (SearchFoundRow) -> Void = { _ in }
    /// A tab of the page of what a source found pressed or swiped to, answered by the root:
    /// the step turned in place (F10).
    var onTurnFound: (FoundWhich) -> Void = { _ in }
    /// The way to the hashtags followed, pressed on the reader's own page (#318).
    var onFollowed: (FollowedTagsEntry) -> Void = { _ in }
    /// The way to the people who ask to follow the reader, pressed there (#313).
    var onRequests: (RequestsEntry) -> Void = { _ in }
    var onKeeping: (KeepingEntry) -> Void = { _ in }
    /// A hashtag somebody features, or the way to the people they feature, pressed on About
    /// of their page (#315, #318), answered by the root: a step of the walk.
    var onOpenFeatured: (FeaturedPress) -> Void = { _ in }
    /// Who boosted or favourited a post, pressed in its `…` (#334), answered by the root: a step
    /// of the walk from the row pressed.
    var onOpenPeople: (PeopleList, String) -> Void = { _, _ in }
    /// Whether a post's link is drawn with its preview (#335): the person's preference, handed in
    /// by the root, so building a row's acts reads nothing of the environment.
    var linkPreviews = true
    /// The press about looking somebody up through a source, answered by the root.
    var onLookUp: (SearchLookUpLine.Press) -> Void = { _ in }
    /// Trends' tabs, where this pane is Trends: drawn in place of the timelines' names, and
    /// Hashtags and Links drawn in place of the stream when they are in front. Nothing on the
    /// timeline, which is then drawn exactly as it was.
    var trends: TrendsHead?
    /// Bumped once each server's emoji catalogue has landed, so the rows already on screen ask
    /// again. Per host and not one counter for the pane: see `waitForCatalogues`.
    @State private var settledHosts: Set<String> = []
    @State private var toast: String?
    @State private var toastTick = 0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(DummyPrefs.self) private var prefs
    /// Nothing here but a finger (#303): the list marks the post being read as it scrolls, one
    /// press opens a row, and the selection is neither drawn nor followed. See `ShellReadingMark`.
    @Environment(\.shellTouch) private var touch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellLayout) private var shellLayout
    /// Counted up each time a timeline returned to has a post to put back at the top (#303).
    /// The list answers the count and not the switch: a list drawn afresh — a return through a
    /// timeline with no posts — is not there to hear the switch, and is there for this.
    @State private var returns = 0
    /// How far a sideways swipe has slid what is under the head (#305). Read by `Slid`, and by
    /// the head's dots, which lean with it.
    private var slide: PageSlide { session.slide(trends == nil ? "timeline" : "trends") }
    /// When the reload mark was last pressed to begin a reload (#307). See `reloadMark`.
    @State private var reloadPressed: Date?
    /// A jump to the top read the newest page afresh (#359, C22): the list is put at its head
    /// once that page is drawn, from the change of what it draws (`listedNewest`).
    @State private var toNewest = false

    private var timeline: TimelineQuery { session.currentTimeline }

    /// A search is open over this timeline. `search` is never nil in the product — the root holds
    /// one for the life of the window — so whether one is open is this, and not `search == nil`.
    private var searching: Bool { search?.isOpen == true }

    /// The people and the hashtags the sources found for the search's words (#319): drawn over
    /// its posts, and none with no search open.
    private var foundBands: [SearchBands] {
        guard searching, let search, search.isSearching, let people else { return [] }
        return people.found.said(for: search.pattern, in: session)
    }

    private var items: [DummyItem] {
        search.flatMap { session.searched($0, latest: prefs.latestDate) }
            ?? session.timelineItems(latest: prefs.latestDate)
    }

    /// Running first; a live note replaces a leftover line; otherwise the reload
    /// line. Loading and a miss do not auto-dismiss: a 2s flash is a fact the
    /// reader has to act on, gone.
    ///
    /// **The page in front's, and nobody else's** (decision 17): where a page of its own asks
    /// (`askInFront`), its ask is the toast, and a reload of the stream running under it is out
    /// of sight and unsaid. Where the stream is in front, the stream's reload, as it always was.
    static func banner(_ ask: PageAsking?, note: String?, in session: ShellSession) -> TimelineToast? {
        if let ask { return TimelineToast.asked(ask, note: note) }
        return TimelineToast.shown(
            running: session.reload.running,
            waiting: session.reload.onlyWaiting,
            line: session.reload.line,
            stopped: session.reload.stopped,
            note: note
        )
    }

    /// Whose asking is in front of the stream (DESIGN-reload): what the toast says, what the
    /// mark stops, and what `Escape` stops — **the one decision of it**, so the three cannot
    /// come to name different asks.
    enum AskInFront: Equatable {
        case person(DummyPerson)
        case people(PeopleList)
        case followed(FollowedTags)
        /// A hashtag's page: its ask of the sources, as the side in front made it.
        case tag(PostTag)
        /// The posts sharing a rising link (#379): its asks of the sources that list them.
        case shared(SharedLink)
        /// A server tended (#380): its ask of what the server keeps for those who answer for it.
        case tending(Tending)
        /// A tab of Trends that lists what is rising, with nothing drawn over it.
        case rising(RisingWhich)
        /// A page that asks nothing of its own: the hashtags a search found.
        case quiet
    }

    /// What is in front of the stream that asks for itself, or nothing where the stream is in
    /// front — the timeline, Posts, a conversation, and any step that cannot be drawn, since the
    /// stream is drawn in its stead. `rising` is Trends' tab in front where
    /// it lists what is rising.
    static func askInFront(
        _ standing: ShellStep?, rising: RisingWhich?, of people: ShellPersonPages?, in session: ShellSession
    ) -> AskInFront? {
        guard let people else { return nil }
        let shown = drawn(standing, of: people, in: session)
        switch standing {
        case .person(let who): return .person(who)
        case .people(let list) where shown.drawn: return .people(list)
        case .found where shown.drawn:
            guard let found = shown.found else { return nil }
            return found.which == .people ? .people(found.at.people) : .quiet
        case .followedTags(let page) where shown.drawn: return .followed(page)
        case .shared(let page) where shown.drawn: return .shared(page)
        case .server(let page) where shown.drawn: return .tending(page)
        // Always drawn, whatever it holds.
        case .tag(let tag): return .tag(tag)
        case .thread where shown.drawn: return nil
        case .people, .found, .followedTags, .shared, .server, .thread, .link, nil: break
        }
        // What stands in the stream's place on Trends, where a tab of what is rising is drawn.
        guard let rising, people.rising.said(rising, in: session) != nil else { return nil }
        return .rising(rising)
    }

    /// What the page in front is asking now, as its store says it.
    static func ask(_ front: AskInFront, of people: ShellPersonPages, in session: ShellSession) -> PageAsking {
        switch front {
        case .person(let who): people.ask(of: who, in: session)
        case .people(let list): people.lists.ask(of: list, in: session)
        case .followed(let page): people.followed.ask(of: page, in: session)
        case .tag(let tag): session.reload.tagPageAsk(of: tag, on: session.stream)
        case .shared(let page): people.shared.ask(of: page)
        case .tending(let page): people.tending.ask(of: page)
        case .rising(let which): people.rising.ask(of: which, in: session)
        case .quiet: PageAsking()
        }
    }

    /// Stop on the page in front, and `Escape` there: its own ask called off, landing as
    /// stopped, and nothing else — a reload of the stream under it goes on. Whether anything
    /// was stopped.
    @discardableResult
    static func stop(_ front: AskInFront, of people: ShellPersonPages, in session: ShellSession) -> Bool {
        switch front {
        case .person(let who): people.stop(who, in: session)
        case .people(let list): people.lists.stop(list)
        case .followed(let page): people.followed.stop(page)
        case .tag(let tag): session.reload.stopTag(tag, on: session.stream)
        case .shared(let page): people.shared.stop(page)
        case .tending(let page): people.tending.stop(page)
        case .rising(let which): people.rising.stop(which)
        case .quiet: false
        }
    }

    /// The stream's Stop, while a reload the reader pressed for runs (#307).
    private var streamStop: (() -> Void)? {
        session.reload.stoppable ? { _ = session.reload.stop() } : nil
    }

    /// The page in front's Stop, where what it asks now is a wait the reader pressed for, and
    /// nothing otherwise: the bar's mark is then Stop.
    private func onStop(_ front: AskInFront) -> (() -> Void)? {
        guard let people, Self.ask(front, of: people, in: session).stoppable else { return nil }
        return { Self.stop(front, of: people, in: session) }
    }

    var body: some View {
        // What the page in front asks of its own, where it does: its toast (decision 17).
        let asked = Self.askInFront(standing, rising: trends?.front.rising, of: people, in: session)
            .flatMap { front in people.map { Self.ask(front, of: $0, in: session) } }
        // What is drawn of the step in front, asked once a pass: the head, the page and the
        // swipe all read this one answer.
        let shown = Self.drawn(standing, of: people, in: session)
        let root = shown.root, listed = shown.list, drawn = shown.drawn
        VStack(alignment: .leading, spacing: 0) {
            // **Somebody's page is a page of its own** (F9), **and every page opened over the
            // stream** (F10): each takes the pane's whole height, and the timelines' names, the
            // search and the reload are not drawn over it.
            if Self.headDrawn(over: standing, drawn: drawn) {
                header
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.top, ShellSpace.step)
                    .padding(.bottom, ShellSpace.snug)
                    // The head stays where it is and shows the change: a swipe begins under it.
                    .headOfPage()
                    .modifier(ProbedPane(part: .head))

                ShellRule()
            }

            Group {
            // **Whatever step the reader is standing on** (#122). A face pressed inside a
            // conversation opens over it, and a row pressed on that page opens over the page;
            // which is in front is `ShellWalk` and is not decided again here. **No `default:`.**
            switch standing {
            case .person(let person):
                personPage(person)
            case .tag(let tag):
                tagPage(tag)
            case .people(let list):
                // A list whose source is no longer one that says who people are — removed since
                // — draws the stream instead, as a conversation no longer held does.
                if let people, let listed {
                    peoplePage(list, said: listed, in: people)
                } else {
                    underneath
                }
            case .found(_, let which):
                // Neither kind left to draw — the answer no longer held and its people no longer
                // asked of a source that says who people are — draws the stream; one left, that one.
                if let people, let found = shown.found {
                    foundPage(found, standing: which, in: people)
                } else {
                    underneath
                }
            case .followedTags(let page):
                // No such list to draw — the sign-in ended, or sees who is followed no longer,
                // or its source was removed — draws the stream instead.
                if let followed = people?.followed, let said = shown.followed {
                    followedPage(page, said: said, in: followed)
                } else {
                    underneath
                }
            case .server(let page):
                // The standing, or the words, gone since — or the source — draws the stream instead.
                if let tending = people?.tending, drawn {
                    tendingPage(page, in: tending)
                } else {
                    underneath
                }
            case .shared(let page):
                // Every source it was asked of removed since draws the stream instead.
                if let shared = people?.shared, drawn {
                    sharedPage(page, in: shared)
                } else {
                    underneath
                }
            case .thread:
                // A root this device no longer holds draws the stream instead, which is the same
                // answer the pane gave when it looked the root up among the timeline's own rows.
                if let root {
                    conversationPage(root)
                } else {
                    underneath
                }
            // A page read out of a post is never what this pane is handed: it is drawn over the
            // step beneath it (`ShellWalk.beneath`, `LinkInPlace`), which is what stands here.
            case .link, nil:
                underneath
            }
            }
            // What is under the head follows a sideways swipe (#305) — this, and not the pane.
            .modifier(ProbedPane(part: .under))
            .modifier(Slid(slide: slide))
        }
        // **A sideways swipe, heard on the pane and begun under its head** (#305): whatever it draws —
        // posts, or that there are none — and whichever page is in front. On the timeline it
        // goes to the one beside; on a list opened over it, it goes back; on somebody's page, a conversation's or a hashtag's it is that page's own.
        // What follows the finger stays inside the pane: not over the rail on a wide page.
        .modifier(SwipesSideways(
            session: session, slide: slide, touch: touch, page: Self.page(standing, drawn: drawn),
            opened: Self.openedID(standing), searching: searching, back: onBack, trends: trends
        ))
        .modifier(HoldsSlide(holds: touch))
        // One asker for the `…` of every row under this pane — the timeline, a conversation, a
        // person's page, a tag's.
        .modifier(RowAsks(session: session))
        .modifier(ReloadToast(
            toast: Self.banner(asked, note: toast, in: session),
            // The pieces on the wire are the stream's reload's alone (#170).
            work: asked == nil ? session.work : nil, reading: asked == nil ? session.reload.reading : []
        ))
        // The timeline in front read from this device as it shows (#357).
        .modifier(CoversTimeline(session: session, latest: prefs.latestDate))
        .task(id: catalogueHosts) { await waitForCatalogues() }
        .onChange(of: session.toast) { _, toast in
            if let toast { showToast(toast.text) }
        }
        // Each timeline keeps the post the reader was on (#100). The one left writes down where
        // they were standing; the one arrived at lights what it wrote down last time, among the
        // posts it holds now — nothing at all for a timeline this run has not opened, which is
        // also the answer the old line gave on every switch.
        //
        // **Not while the search is open** (#32). The lamp is then the search's own, and the
        // post the timeline underneath was on is parked inside `ShellSearch` waiting to be
        // handed back. Writing a result's id into the timeline's place would lose that post and
        // put a result in its stead.
        //
        // **Open, and not merely there** (#144). The root hands this pane its one `ShellSearch`
        // whether or not a search is open, so a test for `nil` was false on every switch the
        // product ever made: no timeline's place was written down or given back, and the only
        // line that ran was the one that puts the lamp out where the arrived-at list lacks it.
        // A post that happened to be in both lists stayed lit, which read as a place kept.
        //
        // **With the search open, the parked post is what moves** (#145). The search now asks
        // the timeline in front, so switching searches the new one with the pattern kept, and
        // the lamp stays on a result only where the new results still hold it. The post parked
        // for the old timeline is written down as its place, and the new timeline's own is
        // parked instead — among the posts that timeline shows, not among the results — so
        // closing the search gives back the post of the timeline the reader is in.
        .onChange(of: session.timelineID) { left, arrived in
            // Trends' posts are no timeline of the timeline's: a switch there is not this list's.
            guard trends == nil else { return }
            let top = session.scrolledTop
            // Another list, so the row the last one had at the top means nothing here.
            session.scrolledTop = nil
            // A tag's page stays over the switch, and its lamp and the place under it are
            // `FediqoRootView.timelineSwitched`'s (#197): only the search's parked post is filed here.
            let onTag = if case .tag = standing { true } else { false }
            // And the rows the mark was among are not this list's (#303).
            let mark = session.readingMark
            let wasReading = mark.left()
            mark.forget(for: arrived?.id ?? TimelineQuery.all.id)
            // The one left keeps the stretch round the post it was left at, drawn at once on the
            // way back (#359).
            session.timelineLeft(left ?? .all, at: (touch ? wasReading : selectedID) ?? top)
            if !searching {
                if !onTag {
                    // Under a finger the place kept is the post being read, and the one given
                    // back is marked and put at the top; nothing is selected.
                    let kept = session.timelinePlaces.switched(
                        from: left, to: arrived, standingOn: touch ? wasReading : selectedID,
                        among: searching ? items.map(\.id) : session.timelineIDs(latest: prefs.latestDate)
                    )
                    let restored = Self.restored(kept, touch: touch)
                    if touch {
                        mark.keep(restored.marked)
                        returns += 1
                    }
                    if selectedID != restored.selected { selectedID = restored.selected }
                }
            } else {
                let shown = session.timelineItems(latest: prefs.latestDate).map(\.id)
                search?.switched { parked in
                    session.timelinePlaces.switched(from: left, to: arrived, standingOn: parked, among: shown)
                }
                if !onTag, let selectedID, !items.contains(where: { $0.id == selectedID }) {
                    self.selectedID = nil
                }
                // A search sent to the last timeline's sources is sent to this one's (#176).
                let now = session.currentTimeline
                let pattern = search?.pattern ?? ""
                Task { await session.reload.searchSwitched(to: now, pattern: pattern, in: session) }
            }
            // The walk ends on the same change, where it is held: `FediqoRootView` clears it, all
            // but a tag's page in front, which stays and asks the new timeline (#197).
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
        let http = WatchedHTTP(session.http, for: .emoji, in: session.work)
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
                try await SourceReach.mastodon(host, over: http).customEmojis()
            }
        }
        await store.settle(host: host)
    }

    /// Whether the row at `index` of `count`, coming into view, asks the timeline in front for its
    /// next stretch (#87): one of the last `moreAhead`, so the next stretch is on its way before
    /// the reader reaches the end rather than after. **Never a search's**: a search shows what this
    /// device holds, and the end of its results is not the end of any source's timeline.
    static func asksForMore(at index: Int, of count: Int, searching: Bool) -> Bool {
        !searching && index >= count - moreAhead
    }

    /// How many rows from the end reading starts asking for more.
    static let moreAhead = 5

    /// Where a list drawn afresh puts the reader (#110).
    enum Landing: Equatable, Sendable {
        /// The lamp's row, in the middle — what coming back from a thread has always done.
        case centred(String)
        /// The row that was at the top when the list was last drawn, at the top again.
        case top(String)
    }

    /// **The lamp first, and the place scrolled to where there is no lamp.** A list is drawn
    /// afresh by a thread closing and, since #110, by a window dragged across the width where
    /// the arrangement changes — and a reader who scrolled without lighting anything was put
    /// back at the top, which is the place scrolled to lost. A static function over the two
    /// facts, so the order between them is a thing a test can ask.
    ///
    /// **Under a finger there is no lamp to centre** (#303): the list goes back to the place
    /// scrolled to, whatever a press that opened something left selected.
    ///
    /// **And to the post being read before the row that was at the top**, which is the one
    /// above it where that row was cut by the top of the list: coming back, the lamp is on the
    /// post it was on. A timeline returned to through one with no posts is drawn afresh too,
    /// and the post it was left at is the mark by then (`ShellReadingMark.keep`).
    static func landing(selected: String?, top: String?, touch: Bool = false, marked: String? = nil) -> Landing? {
        if !touch, let id = DummyCommand.centredOnAppear(selected: selected) { return .centred(id) }
        return ((touch ? marked : nil) ?? top).map(Landing.top)
    }

    /// Where a timeline returned to puts the post it was left at (#100, #303): in the middle
    /// where it is the selection, and at the top where it is the mark under a finger — the
    /// first row wholly on screen is then that post. Nothing for a timeline with no post kept.
    ///
    /// **And one with no post kept — never visited — at its first post, at the top** (#305):
    /// `first` is that post. **With a keyboard or a pointer too, and meant**: there a timeline
    /// keeps a post only while one is selected, so a switch with nothing selected opens the
    /// timeline at its top. It did so already unless the two timelines shared a row. Left alone, the scroll view keeps a row the two timelines share
    /// where it stood, and a timeline opens for the first time somewhere down its length.
    static func arrival(selected: String?, returning: String?, touch: Bool, first: String? = nil) -> Landing? {
        if let kept = touch ? returning.map(Landing.top) : selected.map(Landing.centred) { return kept }
        return TimelineSwipe.opensAt(kept: nil, first: first).map(Landing.top)
    }

    /// What is in front, as far as a sideways swipe cares (#305): the timeline itself, a page
    /// opened over it, or a page read out of a post, which is somebody's own.
    static func page(_ standing: ShellStep?, drawn: Bool = true) -> TimelineSwipe.Page {
        switch standing {
        // Somebody's page has tabs of its own, and its sideways is theirs (F9); a hashtag's
        // is the frame's too, with tabs or with none (F10).
        case .person, .tag: .tabbed
        // A conversation's page is the frame's, and its sideways the frame's (F10) — where it
        // is drawn; over the stream drawn in its stead the swipe goes back, as it did.
        // So is a list of people's (F10), where it is drawn.
        // And what a search found at a source, and the hashtags followed.
        case .thread, .people, .found, .followedTags, .shared, .server: drawn ? .tabbed : .opened
        case .link: .link
        case nil: .timeline
        }
    }

    /// Whether the timelines' head — their names, the search, the reload — is drawn over what
    /// the reader stands on: not over somebody's page, a conversation's, a hashtag's, a list
    /// of people's, what a search found nor the hashtags followed, each a page
    /// of its own. **Asked of what is drawn, not of the step alone** (F10 §1): any of those
    /// that cannot be drawn (`drawn` false) draws the stream, and the head is over that.
    static func headDrawn(over standing: ShellStep?, drawn: Bool = true) -> Bool {
        switch standing {
        case .person, .tag: false
        case .thread, .people, .found, .followedTags, .shared, .server: !drawn
        case .link, nil: true
        }
    }

    /// Whether the search field is drawn at the pane's foot: where a search is `open` and the
    /// timelines' head is drawn (`headDrawn`), and nowhere else. The field is the stream's, as
    /// the head is, so a page opened over a search's results — a page about one thing — takes the
    /// whole place without it (F10); the search stays open behind the page, as it was, and its
    /// field is drawn again when the walk leaves the page (`ShellSearch.appeared`).
    static func searchFieldDrawn(open: Bool, over standing: ShellStep?, drawn: Bool) -> Bool {
        open && headDrawn(over: standing, drawn: drawn)
    }

    /// What is drawn of the step in front: the post a conversation is around, where this device
    /// still holds it; the list a list of people's page is handed, where it can be said; and
    /// whether the step's page is drawn at all. A conversation whose post is no longer held, or
    /// a list nobody can say — its source gone, nobody signed in to see it — is not, and the
    /// stream is drawn in its stead.
    ///
    /// **The one decision of what is drawn**: the pane's body, its head and its swipe, and the
    /// root asked what Tab and `r` do, all ask it here, handed the same things.
    struct Drawn {
        var root: DummyItem?
        var list: PeopleSaid?
        /// What the tab of what a search found in front is handed, where any tab is left.
        var found: FoundSaid?
        /// What the list of the hashtags followed is handed, where the sign-in still sees it.
        var followed: FollowedTagsSaid?
        var drawn: Bool
    }

    static func drawn(_ standing: ShellStep?, of people: ShellPersonPages?, in session: ShellSession) -> Drawn {
        switch standing {
        case .thread(let id):
            let root = session.held(id)
            return Drawn(root: root, drawn: root != nil)
        case .people(let list):
            let said = people?.lists.said(of: list, in: session)
            return Drawn(list: said, drawn: said != nil)
        case .found(let at, let which):
            let said = people?.found.drawn(at, at: which, in: session)
            return Drawn(found: said, drawn: said != nil)
        case .followedTags(let page):
            let said = people?.followed.said(of: page, in: session)
            return Drawn(followed: said, drawn: said != nil)
        case .shared(let page):
            return Drawn(drawn: people?.shared.canAskAgain(page, in: session) ?? false)
        case .server(let page):
            return Drawn(drawn: people != nil && ShellTending.drawn(page, in: session))
        case .person, .tag, .link, nil:
            return Drawn(drawn: true)
        }
    }

    /// Somebody's page (F9): handed which tabs it has, which is in front and each part's own
    /// value, all of them worked out where the source is asked — nothing here looks at which
    /// kind of source theirs is.
    private func personPage(_ person: DummyPerson) -> some View {
        let held = session.heldPosts(of: person)
        let said = people?.said(of: person, in: session)
        let tabs = people?.tabs(of: person, in: session) ?? [.posts]
        let front = people?.front(of: person, in: session) ?? .posts
        return PersonPage(
            person: person,
            tabs: tabs,
            front: front,
            head: people?.head(of: person, in: session)
                ?? PersonHeadSaid.made(of: person, said: nil, tabs: tabs, held: held.count, heldAtLeast: session.heldAtLeast, standing: nil),
            // What their source says of them, where it says who people are; nothing for
            // anybody else, and then this is the page it always was.
            said: said,
            about: people?.about(of: person, in: session),
            posts: PostRowsSaid.posts(of: said, held: held, standing: people?.stands(to: person, in: session)),
            pinned: front == .pinned ? people?.pinned(of: person, in: session).map { PostRowsSaid.pinned($0) } : nil,
            people: people.flatMap { pages in
                pages.list(front, of: person, in: session).flatMap { pages.lists.said(of: $0, in: session) }
            },
            lookUp: people.flatMap { $0.found.line(of: person, said: said, in: session) },
            // Their own server, asked only at this line's press and as nobody (#310).
            home: people?.homeLine(of: person, in: session),
            rows: PersonPageRows(
                catalogues: session.emoji,
                catalogueSettled: settledHosts.contains(person.host),
                posts: session.posts,
                // A row here opens the conversation it belongs to (#122), so the answer mark
                // does what it does on the timeline: it opens that conversation first. A post
                // that is on the page only is made an item by the press, and then acts.
                acting: { item in
                    people?.acting(item, of: person, in: session, held: { acting($0) }) ?? acting(item)
                },
                playback: playback,
                onPlayRow: onPlayRow,
                onViewRow: onViewRow,
                onTurnRow: onTurnRow,
                onOpenThread: onOpenThread
            ),
            selectedID: $selectedID,
            decks: $decks,
            jumpToTop: jumpToTop,
            slide: session.slide("person"),
            canReload: ways.canReload,
            acts: personActs(person)
        )
        // One page per person, so opening a second face from inside one draws afresh.
        .id(person.id)
        // **How the reader stands to them is asked once the page has said who they
        // are** — by the id the source gave — and again for a reader who changed or a
        // sign-in given follows: read, never acted.
        .task(id: people?.standsOpening(to: person, in: session)) { await people?.standsOpened(to: person, in: session) }
        // **The ask is the page opening**, once a person a run: who they are, of the source
        // they were met through and nobody else — and none of their posts (F9).
        // And who asks is part of which opening it is: a reader who ends, begins or
        // changes while the page is in front opens it again, and it is asked as them.
        .task(id: ShellPersonPages.opening(person, in: session)) { await people?.opened(person, in: session) }
        // **A tab asks when it is first in front, and never before**: their posts, what
        // they pinned, a list of people. About asks nothing.
        .task(id: people?.fronting(person, in: session)) { await people?.fronted(person, in: session) }
        // **And what they feature, once the source has said who they are** (B7): their
        // hashtags, and whether they feature anybody — two asks more of the page opening.
        .task(id: people?.featuredOpening(of: person, in: session)) { await people?.featuredOpened(person, in: session) }
        // **And what only staff see of them** (#382), **and who is known in common** (#377): two
        // asks of the page's own, in one modifier so the page's chain does not grow.
        .modifier(PersonPageAsks(person: person, people: people, session: session))
        // What their own server said is held only while this page is in front (#310).
        .onDisappear { people?.home.letGo(of: person) }
        // And what only staff see of them (#382).
        .onDisappear { people?.tending.people.forgetStaff(of: people?.said(of: person, in: session)?.person) }
    }

    /// What the parts of somebody's page press.
    private func personActs(_ person: DummyPerson) -> PersonPageActs {
        PersonPageActs(
            onBack: onBack,
            onTab: { tab in _ = people?.turn(person, to: tab, lamp: &selectedID, in: session) },
            onReload: ways.onReload,
            onPull: { await people?.again(person, in: session) },
            // While what the page asks runs, the bar's mark stops it, and nothing else.
            onStop: onStop(.person(person)),
            onLookUp: onLookUp,
            onHome: { press in Task { await people?.homePressed(press, on: person, in: session) } },
            // Where they moved to is somebody this same source names: their page is
            // asked of it by that name, and "not heard of" is a state of that page.
            onOpenMoved: { moved in
                if let there = DummyPerson(handle: moved.handle, host: person.host) { onOpenPerson(there) }
            },
            onFollowed: onFollowed,
            onRequests: onRequests,
            onKeeping: onKeeping,
            onFeatured: { press in
                switch press {
                case .takeOff(let tag):
                    Task { await people?.features.takeOff(tag, of: person, said: people?.said(of: person, in: session), in: session) }
                case .tag, .people:
                    onOpenFeatured(press)
                }
            },

            onListAct: { act, listed in
                guard let people, let list = people.list(people.front(of: person, in: session), of: person, in: session) else { return }
                Task { await people.lists.press(act, on: listed, of: list, in: session) }
            },
            onAct: { act in Task { await people?.act(act, on: person, in: session) } },
            onNote: { words in
                // Nothing written: the lock's press, which only asks for the account part.
                guard let words else {
                    _ = session.askFor([PersonAct.feature.needs], host: person.host)
                    return
                }
                guard let people else { return }
                Task { await people.acts.writeNote(words, of: person, said: people.said(of: person, in: session), in: session) }
            },
            onLanguages: { codes in Task { await people?.chooseLanguages(codes, of: person, in: session) } },
            onAskFollows: { session.askFor([PersonAct.follow.needs], host: person.host) },
            onChange: { people?.changeOwn(person, in: session) },
            onReadOn: { Task { await people?.readOn(person, in: session) } },
            onPinnedReadOn: { Task { await people?.pinnedReadOn(person, in: session) } },
            onOpenListed: onOpenListed,
            onListAgain: { Task { await people?.fronted(person, again: true, in: session) } },
            onListReadOn: {
                guard let people, let list = people.list(people.front(of: person, in: session), of: person, in: session) else { return }
                Task { await people.lists.readOn(list, in: session) }
            },
            onStaffAct: { staff in
                guard let shown = staff.account.person else { return }
                people?.tending.people.openAct(
                    on: staff.account.id, handle: shown.handle, local: staff.account.local, at: staff.host, in: session
                )
            }
        )
    }

    /// A conversation's page (F10): the whole height of the pane, in the frame every opened
    /// page stands in, with what its bar says worked out from the post it is around.
    private func conversationPage(_ opened: DummyItem) -> some View {
        ConversationPage(
            said: ConversationSaid.made(of: opened, blog: session.blogs.reading(of: opened) != nil, canReload: ways.canReload),
            slide: session.slide("thread"),
            onBack: onBack,
            onReload: ways.onReload,
            // Pulled down, the conversation is read again as `r` reads it there (#307).
            onPull: {
                await PullsToReload.pull(offered: true, reload: ways.onReload, settled: { await session.reload.settled(.thread) })
            },
            // While a read the reader pressed for runs, the bar's mark stops it (#307).
            onStop: session.reload.stoppable ? { session.reload.stop() } : nil,
            rows: { titleRow in
                DummyThreadPane(
                    root: opened,
                    catalogues: session.emoji,
                    catalogueSettled: settledHosts.contains(opened.source.host),
                    posts: session.posts,
                    conversations: session.conversations,
                    onAskAround: { Task { await session.conversations.again(opened, in: session) } },
                    onReadFurther: { Task { await session.conversations.press(opened, in: session) } },
                    onReachFurther: { appeared in
                        Task { await session.conversations.reached(opened, appeared: appeared, in: session) }
                    },
                    // A ranked blog's standing, read here where the session is (#209).
                    blog: session.blogs.reading(of: opened),
                    onReadBlog: { Task { await session.blogs.again(opened) } },
                    // The password is handed on and not kept (#213).
                    onUnlockBlog: { password in Task { await session.blogs.unlock(opened, password: password) } },
                    onSignIn: { Task { await session.signIn(host: opened.source.host) } },
                    selectedID: $selectedID,
                    // Inside the conversation the answer mark opens the answer (#108).
                    acting: { acting($0, inside: opened) },
                    decks: $decks,
                    playback: playback,
                    onPlayRow: onPlayRow,
                    onViewRow: onViewRow,
                    onTurnRow: onTurnRow,
                    onOpenThread: onOpenThread,
                    onOpenPerson: onOpenPerson,
                    jumpToTop: jumpToTop,
                    titleRow: titleRow
                )
            }
        )
        // One pane per thread, so going back from a nested one draws its parent
        // afresh.
        .id(opened.id)
        // **The ask is the pane opening** — #90, and since #198 for a forum topic's
        // replies too. A thread is what the reader has just pressed Return on, so
        // nothing asks them a second time for a thing they have already said they
        // want; asked once per post per run, so reopening draws what is already held.
        // And from here it is the thread in front, which the wait asks again.
        .task(id: opened.id) { await session.reload.opened(opened, in: session) }
        // What `r` last said about this thread goes with it (#175): the timeline under
        // it does not go on saying a thread nobody is reading could not be reloaded.
        // And a page still on its way for it stops (#177): nobody is reading on. Nor
        // is it asked again on the wait any more (#198).
        .onDisappear {
            session.reload.forget(.thread)
            session.reload.left(opened)
            session.stopReadingFurther(of: opened)
        }
    }

    /// A list of people's page (F10): the whole height of the pane, in the frame every opened
    /// page stands in, with no tabs, handed what its source said — worked out where the source
    /// is asked, and nothing here looks at which kind of source it is.
    private func peoplePage(_ list: PeopleList, said: PeopleSaid, in people: ShellPersonPages) -> some View {
        PeoplePane(
            said: said,
            selectedID: $selectedID,
            slide: session.slide("people"),
            canReload: ways.canReload,
            onOpen: onOpenListed,
            onAskAgain: { Task { await people.lists.again(list, in: session) } },
            onReload: ways.onReload,
            // Pulled down, the list is asked from the top as `r` asks it.
            onPull: { await people.lists.again(list, in: session) },
            // While it is asked, the bar's mark stops that ask.
            onStop: onStop(.people(list)),
            onReadOn: { Task { await people.lists.readOn(list, in: session) } },
            onChoose: { choice in Task { await people.lists.choose(choice, for: list, in: session) } },
            onAct: { act, person in Task { await people.lists.press(act, on: person, of: list, in: session) } },
            onAsk: { session.askFor([PersonAct.removeFollower.needs], host: list.host) },
            jumpToTop: jumpToTop,
            onBack: onBack
        )
        // One pane per list, so a second list opened from inside one draws afresh.
        .id(list.id)
        // **The ask is the page opening**, once a list a run: its first stretch, of the source
        // that keeps it and nobody else. Nothing reads on unpressed.
        .task(id: ShellPeoplePages.opening(list, in: session)) { await people.lists.opened(list, in: session) }
    }

    /// What a search found at a source (F10): the whole height of the pane, in the frame every
    /// opened page stands in, handed its tabs and what the tab in front lists — worked out where
    /// the answer is held. Its bar's mark is on People alone, where `r` asks the source for the
    /// people again — and Stop while they are asked, stopping that ask and nothing else.
    ///
    /// The walk stood on `standing`'s tab: where the page draws the other one — that tab lost
    /// everything its source gave — the walk is turned to it, so Tab, the keys and leaving all
    /// stand on the tab that is drawn.
    private func foundPage(_ said: FoundSaid, standing: FoundWhich, in people: ShellPersonPages) -> some View {
        let lists = people.lists, list = said.at.people, which = said.which
        return FoundPage(
            said: said,
            selectedID: $selectedID,
            slide: session.slide("found"),
            reload: FoundPage.reloadName(of: said, canReload: ways.canReload),
            acts: FoundPage.acts(
                onBack: onBack,
                onTab: onTurnFound,
                onReload: ways.onReload,
                // Pulled down on People, the list is asked from the top as `r` asks it.
                onPull: { await lists.again(list, in: session) },
                onStop: which == .people ? onStop(.people(list)) : nil
            ),
            onOpenPerson: onOpenListed,
            onOpenRow: onOpenFound,
            onAskAgain: { Task { await lists.again(list, in: session) } },
            onReadOn: { Task { await lists.readOn(list, in: session) } },
            onAct: { act, person in Task { await lists.press(act, on: person, of: list, in: session) } },
            onAsk: { session.askFor([PersonAct.removeFollower.needs], host: list.host) },
            jumpToTop: jumpToTop
        )
        // One page per source's answer, so another opened from inside one draws afresh.
        .id(said.at.id)
        // **The people are asked when their tab first comes in front**, once a run, as the list
        // of them opened on its own was; the hashtags ask nothing. A tab never in front has
        // asked nothing.
        .task(id: which == .people ? ShellPeoplePages.opening(list, in: session) : nil) {
            if which == .people { await lists.opened(list, in: session) }
        }
        .onChange(of: which != standing, initial: true) { _, fell in
            if fell { onTurnFound(which) }
        }
    }

    /// The hashtags followed (F10): the whole height of the pane, in the frame every opened page
    /// stands in, with no tabs, handed what its source listed. Its bar's mark is where `r` asks
    /// the list again from the top — and Stop while it is asked, stopping that ask alone.
    private func followedPage(_ page: FollowedTags, said: FollowedTagsSaid, in followed: ShellFollowedTags) -> some View {
        FollowedTagsPane(
            said: said,
            selectedID: $selectedID,
            slide: session.slide("followed"),
            reload: FollowedTagsPane.reloadName(of: said, canReload: ways.canReload),
            onOpen: onOpenRisingRow,
            onReload: ways.onReload,
            // Pulled down, the list is asked from the top as `r` asks it.
            onPull: { await followed.again(page, in: session) },
            onStop: onStop(.followed(page)),
            onReadOn: { Task { await followed.readOn(page, in: session) } },
            onAct: { row, to in Task { await followed.press(row.id, on: page, only: to, in: session) } },
            onAsk: { session.askFor([.follows], host: page.host) },
            jumpToTop: jumpToTop,
            onBack: onBack
        )
        .id(page.id)
        // **The ask is the page opening**, once a list a run: its first stretch, as the reader.
        // And who asks is part of which opening it is. Nothing reads on unpressed.
        .task(id: followed.opening(page, in: session)) { await followed.opened(page, in: session) }
    }

    /// A server tended (#380): the whole height of the pane, in the frame every opened page stands
    /// in, with a tab for each task the standing allows. Its bar's mark asks again where `r`
    /// would, and is Stop while the server is asked.
    private func tendingPage(_ page: Tending, in tending: ShellTending) -> some View {
        let people = tending.people
        let askWords = { _ = session.askFor([.tending], host: page.host) }
        return TendingPane(
            page: page,
            tabs: ShellTending.tabs(at: page.host, in: session),
            reports: page.tab == .reports ? tending.said(of: page, in: session) : nil,
            people: page.tab == .people ? people.said(of: page, in: session) : nil,
            servers: page.tab == .servers ? tending.servers.said(of: page, in: session) : nil,
            server: page.tab == .server ? tending.server.said(of: page, in: session) : nil,
            counts: tending.counts(of: page, in: session),
            acts: ShellTending.acts(at: page.host, in: session),
            reload: TendingPane.reloadName(page.host, canReload: ways.canReload),
            slide: session.slide("tending"),
            frame: OpenedPageActs(
                onBack: onBack,
                onTab: onTurnTending,
                onReload: ways.onReload,
                onPull: { await tending.again(page, in: session) },
                onStop: onStop(.tending(page))
            ),
            onReport: TendingReportActs(
                onAct: { act, report in Task { await tending.act(act, on: report.id, of: page, in: session) } },
                onAskWords: askWords,
                onOpenPage: { report in
                    if let url = ShellTending.page(of: report, host: page.host) { onOpenServerPage(url, page.host) }
                },
                onActOnAccount: ShellTendingPeople.actsOn(at: page.host, in: session) ? { report in
                    guard let target = report.target else { return }
                    people.openAct(
                        on: target.accountID, handle: target.handle, local: target.livesHere, at: page.host, report: report.id,
                        in: session
                    )
                } : nil
            ),
            onPeople: TendingPeopleActs(
                onFind: { filter in Task { await people.find(filter, on: page, in: session) } },
                onLetIn: { account in Task { await people.letIn(account.id, of: page, in: session) } },
                onTurnAway: { account in Task { await people.turnAway(account.id, of: page, in: session) } },
                onUndo: { act, account in Task { await people.undo(act, on: account.id, of: page, in: session) } },
                onActOn: { account in
                    people.openAct(
                        on: account.id, handle: account.person?.handle ?? account.id, local: account.local, at: page.host, in: session
                    )
                },
                onAskWords: askWords
            ),
            onServers: TendingServersActs(
                onAdd: { list in tending.servers.open(TendingServersActs.kind(of: list), at: page.host, in: session) },
                onChange: { block in tending.servers.open(.block(block), at: page.host, in: session) },
                onRemove: { list, id in Task { await tending.servers.remove(list, id: id, on: page, in: session) } },
                onReadOn: { list in Task { await tending.servers.readOn(list, of: page, in: session) } },
                onAskWords: askWords
            ),
            onServer: TendingServerActs(
                onSpan: { days in Task { await tending.server.choose(days: days, on: page, in: session) } },
                onReview: { item, rise in Task { await tending.server.review(item, rise: rise, on: page, in: session) } },
                onReadOn: { kind in Task { await tending.server.readOn(kind, of: page, in: session) } },
                onOpenRules: { url in onOpenServerPage(url, page.host) },
                onAskWords: askWords
            ),
            onOpenPerson: onOpenPerson,
            onReadOn: { Task { await tending.readOn(page, pressed: true, in: session) } },
            onReachFoot: { Task { await tending.readOn(page, pressed: false, in: session) } },
            catalogues: session.emoji,
            posts: session.posts,
            selectedID: $selectedID,
            jumpToTop: jumpToTop
        )
        .id(page.host)
        // **The ask is the tab coming in front**, once a run; and again where who is signed in changes.
        .task(id: tending.opening(page, in: session)) { await tending.opened(page, in: session) }
        // **And the head's figures, as the page opens**: the open reports and those waiting, once.
        .task(id: tending.opening(Tending(host: page.host, tab: .reports), in: session)) { await tending.headOpened(page, in: session) }
    }

    /// The posts sharing a rising link (#379): the whole height of the pane, in the frame every
    /// opened page stands in, with no tabs, handed what this device holds of what its sources
    /// listed. Its bar's mark asks them again from the top where `r` would — and is Stop while
    /// they are asked — and its other mark opens the link's own page.
    private func sharedPage(_ page: SharedLink, in shared: ShellSharedLinks) -> some View {
        let said = shared.said(of: page, in: session)
        return SharedLinkPane(
            said: said,
            reload: SharedLinkPane.reloadName(of: said, canReload: ways.canReload),
            slide: session.slide("shared"),
            acts: OpenedPageActs(
                onBack: onBack,
                onReload: ways.onReload,
                // Pulled down, the sources are asked from the top as `r` asks them.
                onPull: { await shared.again(page, in: session) },
                onStop: onStop(.shared(page))
            ),
            onOpenPage: { onOpenSharedPage(page) },
            onReadOn: { Task { await shared.readOn(page, pressed: true, in: session) } },
            onReachFoot: { Task { await shared.readOn(page, pressed: false, in: session) } },
            rows: PersonPageRows(
                catalogues: session.emoji,
                posts: session.posts,
                acting: acting,
                playback: playback,
                onPlayRow: onPlayRow,
                onViewRow: onViewRow,
                onTurnRow: onTurnRow,
                onOpenThread: onOpenThread
            ),
            onOpenPerson: onOpenPerson,
            selectedID: $selectedID,
            decks: $decks,
            jumpToTop: jumpToTop
        )
        .id(page.id)
        // **The ask is the page opening**, once a link a run: each source's newest stretch.
        .task(id: page.id) { await shared.opened(page, in: session) }
    }

    /// A hashtag's page (F10): the whole height of the pane, in the frame every opened page
    /// stands in, handed which tabs it has, which is in front and what its head says — all of
    /// them worked out where its sources are asked, and nothing here looks at which kind of
    /// source any of them is. Its bar's mark asks the sources again where `r` would, and is
    /// Stop while they are asked, stopping that ask and nothing else (decision 11).
    private func tagPage(_ tag: PostTag) -> some View {
        let items = session.heldPosts(under: tag, latest: prefs.latestDate)
        let timeline = session.currentTimeline
        let asked = ways.canReload ? session.reload.tagReach(of: timeline, in: session).asked : []
        return TagPane(
            // Whether the reader follows it at each source they are signed in to (#318), and
            // so whether the page has an About; with nobody to ask, its posts alone.
            said: people?.tags.said(of: tag, held: items.count, in: session)
                ?? TagPageSaid.made(of: tag, held: items.count, follows: [], front: nil, in: session),
            items: items,
            reload: TagPane.reloadName(tag, asking: asked, canReload: ways.canReload),
            slide: session.slide("tag"),
            acts: TagPageActs(
                onBack: onBack,
                onTab: { tab in _ = people?.tags.turn(tag, to: tab, lamp: &selectedID, in: session) },
                // The head's Follow only ever follows, as `l` does.
                onHeadFollow: { line in _ = people?.tags.pressed(line, only: true, in: session) },
                onFollow: { line in _ = people?.tags.pressed(line, in: session) },
                onUnfollow: { line in _ = people?.tags.unfollowed(line, in: session) },
                onFeature: { line in _ = people?.tags.featurePressed(line, in: session) },
                onUnfeature: { line in _ = people?.tags.unfeatured(line, in: session) },
                onAskFollows: { host in session.askFor([.follows], host: host) },
                onReload: ways.onReload,
                // Pulled down, the sources are asked again as `r` asks them, and the spinner
                // stays until that ask is over — landed, failed or stopped.
                onPull: {
                    await session.reload.tagAgain(tag, timeline: timeline, in: session)
                    await session.reload.settled(.tag)
                },
                // While they are asked, the bar's mark stops that ask.
                onStop: onStop(.tag(tag))
            ),
            catalogues: session.emoji,
            catalogueSettled: false,
            posts: session.posts,
            selectedID: $selectedID,
            acting: acting,
            decks: $decks,
            playback: playback,
            onPlayRow: onPlayRow,
            onViewRow: onViewRow,
            onTurnRow: onTurnRow,
            onOpenThread: onOpenThread,
            onOpenPerson: onOpenPerson,
            jumpToTop: jumpToTop
        )
        .id(HeldUnderTag.folded(tag))
        // **The ask is the page coming in front**: each source whose sign-in holds
        // follows, once. And who asks, and what they hold, is part of which opening it
        // is: a sign-in given follows opens the page again, and it is read — never acted.
        // **Asked for the page and not for About**: the head's mark needs the answer, and
        // About, brought in front, asks nothing more.
        .task(id: people?.tags.opening(tag, in: session)) { await people?.tags.opened(tag, in: session) }
        // Once those have said, where a source did not say whether it is featured there, the
        // reader's own featured hashtags are asked of it — once a run (#318).
        .task(id: people?.tags.opening(tag, in: session)) { await people?.tags.featuresOpened(tag, in: session) }

        // What a source said of a hashtag is held only while its page is in front.
        .onDisappear { people?.tags.closed(tag) }
        // About gone from under the reader — the sign-in ended: the page is its posts, and
        // the lamp is on no block that is no longer there.
        .onChange(of: people?.tags.tabs(of: tag, in: session)) { _, _ in
            people?.tags.tabsChanged(tag, lamp: &selectedID, in: session)
        }
    }

    /// A name for the page opened, so a swipe begun on one is not acted on over another.
    static func openedID(_ standing: ShellStep?) -> String? {
        switch standing {
        case .thread(let id): "thread:" + id
        case .person(let person): "person:" + person.id
        case .tag(let tag): "tag:" + String(describing: tag)
        case .people(let list): "people:" + list.id
        case .found(let at, let which): "found:" + at.id + "\u{1e}" + which.rawValue
        case .followedTags(let page): "followed:" + page.id
        case .shared(let page): "shared:" + page.id
        case .server(let page): "server:" + page.host + "\u{1e}" + page.tab.rawValue
        case .link, nil: nil
        }
    }

    /// What a timeline switched to does about the post it kept (#303): the selection it becomes
    /// with a keyboard or a pointer, and under a finger the mark, with nothing selected.
    static func restored(_ kept: String?, touch: Bool) -> (selected: String?, marked: String?) {
        touch ? (nil, kept) : (kept, nil)
    }

    /// The list under the walk: what is held, or the notice that says there is nothing.
    ///
    /// Written out once, because two places fall back to it — nothing walked to, and a
    /// conversation whose root this device no longer holds.
    ///
    /// **Rows win, and nothing else decides.** What is already here is read at once, including
    /// while a reload runs; and a reload running, a failed source, a search and nobody joined are
    /// all the notice where there are no rows — waiting rows would be a wait that never ended,
    /// and a pane-sized failure would hide that this timeline has nothing to show. A wait and a
    /// miss are the bottom toast, and the distinctions inside empty live on `EmptyNotice`.
    @ViewBuilder
    private var underneath: some View {
        // On Trends, Hashtags or Links in front is drawn in the stream's place (#320, F10); the
        // stream is Posts. Everywhere else the stream, exactly as it was.
        if let which = trends?.front.rising, let rising = people?.rising, let said = rising.said(which, in: session) {
            risingTab(said, in: rising)
        } else {
            stream
        }
    }

    /// Hashtags or Links on Trends (#320, F10): the one list woven of what the sources say,
    /// right under Trends' own tabs and marks as Posts is. Its mark and a pull ask the sources
    /// again, as `r` does.
    private func risingTab(_ said: RisingSaid, in rising: ShellRising) -> some View {
        let which = said.which
        return RisingPane(said: said, selectedID: $selectedID, onOpen: onOpenRising, jumpToTop: jumpToTop)
        // One list per tab, so a tab brought in front is drawn afresh at its own lamp.
        .id(which)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Pulled down, the sources are asked again as `r` asks them.
        .modifier(PullsToReload(offered: { ways.canReload }, reload: {}, settled: { await rising.again(which, in: session) }))
        // **A tab asks when it first comes in front**, once a run for each source: one stretch
        // of what is rising there, of that source and nobody else. A tab never in front has
        // asked nothing.
        .task(id: rising.opening(which, in: session)) { await rising.opened(which, in: session) }
        // And on Links, each source's document not yet had this run — again where one was let
        // go: whether it lists the posts sharing a link is its own word there (#379), and a
        // link's row opens them only where it says so.
        .task(id: which == .links ? people?.shared.unheard(said.answers.map(\.source)) : nil) {
            guard which == .links, let shared = people?.shared else { return }
            await shared.hear(said.answers.map(\.source), in: session)
        }
    }

    /// The stream, under the line that says which of its sources is not being read (#371) — over
    /// the posts and over the notice that there are none alike, which may be why. A search's
    /// results are not a timeline, and say nothing of the kind.
    private var stream: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !searching { UnreadSourcesHead(timeline: timeline, session: session) }
            streamBody
        }
    }

    @ViewBuilder
    private var streamBody: some View {
        // Bound once: the list, each row's rule under it and the jump to the top all read the
        // same rows, and each read of `items` used to ask the session for them again.
        let items = items
        let bands = foundBands
        // With no post found, what the sources found still stands, over the line that says so.
        if items.isEmpty, bands.isEmpty {
            // Its first page still being read from this device (#357, C2): rows to come, and
            // not a notice that there are none.
            if !searching, session.timelineLoading(latest: prefs.latestDate) {
                TimelineReading()
            } else {
                empty
            }
        } else {
            list(items, under: bands)
        }
    }

    private func list(_ items: [DummyItem], under bands: [SearchBands] = []) -> some View {
        // The rows shown: the drawing's, and those that left it easing out where they stood, at
        // or below the row being read (#357). Where motion is reduced, the drawing's alone.
        // Read, so the list is drawn again as the rows that left have eased out.
        _ = session.leavingEnded
        let shown = searching ? TimelineShown(rows: items, leaving: []) : session.timelineShown(
            latest: prefs.latestDate,
            anchor: ShellReadingMark.heldAtTop(top: session.scrolledTop, marked: session.readingMark.id, touch: touch),
            moving: !reduceMotion
        )
        let rows = shown.rows
        let last = rows.count - 1
        // Where the timeline in front is not whole, said at its place (#201). A search's results
        // are not a timeline, and say nothing of the kind.
        let gaps = searching ? [:] : session.gapMarks(in: items)
        // What is new to this drawing, which eases in where it stands (#357).
        let arrived = searching ? [] : session.timelineArrived(latest: prefs.latestDate)
        // Which drawing this is, for the place to be held across one that moved the rows above
        // it (#359): none for a search's results.
        let stamp = searching ? 0 : session.timelineDrawn(latest: prefs.latestDate).stamp
        let above = !searching && session.timelineReadsAbove(latest: prefs.latestDate)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // What the sources found beside posts (#319): short bands over the posts,
                    // which begin under them exactly as they always did.
                    if !bands.isEmpty {
                        SearchBandsView(
                            bands: bands, timeline: session.name(of: timeline), selectedID: $selectedID, onOpen: onOpenFound
                        )
                        if items.isEmpty {
                            Text(String(format: L10n.t("search.empty.title"), session.name(of: timeline)))
                                .shellFont(.meta)
                                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                                .padding(ShellSpace.pad)
                        }
                    }
                    // Rows above the head still to be read from this device (#359).
                    if above { TimelineReadingOn() }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        let isLast = index == last
                        // **One view a post, the rule under it included** (#303). The list
                        // reports which of its children are wholly on screen, and a rule that
                        // was a child of its own was reported whole while its post was cut.
                        VStack(alignment: .leading, spacing: 0) {
                        // Under a finger the row is lit by its own share of the reading mark,
                        // and drawn again only when that share changes (#303).
                        ReadRow(
                            lamp: session.readingMark.lamp(for: item.id), touch: touch,
                            selected: item.id == selectedID
                        ) { lit in
                        DummyItemRow(
                            item: item,
                            catalogues: session.emoji,
                            catalogueSettled: settledHosts.contains(item.source.host),
                            posts: session.posts,
                            acting: acting(item),
                            selected: lit,
                            top: decks.top(of: item.id, of: item.attachments.count),
                            lifted: decks.isLifted(item.id),
                            player: playback.rowPlayer(for: item, decks: decks),
                            // A press lights the row; a second press on the row it is already on
                            // opens the conversation, which is what `Return` does (#33). The rule
                            // is `DummyCommand.tapped` and is read by both lists. Under a
                            // finger the first press opens it (#303).
                            onSelect: {
                                switch DummyCommand.tapped(item.id, selected: selectedID, touch: touch) {
                                case .select: selectedID = item.id
                                case .open: onOpenThread(item.id)
                                }
                            },
                            // Lit and opened in one, for the reader who activates a row once —
                            // done by the root, in one turn, on the id this press carries.
                            onOpen: { onOpenThread(item.id) },
                            // The face and the name, as a press (#99).
                            onOpenPerson: onOpenPerson,
                            quoteLifted: decks.isQuoteLifted(of: item),
                            onToggleQuoteCover: { decks.toggleQuoteCover(of: item) },
                            onToggleCover: { _ = decks.toggleCover(item.id) },
                            onPlay: { onPlayRow(item) },
                            onView: { onViewRow(item) },
                            onViewAt: { at in
                                decks.show(item.id, at: at, of: item.attachments.count)
                                onViewRow(item)
                            },
                            onTurn: { onTurnRow(item) },
                            onEnded: { playback.stop() }
                        )
                        }
                        .id(item.id)
                        .modifier(EasesIn(arrived: arrived.contains(item.id)))
                        .modifier(EasesOut(leaving: shown.leaving.contains(item.id)))
                        // Reading toward the end asks for the next stretch (#87): a lazy row
                        // appears as it is scrolled or walked to, and nothing else asks.
                        .modifier(AsksForMore(
                            asks: Self.asksForMore(at: index, of: rows.count, searching: searching),
                            timeline: timeline, session: session, latest: prefs.latestDate
                        ))
                        // And a search's, its next pages from the file (#360).
                        .modifier(SearchReadsOn(asks: searching && index >= rows.count - Self.moreAhead, session: session))
                        .modifier(TimelineGapMarked(marks: gaps[item.id], session: session))
                        if !isLast {
                            ShellRule()
                        }
                        }
                    }
                    // Which sources have no more of what is rising to give (#288). A search's
                    // results are not a timeline, and end nowhere a source chose.
                    if !searching { TrendsEndFoot(timeline: timeline, session: session) }
                    // That the reader's marks stand by when they were published (#317).
                    if !searching, session.readsMarks(timeline) { MarksOrderFoot() }
                    // The page below being read from this device (#357).
                    if !searching, session.timelineLoading(latest: prefs.latestDate) { TimelineReadingOn() }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.never)
            // Pulled down from its top, the list is read again as the reload mark reads it
            // (#307) — the same press, by the same function — wherever that mark is offered.
            .modifier(PullsToReload(
                offered: { ReloadMark.pulls(canReload: ways.canReload, searching: searching) },
                reload: {
                    session.readingMark.pulled()
                    ways.onReload()
                },
                settled: {
                    await session.reload.settled(.timeline)
                    session.readingMark.pullSettled()
                }
            ))
            // The end of the list stops short of whatever floats over the page (#112).
            .clearsFloatingCorner()
            .modifier(KeepsTopRow(session: session, placing: searching ? nil : timeline, latest: prefs.latestDate))
            .modifier(HoldsPlace(session: session, proxy: proxy, touch: touch, first: items.first?.id, stamp: stamp))
            // The rows the mark may be among, said when they change and not on every pass (#303).
            // The drawn timeline's own ids, one array a drawing: compared in no time where they
            // did not change (#357).
            .onChange(of: searching ? items.map(\.id) : session.timelineIDs(latest: prefs.latestDate), initial: true) { _, ids in
                session.readingMark.list(Set(ids), of: timeline.id)
                listedNewest(ids, proxy: proxy)
            }
            .onAppear {
                // A tick later: a lazy stack just built has not laid out the row to scroll to.
                let mark = session.readingMark
                mark.returning = nil
                switch Self.landing(selected: selectedID, top: session.scrolledTop, touch: touch, marked: mark.id) {
                case .centred(let id): Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
                case .top(let id): Task { @MainActor in proxy.scrollTo(id, anchor: .top) }
                case nil: break
                }
                // Under a finger a selection is only where a press that opened something came
                // from; back on the list it is nothing, and the mark is the list's (#303).
                if touch, selectedID != nil { selectedID = nil }
            }
            .onChange(of: selectedID) { _, id in
                // Not under a finger, and not for the row a keyboard was just handed (#303).
                let mark = session.readingMark
                let handed = mark.handed
                mark.handed = nil
                guard let id, ShellReadingMark.centres(onSelecting: id, touch: touch, handed: handed) else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // Coming back to a timeline, the post it kept is centred again (#100) — "still
            // focused" and "still in view" are two halves of one sentence, and lighting a row
            // the reader would have to scroll to find is only the first half.
            //
            // **A tick later, and read through the binding rather than captured.** The stack has
            // just been rebuilt for this query and has not laid out the row yet, which is the
            // same wait `onAppear` takes; and by the time the tick comes round the pane's own
            // handler has lit the row, so the id asked for is the one that was restored rather
            // than the one this pass was built with.
            //
            // **Under a finger it is put at the top** (#303), where the mark is: the first row
            // wholly on screen is then the post the timeline was left at.
            .onChange(of: session.timelineID) { _, _ in
                Task { @MainActor in
                    let mark = session.readingMark
                    // A timeline never visited opens at its first post (#305): the scroll view
                    // otherwise keeps a row the two timelines share where it was.
                    // Asked of the session now, and not of `items`: this closure was made for
                    // the list that was in front, and its first post is that timeline's.
                    let first = searching ? nil : session.timelineItems(latest: prefs.latestDate).first?.id
                    let arrival = Self.arrival(
                        selected: selectedID, returning: mark.returning, touch: touch, first: first
                    )
                    mark.returning = nil
                    switch arrival {
                    case .centred(let id): proxy.scrollTo(id, anchor: .center)
                    case .top(let id): proxy.scrollTo(id, anchor: .top)
                    case nil: break
                    }
                }
            }
            .onChange(of: returns) { _, _ in
                Task { @MainActor in
                    let mark = session.readingMark
                    guard touch, let id = mark.returning else { return }
                    mark.returning = nil
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            // A reload lands newer rows above the selected one; it stays centred (#23, #29).
            // Under a finger nothing is selected to centre, and the list stays where it is read.
            .onChange(of: session.reload.landed) { _, _ in
                guard let selectedID, ShellReadingMark.centres(onSelecting: selectedID, touch: touch, handed: nil) else { return }
                proxy.scrollTo(selectedID, anchor: .center)
            }
            // A keyboard attached or taken away (#303): the marked row becomes the selected one,
            // or the selection goes and the mark is the list's again. Only with the list in
            // front — a post opened keeps the lamp the walk gave it — and the list does not move.
            //
            // **Only after the list was moved by hand.** A keyboard reported a moment after
            // launch was there all along, and a launch with a keyboard selects nothing.
            .onChange(of: touch) { _, now in
                let mark = session.readingMark
                defer { if now { mark.becameTouch() } }
                guard standing == nil else { return }
                let next = ShellReadingMark.handover(touchNow: now, marked: mark.id, used: mark.used, selected: selectedID)
                guard next != selectedID else { return }
                if !now { mark.handed = next }
                selectedID = next
            }
            .onChange(of: jumpToTop) { _, _ in jumpedToTop(first: items.first?.id, proxy: proxy) }
        }
    }

    /// `g`, or the tab pressed again: the list at its first row. **Where the rows above where
    /// it is read were let go** (#359, C22), the timeline's newest page is read afresh and the
    /// list put at its head once it is drawn — the newest, and not the highest row still held.
    private func jumpedToTop(first: String?, proxy: ScrollViewProxy) {
        let latest = prefs.latestDate
        guard standing == nil, search?.isOpen != true, session.timelineReadsAbove(latest: latest) else {
            guard let first else { return }
            withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(first, anchor: .top) }
            return
        }
        let query = timeline
        // Set before the read: its page may be drawn before the read is heard to end.
        toNewest = true
        Task {
            if await !session.readNewest(query) { toNewest = false }
        }
    }

    /// What the list draws changed: where a jump to the top read the newest page afresh, the
    /// list is put at its head as that page is drawn — not before, while it is being read.
    private func listedNewest(_ ids: [String], proxy: ScrollViewProxy) {
        guard toNewest, let first = ids.first, session.coverage[timeline]?.landed == true else { return }
        toNewest = false
        proxy.scrollTo(first, anchor: .top)
    }

    /// One row's share of #54's acts (#106).
    ///
    /// **Built here and handed down**, so the timeline, a conversation and somebody's page all
    /// draw one answer: the session holds what the sign-in bought and what the source has turned
    /// away since, and three panes working it out for themselves would be three derivations free
    /// to disagree about one post.
    func acting(_ item: DummyItem) -> ItemActing {
        acting(item, inside: nil)
    }

    /// The same, for a row drawn inside the conversation around `root` — where the answer mark
    /// opens the answer rather than the conversation (#108). Built by `RowActing`, which the
    /// notices page builds a post's row by too (#375).
    func acting(_ item: DummyItem, inside root: DummyItem?) -> ItemActing {
        RowActing(
            session: session, people: people, linkPreviews: linkPreviews, openThread: onOpenThread,
            openPeople: onOpenPeople
        )(item, inside: root)
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
    ///
    /// **On a narrow page it is the one timeline in front, by name** (#304): its rules and where
    /// it stands under the name, and every other timeline behind a press on it. See
    /// `TimelineNarrowHead`.
    private var header: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            if let trends {
                trendsHead(trends)
            } else if shellLayout == .narrow, !session.queries.isEmpty {
                TimelineNarrowHead(session: session, slide: slide) {
                    searchMark
                    reloadMark
                }
            } else {
            HStack(alignment: .center, spacing: ShellSpace.step) {
                if !session.queries.isEmpty { addPill.modifier(FingerTall()) }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: ShellSpace.tight) {
                            ForEach(session.queries) { query in
                                queryPill(query)
                                    .modifier(FingerTall())
                                    .id(query.id)
                            }
                        }
                        .padding(.vertical, ShellSpace.hair)
                        .modifier(FingerRoom())
                        // The names scroll sideways; the press on the top of the screen is the
                        // list's (#308).
                        .notToTop()
                    }
                    .scrollIndicators(.never)
                    .modifier(FingerRoom(given: false))
                    // The head is drawn afresh when a page of its own is left: the row is
                    // brought to the timeline in front as it appears, not only as that changes.
                    // A tick later: a row just built has not laid out the name to scroll to.
                    .onAppear {
                        guard let query = session.timelineID else { return }
                        Task { @MainActor in proxy.scrollTo(query.id) }
                    }
                    .onChange(of: session.timelineID) { _, query in
                        guard let query else { return }
                        withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(query.id) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if session.timelineID != nil {
                    Text(session.rule(of: timeline))
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .lineLimit(1)
                }
                searchMark
                reloadMark
            }
            }
            if trends == nil, session.timelinesUnreadable {
                Text(L10n.t("timeline.unreadable.line"))
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .shellHelp("timeline.unreadable", about: L10n.t("timeline.unreadable.line"))
            }
            if let latest = prefs.latestDate {
                latestMark(latest)
            }
        }
        .accessibilityElement(children: .contain)
        .modifier(ScrollsToNeighbour(session: session, steps: trends == nil))
    }

    /// Trends' head (DESIGN-trends, Pane): its tabs where it has more than one — no names of
    /// timelines, no `[+]`, no rule and no editor, since Trends is written by nobody — then the
    /// search, on Posts alone, and the reload.
    private func trendsHead(_ trends: TrendsHead) -> some View {
        HStack(alignment: .center, spacing: ShellSpace.step) {
            if PageFrame.stripDrawn(trends.tabs) {
                ShellTabs(trends.tabs, selected: trends.front, slide: slide, onSelect: trends.onTurn)
            }
            Spacer(minLength: 0)
            searchMark
            reloadMark
        }
    }

    /// Quiet word that newer posts are held back by the latest date in Preferences (#22), so a
    /// stream that stops short does not read as missing posts.
    private func latestMark(_ latest: LatestDate) -> some View {
        let day = latest.start().formatted(.dateTime.year().month().day().locale(L10n.locale()))
        return Label(String(format: L10n.t("timeline.latest"), day), systemImage: "calendar")
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.inkDim(colorScheme))
            .lineLimit(1)
            .accessibilityLabel(String(format: L10n.t("timeline.latest.label"), day))
    }

    /// One of the timeline's tabs: a `ShellTabPill` named by the reader, marked where one of its
    /// rules has lost its source, and pressed twice or held to be edited.
    private func queryPill(_ query: TimelineQuery) -> some View {
        let missing = session.hasMissingRule(query)
        return ShellTabPill(
            session.name(of: query),
            symbol: query.symbol,
            selected: query == session.timelineID,
            accessory: missing ? "circle.dashed" : nil,
            hint: missing ? L10n.t("timeline.pill.missing.hint") : nil
        ) {
            session.goToTimeline(query)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { session.editTimeline(query) }
        )
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in session.editTimeline(query) }
        )
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
            ShellIconButton("magnifyingglass", name: "shortcut.search", action: ways.onSearch)
        }
    }

    /// `r`'s mark. Stays the mark while a reload runs: a plate here would be a second
    /// loading animation, and blinking the control out from under the finger that pressed
    /// it is the thing decision 4 refuses. A press then still does nothing (`r` already).
    ///
    /// **While a reload the reader pressed for runs, the mark is Stop** (#307), and a press
    /// stops it exactly as `Escape` does — `ShellReload.stop`, the one function. A control in
    /// the place of the one just pressed, never a gap: it is Stop for as long as there is
    /// something to stop and the reload mark again the moment there is not. For a pointer as
    /// for a finger.
    ///
    /// **One button whose glyph and name change**, and not two that take turns: VoiceOver stays
    /// on it as it flips, and the header does not shift. **And a press on Stop within
    /// `ReloadMark.settle` of the press that began the reload is not heard**: a second press of
    /// a quick double would otherwise cancel what the first had just started.
    ///
    /// **On a tab of Trends that lists what is rising the mark is that tab's** (decision 17):
    /// Stop while its sources are asked, stopping them and nothing else — never the Posts'
    /// reload running out of sight under it.
    @ViewBuilder
    private var reloadMark: some View {
        let front = Self.askInFront(standing, rising: trends?.front.rising, of: people, in: session)
        let stop: (() -> Void)? = if let front { onStop(front) } else { streamStop }
        if let shown = ReloadMark.shown(canReload: ways.canReload, stoppable: stop != nil) {
            ShellIconButton(shown.symbol, name: shown.name) {
                switch ReloadMark.press(shown, at: Date(), pressedAt: reloadPressed) {
                case .begins:
                    reloadPressed = Date()
                    ways.onReload()
                case .stops: stop?()
                case .unheard: break
                }
            }
        }
    }

    /// `[+]`: a new timeline. A press, not a selected tab.
    private var addPill: some View {
        Button {
            session.newTimeline()
        } label: {
            Image(systemName: "plus")
                .shellFont(.meta, weight: .semibold)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .padding(.horizontal, ShellSpace.snug)
                .padding(.vertical, ShellSpace.tight)
                .background(
                    Capsule(style: .continuous)
                        .fill(ShellChrome.well(colorScheme))
                )
        }
        .buttonStyle(.plain)
        .shellNamed("timeline.new.title")
    }

    private var empty: some View {
        ShellNotice(EmptyNotice.timeline(
            searching: search?.isSearching == true,
            indexed: search?.isIndexed ?? false,
            query: timeline,
            notes: session.notes,
            written: session.written,
            sources: session.sources,
            // The folded text only where a rule reads it, as `timelineItems` asks: All and Trends
            // read none, and an empty one of them would otherwise fold every note held to say so.
            index: session.definition(of: timeline).readsText ? session.textIndex : TextIndex([]),
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

/// Which row is at the top of the stream, written down as the reader scrolls — into the session,
/// which outlives the pane, and past observation, so a scroll redraws nothing (#110).
///
/// **Watched, never steered.** A position binding also drives the scroll view it is bound to, and
/// on a list rebuilt by a swap of arrangement it was a second hand on the scroll beside the lamp's
/// own `scrollTo` — seen once on a running Mac, with the lamp fourteen rows down and off the
/// screen after the swap. This only reports, so what moves the list on appearing is
/// `TimelinePane.landing` and nothing else.
///
/// A modifier of its own rather than a closure in the list's chain, which is long enough already
/// for the compiler the CI builds with.
struct KeepsTopRow: ViewModifier {
    let session: ShellSession
    /// The timeline whose place the top row is (#359): nothing for a search's results.
    var placing: TimelineQuery?
    var latest: LatestDate?

    func body(content: Content) -> some View {
        content.onScrollTargetVisibilityChange(idType: String.self) { visible in
            session.scrolledTop = visible.first
            // The reader's place, which moves the timeline's window every twenty rows (C19).
            if let placing, let top = visible.first { session.scrolled(to: top, of: placing, latest: latest) }
            // The reading mark is worked out from the same report (#303), and from the rows
            // wholly on screen, said below. Kept whether or not a finger is all there is, so a
            // keyboard taken away finds the mark where the list is; nothing reads it till then.
            // Said with the timeline in front, so a report made of the one just left is not
            // taken for this one's (`ShellReadingMark.hears`).
            session.readingMark.visible(visible, of: session.currentTimeline.id)
            // What the rows on screen still owe goes first in its source's line (#293).
            // Only rows that owe: a screen of rows that owe nothing asks nothing of anybody.
            let owing = visible.filter(session.owingRows.contains)
            if !owing.isEmpty { Task { await session.refs.near(owing, in: session) } }
        }
        // Wholly on screen, to within what a row's own arithmetic can be out by
        // (`ShellReadingMark.wholeShare`) — never asked for as exactly all of it.
        .onScrollTargetVisibilityChange(idType: String.self, threshold: ShellReadingMark.wholeShare) { whole in
            session.readingMark.whole(whole, of: session.currentTimeline.id)
        }
        // The person moving the list, as against the list being moved: what a timeline
        // returned to was kept on gives way to what is on screen only for the first (#303).
        .onScrollPhaseChange { _, phase in
            if ShellReadingMark.byHand(phase) { session.readingMark.scrolledByHand() }
        }
    }
}

/// The row the reader is reading stays where it is when the store renews the list under them
/// (#175). A landing nobody pressed for puts newer rows above it; the row at the top before is
/// put back at the top, rather than the stream sliding down under the reader's eyes.
///
/// **The top row, not the lamp.** `r` centres the lamp as it ends, because the reader asked and
/// is looking for what came; a renewal the reader did not ask for leaves the page as it was read.
/// A modifier of its own for `KeepsTopRow`'s reason.
///
/// **Under a finger, the post being read** (#303): the row at the top may be one cut by the
/// top of the list, and putting that back whole would move the lamp up a post at every landing.
struct HoldsPlace: ViewModifier {
    let session: ShellSession
    let proxy: ScrollViewProxy
    var touch = false
    /// The newest post of the list in front: what a pull's landing puts at the top (#307).
    var first: String?
    /// The drawing of the timeline in front (`DrawnTimeline.stamp`), none for a search's.
    var stamp = 0

    /// What moves the list under the reader: what is held, or the drawing alone.
    struct Moved: Equatable {
        let notes: Int
        let stamp: Int
    }

    func body(content: Content) -> some View {
        content.onChange(of: Moved(notes: session.notesRevision, stamp: stamp)) { was, now in
            let held = ShellReadingMark.heldAtTop(
                top: session.scrolledTop, marked: session.readingMark.id, touch: touch
            )
            guard was.notes != now.notes else {
                // **The drawing alone moved** (#359): an edge let go, a page read above. Held
                // only where the rows above the one read are not what they were, so a stretch
                // let go below moves nothing.
                if let top = held, session.timelineDrawnMovedAbove(top) { proxy.scrollTo(top, anchor: .top) }
                return
            }
            // **What a pull brought is shown** — the list was at rest at its top, and holding
            // the post that was first would leave the new ones out of sight above it, a pull
            // that looked as though it did nothing. Any other landing holds the place.
            if session.readingMark.landing() {
                if let first { proxy.scrollTo(first, anchor: .top) }
                return
            }
            guard let top = held else { return }
            proxy.scrollTo(top, anchor: .top)
        }
    }
}

/// A name in the row of timelines made a finger tall to press, on an iPhone or iPad, **without
/// being drawn any taller** (#304): the press reaches above and below the pill, and the row is
/// as high as it was. Nothing on a Mac, where a pointer is exact.
///
/// Upright only. `ShellTouchFloor` reaches every way, and the names stand a few points apart:
/// sideways, one name's press would lie over the next.
struct FingerTall: ViewModifier {
    /// What the reach is worked out from: 11 points each way. **Not more, and measured.** The
    /// row that scrolls the names is given this room and takes it back (`FingerRoom`), and with
    /// 13 the names stood half a point lower on an iPad at the smallest text — the row had
    /// become taller than the marks beside it. So a name at the default text and above is a
    /// finger tall with its reach, and at the smallest text it is three points short of one.
    static let drawn: CGFloat = 22
    static var reach: CGFloat { ShellTouchFloor.spill(drawn: drawn) }

    /// Whether the reach is given here: on an iPhone or iPad. A test says so for itself, to
    /// measure on a Mac what the reach does to the row's height — which is nothing.
    static var onThisDevice: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    var applies = FingerTall.onThisDevice

    @ViewBuilder
    func body(content: Content) -> some View {
        if applies {
            // A shape past the pill's own upper and lower edges. Nothing is padded: what is
            // drawn, and where, is what it was.
            content.contentShape(Reached(reach: Self.reach))
        } else {
            content
        }
    }
}

/// A rectangle reaching past its own top and bottom, and no wider than it is.
struct Reached: Shape {
    let reach: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -reach))
    }
}

/// Room for that reach inside the row that scrolls the names, which would otherwise cut a press
/// off at its own edge: given to what scrolls, and taken back from the row, so nothing moves.
struct FingerRoom: ViewModifier {
    var given = true
    var applies = FingerTall.onThisDevice

    @ViewBuilder
    func body(content: Content) -> some View {
        if applies {
            content.padding(.vertical, given ? FingerTall.reach : -FingerTall.reach)
        } else {
            content
        }
    }
}

/// The sideways swipe on the timelines' page, on an iPhone or iPad (#305). Nothing on a Mac.
/// A modifier of its own for `KeepsTopRow`'s reason.
struct SwipesSideways: ViewModifier {
    let session: ShellSession
    let slide: PageSlide
    let touch: Bool
    let page: TimelineSwipe.Page
    /// The page opened, by name, where one is.
    let opened: String?
    let searching: Bool
    let back: () -> Void
    /// Trends' tabs, where the pane is Trends: beside on its own page is the tab beside, and
    /// there is no leaving it from the first — Trends is a place, not a page opened over one.
    var trends: TrendsHead?

    @Environment(\.shellCovered) private var covered

    func body(content: Content) -> some View {
        let means = TimelineSwipe.means(
            touch: touch, page: page, searching: searching,
            listShown: session.timelineListShown, editing: session.editing != nil, covered: covered
        )
        let tabs = trends?.tabs ?? []
        let place = trends.map { (index: $0.tabs.firstIndex(of: $0.front), count: $0.tabs.count) }
            ?? session.timelinePosition
        let ways = means.map { TimelineSwipe.ways($0, index: place.index, count: place.count) }
        content.modifier(PageSwipes(
            slide: slide, enabled: means != nil, key: means == .back ? "back" : "beside",
            hasNext: ways?.next ?? false, hasPrevious: ways?.previous ?? false,
            inFront: { means == .back ? opened : trends.map(\.front.id) ?? session.currentTimeline.id },
            step: { step in
                guard means == .back else {
                    guard let trends else { return session.stepTimeline(by: step) }
                    guard let to = TimelineSwipe.target(from: place.index, count: tabs.count, step: step) else { return false }
                    trends.onTurn(tabs[to])
                    return true
                }
                guard step == -1 else { return false }
                back()
                return true
            }
        ))
    }
}

/// Keeps a list slid sideways inside its own pane, on an iPhone or iPad under a finger: not
/// over the rail beside it on a wide page.
///
/// **One shape that either holds or does not**, and not a clip put on and taken off: a modifier
/// that came and went with a keyboard would be another list each time, drawn afresh. And where
/// it does not hold it cuts nothing — a list shows a few points past its own foot, and a clip
/// at its edges changed that, measured on an iPad's picture.
struct HoldsSlide: ViewModifier {
    let holds: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content.clipShape(SlideBounds(holds: holds))
        #else
        content
        #endif
    }
}

/// The pane's own sides where it holds, with nothing cut above or below; everything where not.
struct SlideBounds: Shape {
    let holds: Bool
    static let beyond: CGFloat = 10_000

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: holds ? 0 : -Self.beyond, dy: -Self.beyond))
    }
}

/// The same for a reader who makes no gesture (#305): VoiceOver's scroll on the head of the
/// timelines goes to the one beside, and says which it is and where it stands. The list of them
/// all, behind the name, reaches any.
struct ScrollsToNeighbour: ViewModifier {
    let session: ShellSession
    /// Whether the scroll goes to a timeline: not over Trends' head, whose tabs are no timelines.
    var steps = true

    /// Which way a scroll toward `edge` goes: on for the trailing edge, back for the leading.
    /// A three-finger swipe toward the leading edge scrolls toward the trailing one, so it is
    /// the next timeline — the way the finger's own swipe goes.
    static func step(toward edge: Edge) -> Int {
        switch edge {
        case .trailing: 1
        case .leading: -1
        case .top, .bottom: 0
        }
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        content.accessibilityScrollAction { edge in
            let step = Self.step(toward: edge)
            guard steps, step != 0 else { return }
            // At an end nothing moves, and what is said is where the reader still is.
            session.stepTimeline(by: step)
            let place = session.timelinePosition
            UIAccessibility.post(notification: .pageScrolled, argument: TimelineSwipe.announcement(
                name: session.name(of: session.currentTimeline), position: place.index, count: place.count
            ))
        }
        #else
        content
        #endif
    }
}

/// What the reload mark is, and whether the list can be pulled to do the same (#307).
enum ReloadMark: Equatable, Sendable {
    case reload
    case stop

    /// Nothing where a reload is not offered; Stop while one the reader pressed for runs; the
    /// reload mark otherwise.
    static func shown(canReload: Bool, stoppable: Bool) -> ReloadMark? {
        guard canReload else { return nil }
        return stoppable ? .stop : .reload
    }

    var symbol: String {
        switch self {
        case .reload: "arrow.clockwise"
        case .stop: "stop.circle"
        }
    }

    var name: String {
        switch self {
        case .reload: "shortcut.reload"
        case .stop: "timeline.reload.stop"
        }
    }

    /// How long after the press that began a reload a press on Stop is not heard.
    static let settle: TimeInterval = 0.4

    /// Whether a press on Stop at `now` stops: not within `settle` of the press on this mark
    /// that began the reload. One begun any other way — a key, a pull — is stopped at once.
    static func stops(at now: Date, pressedAt: Date?) -> Bool {
        guard let pressedAt else { return true }
        return now.timeIntervalSince(pressedAt) >= settle
    }

    /// What a press on the mark does, shown as `shown`.
    enum Press: Equatable, Sendable {
        /// It begins a reload: whoever draws the mark writes down when, and asks.
        case begins
        /// It stops the one running.
        case stops
        /// It is Stop pressed within `settle` of the press that began the reload: not heard.
        case unheard
    }

    /// What a press at `now` on the mark shown as `shown` does, the mark last pressed to begin
    /// a reload at `pressedAt`. **The one place this is decided**, for every mark there is: a
    /// timeline's, the notices', and an opened page's.
    static func press(_ shown: ReloadMark, at now: Date, pressedAt: Date?) -> Press {
        switch shown {
        case .reload: .begins
        case .stop: stops(at: now, pressedAt: pressedAt) ? .stops : .unheard
        }
    }

    /// Whether pulling the list down reads it again: exactly where the mark is offered, and
    /// never over a search's results, which are not a timeline to read again.
    static func pulls(canReload: Bool, searching: Bool) -> Bool {
        canReload && !searching
    }
}

/// The pull itself, on an iPhone or iPad. Nothing on a Mac, which has no such gesture.
///
/// **Always there, and asked at the pull whether it does anything.** Put on and taken off as a
/// reload came and went from being offered — under a picture, the keys' guide, a search — it
/// made the list another list each time, drawn afresh from its start. So it is one modifier
/// for the list's whole life, and where no reload is offered a pull's spinner comes and goes
/// at once. Under anything drawn over the list it cannot be pulled at all.
///
/// A pull is the press: it calls what the mark and `r` call, which already takes a second press
/// of the same read and does nothing. The spinner then stays for as long as `settled` waits,
/// and goes when it returns — or when the list does, which cancels the wait.
struct PullsToReload: ViewModifier {
    let offered: () -> Bool
    let reload: () -> Void
    let settled: () async -> Void
    /// Whether the pull is put on at all: on an iPhone or iPad. A test says so for itself.
    var applies = FingerTall.onThisDevice

    @ViewBuilder
    func body(content: Content) -> some View {
        if applies {
            content.refreshable { await Self.pull(offered: offered(), reload: reload, settled: settled) }
        } else {
            content
        }
    }

    /// One pull: nothing where a reload is not offered; else the press, and then the wait.
    /// `sleep` is `Task.sleep` but for a test, which turns it by hand.
    static func pull(
        offered: Bool, reload: () -> Void, settled: () async -> Void,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async {
        guard offered else { return }
        reload()
        // The press starts its read on the next turn; the wait must not look before it has.
        await Task.yield()
        try? await sleep(Self.lead)
        await settled()
    }

    /// How long a pull gives its press to have begun its read, before it waits for the read.
    static let lead: Duration = .milliseconds(50)
}

/// The one asker for the menus of the rows a pane lists: it hands every row under it the way to
/// put its menu's question (`shellRowAsk`) and puts that question itself, once, through
/// `ShellMoreAsks`.
///
/// **On the pane and not on each row.** A row is drawn and let go as it scrolls, so a question
/// held by a row would go with it; and a list of hundreds of rows would carry hundreds of
/// presenters for a question one of them asks. What was chosen is the session's (`rowAsk`), which
/// is also how this question and the key's own are never both up.
struct RowAsks: ViewModifier {
    let session: ShellSession

    func body(content: Content) -> some View {
        content
            .environment(\.shellRowAsk, RowAsk(put: { session.putRowAsk($0) }))
            .modifier(ShellMoreAsks(asked: asked))
    }

    private var asked: Binding<ShellMoreAsk?> {
        Binding(get: { session.rowAsk }, set: { session.putRowAsk($0) })
    }
}

/// What somebody's page asks beside its own reads, each once its time comes: what only staff see
/// of them, where the reader answers for their server (#382), and who of the people the reader
/// follows also follow them, once the source has said how the reader stands — and again each
/// time it is read again (#377). **A modifier of its own**, so the page's chain of modifiers does
/// not grow by one a feature.
struct PersonPageAsks: ViewModifier {
    let person: DummyPerson
    let people: ShellPersonPages?
    let session: ShellSession

    func body(content: Content) -> some View {
        content
            .task(id: people?.tending.people.staffOpening(of: people?.said(of: person, in: session)?.person, in: session)) {
                await people?.tending.people.staffOpened(of: people?.said(of: person, in: session)?.person, in: session)
            }
            .task(id: people.flatMap { $0.acts.familiarOpening(person, said: $0.said(of: person, in: session), in: session) }) {
                guard let people else { return }
                await people.acts.familiarOpened(person, said: people.said(of: person, in: session), in: session)
            }
            // **And which languages its host knows**, once the reader follows them there (#378).
            .task(id: people.flatMap { $0.acts.languagesOpening(person, said: $0.said(of: person, in: session), in: session) }) {
                guard let people else { return }
                await people.acts.languagesOpened(person, said: people.said(of: person, in: session), in: session)
            }
    }
}
