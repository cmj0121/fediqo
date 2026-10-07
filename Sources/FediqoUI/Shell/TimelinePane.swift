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

/// The timeline place: named queries, a brief rule, then the stream or a thread.
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
    @Environment(\.shellLayout) private var shellLayout
    /// Counted up each time a timeline returned to has a post to put back at the top (#303).
    /// The list answers the count and not the switch: a list drawn afresh — a return through a
    /// timeline with no posts — is not there to hear the switch, and is there for this.
    @State private var returns = 0
    /// How far a sideways swipe has slid what is under the head (#305). Read by `Slid`, and by
    /// the head's dots, which lean with it.
    private var slide: PageSlide { session.slide("timeline") }
    /// When the reload mark was last pressed to begin a reload (#307). See `reloadMark`.
    @State private var reloadPressed: Date?

    private var timeline: TimelineQuery { session.currentTimeline }

    /// A search is open over this timeline. `search` is never nil in the product — the root holds
    /// one for the life of the window — so whether one is open is this, and not `search == nil`.
    private var searching: Bool { search?.isOpen == true }

    private var items: [DummyItem] {
        search.flatMap { session.searched($0, latest: prefs.latestDate) }
            ?? session.timelineItems(latest: prefs.latestDate)
    }

    /// Running first; a live note replaces a leftover line; otherwise the reload
    /// line. Loading and a miss do not auto-dismiss: a 2s flash is a fact the
    /// reader has to act on, gone.
    private var banner: TimelineToast? {
        TimelineToast.shown(
            running: session.reload.running,
            waiting: session.reload.onlyWaiting,
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
                // The head stays where it is and shows the change: a swipe begins under it.
                .headOfPage()
                .modifier(ProbedPane(part: .head))

            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(height: ShellSpace.hair)

            Group {
            // **Whatever step the reader is standing on** (#122). A face pressed inside a
            // conversation opens over it, and a row pressed on that page opens over the page;
            // which is in front is `ShellWalk` and is not decided again here. **No `default:`.**
            switch standing {
            case .person(let person):
                PersonPane(
                    person: person,
                    items: session.heldPosts(of: person),
                    catalogues: session.emoji,
                    catalogueSettled: settledHosts.contains(person.host),
                    posts: session.posts,
                    selectedID: $selectedID,
                    // A row here opens the conversation it belongs to (#122), so the answer mark
                    // does what it does on the timeline: it opens that conversation first.
                    acting: acting,
                    decks: $decks,
                    playback: playback,
                    onPlayRow: onPlayRow,
                    onViewRow: onViewRow,
                    onTurnRow: onTurnRow,
                    onOpenThread: onOpenThread,
                    jumpToTop: jumpToTop,
                    onBack: onBack
                )
                // One pane per person, so opening a second face from inside one draws afresh.
                .id(person.id)
            case .tag(let tag):
                TagPane(
                    tag: tag,
                    items: session.heldPosts(under: tag, latest: prefs.latestDate),
                    // What the ask says only where it is this tag's: another tag's, or one left
                    // behind, is not this page's to say.
                    asking: session.reload.tagAsk?.tag == tag ? session.reload.tagAsking : [],
                    failed: session.reload.tagAsk?.tag == tag ? session.reload.tagFailed : [],
                    reach: session.reload.tagAsk?.tag == tag ? session.reload.tagAsk?.reach.sentence : nil,
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
                    // Asked again of the timeline in front, as the press asked it.
                    onRetry: {
                        let timeline = session.currentTimeline
                        Task { await session.reload.tag(tag, timeline: timeline, in: session) }
                    },
                    jumpToTop: jumpToTop,
                    onBack: onBack
                )
                .id(HeldUnderTag.folded(tag))
            case .thread(let id):
                // A root this device no longer holds draws the stream instead, which is the same
                // answer the pane gave when it looked the root up among the timeline's own rows.
                if let opened = session.held(id) {
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
                        onBack: onBack
                    )
                    // Pulled down, the conversation is read again as `r` reads it there (#307):
                    // the pull reaches the pane's own list from here.
                    .modifier(PullsToReload(
                        offered: { ReloadMark.pulls(canReload: ways.canReload, searching: false) },
                        reload: ways.onReload, settled: { await session.reload.settled(.thread) }
                    ))
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
        // goes to the one beside; on a post, a person or a tag opened over it, it goes back.
        // What follows the finger stays inside the pane: not over the rail on a wide page.
        .modifier(SwipesSideways(
            session: session, slide: slide, touch: touch, page: Self.page(standing),
            opened: Self.openedID(standing), searching: searching, back: onBack
        ))
        .modifier(HoldsSlide(holds: touch))
        // One asker for the `…` of every row under this pane — the timeline, a conversation, a
        // person's page, a tag's.
        .modifier(RowAsks(session: session))
        .overlay(alignment: .bottom) {
            if let banner {
                TimelineToastBanner(toast: banner, work: session.work, reading: session.reload.reading)
                    .padding(.bottom, ShellSpace.pad)
                    // At the foot of the page, beside the compose button where it floats and
                    // never under it or over it (#302).
                    .standsBesideFloatingCorner(by: ShellSpace.pad)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: banner)
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
            // Another list, so the row the last one had at the top means nothing here.
            session.scrolledTop = nil
            // A tag's page stays over the switch, and its lamp and the place under it are
            // `FediqoRootView.timelineSwitched`'s (#197): only the search's parked post is filed here.
            let onTag = if case .tag = standing { true } else { false }
            // And the rows the mark was among are not this list's (#303).
            let mark = session.readingMark
            let wasReading = mark.left()
            mark.forget(for: arrived?.id ?? TimelineQuery.all.id)
            if !searching {
                if !onTag {
                    // Under a finger the place kept is the post being read, and the one given
                    // back is marked and put at the top; nothing is selected.
                    let kept = session.timelinePlaces.switched(
                        from: left, to: arrived, standingOn: touch ? wasReading : selectedID, among: items.map(\.id)
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
    static func page(_ standing: ShellStep?) -> TimelineSwipe.Page {
        switch standing {
        case .person, .tag, .thread: .opened
        case .link: .link
        case nil: .timeline
        }
    }

    /// A name for the page opened, so a swipe begun on one is not acted on over another.
    static func openedID(_ standing: ShellStep?) -> String? {
        switch standing {
        case .thread(let id): "thread:" + id
        case .person(let person): "person:" + person.id
        case .tag(let tag): "tag:" + String(describing: tag)
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
        // Bound once: the list, each row's rule under it and the jump to the top all read the
        // same rows, and each read of `items` used to ask the session for them again.
        let items = items
        if items.isEmpty {
            empty
        } else {
            list(items)
        }
    }

    private func list(_ items: [DummyItem]) -> some View {
        let last = items.count - 1
        // Where the timeline in front is not whole, said at its place (#201). A search's results
        // are not a timeline, and say nothing of the kind.
        let gaps = searching ? [:] : session.gapMarks(in: items)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
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
                        // Reading toward the end asks for the next stretch (#87): a lazy row
                        // appears as it is scrolled or walked to, and nothing else asks.
                        .modifier(AsksForMore(
                            asks: Self.asksForMore(at: index, of: items.count, searching: searching),
                            timeline: timeline, session: session
                        ))
                        .modifier(TimelineGapMarked(marks: gaps[item.id], session: session))
                        if !isLast {
                            Rectangle()
                                .fill(ShellChrome.hairline(colorScheme))
                                .frame(height: ShellSpace.hair)
                        }
                        }
                    }
                    // Which sources have no more of what is rising to give (#288). A search's
                    // results are not a timeline, and end nowhere a source chose.
                    if !searching { TrendsEndFoot(timeline: timeline, session: session) }
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
            .modifier(KeepsTopRow(session: session))
            .modifier(HoldsPlace(session: session, proxy: proxy, touch: touch, first: items.first?.id))
            // The rows the mark may be among, said when they change and not on every pass (#303).
            .onChange(of: items.map(\.id), initial: true) { _, ids in
                session.readingMark.list(Set(ids), of: timeline.id)
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
            .onChange(of: jumpToTop) { _, _ in
                guard let first = items.first else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
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
    /// opens the answer rather than the conversation (#108).
    func acting(_ item: DummyItem, inside root: DummyItem?) -> ItemActing {
        var acting = session.acting(on: item)
        acting.perform = { act in
            switch act {
            case .boost, .favourite, .bookmark:
                Task { await session.toggle(act, on: item) }
            case .answer:
                if let root {
                    session.openAnswer(to: item, in: root)
                } else {
                    onOpenThread(item.id)
                }
            // No mark performs this: taking back is an item of the row's `…` (`withdraw`, below).
            case .withdraw:
                break
            }
        }
        // What `y` does (#284), and it says so itself: one act, one outcome, whichever asked.
        acting.keep = { Task { await session.toggleKept(item) } }
        acting.ask = { _ in session.askToBookmark(item) }
        // Taking back is an item of the row's `…` (#109), built only where the post offers it:
        // the question the key `d` asks, about the copy that goes, and a yes that refuses what
        // that asking refuses.
        if acting.acts.offers(.withdraw) {
            acting.withdraw = ItemActing.Withdraw(
                asks: { ShellQuestion.withdraw(session.actingCopy(of: item, for: .withdraw) ?? item) },
                yes: { session.withdrawAsked(item) }
            )
        }
        return acting
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
            if shellLayout == .narrow, !session.queries.isEmpty {
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
            if session.timelinesUnreadable {
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
        .modifier(ScrollsToNeighbour(session: session))
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
    @ViewBuilder
    private var reloadMark: some View {
        if let shown = ReloadMark.shown(canReload: ways.canReload, stoppable: session.reload.stoppable) {
            ShellIconButton(shown.symbol, name: shown.name) {
                switch shown {
                case .reload:
                    reloadPressed = Date()
                    ways.onReload()
                case .stop:
                    guard ReloadMark.stops(at: Date(), pressedAt: reloadPressed) else { return }
                    session.reload.stop()
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

    func body(content: Content) -> some View {
        content.onScrollTargetVisibilityChange(idType: String.self) { visible in
            session.scrolledTop = visible.first
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

    func body(content: Content) -> some View {
        content.onChange(of: session.notesRevision) { _, _ in
            // **What a pull brought is shown** — the list was at rest at its top, and holding
            // the post that was first would leave the new ones out of sight above it, a pull
            // that looked as though it did nothing. Any other landing holds the place.
            if session.readingMark.landing() {
                if let first { proxy.scrollTo(first, anchor: .top) }
                return
            }
            let held = ShellReadingMark.heldAtTop(
                top: session.scrolledTop, marked: session.readingMark.id, touch: touch
            )
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

    @Environment(\.shellCovered) private var covered

    func body(content: Content) -> some View {
        let means = TimelineSwipe.means(
            touch: touch, page: page, searching: searching,
            listShown: session.timelineListShown, editing: session.editing != nil, covered: covered
        )
        let place = session.timelinePosition
        let ways = means.map { TimelineSwipe.ways($0, index: place.index, count: place.count) }
        content.modifier(PageSwipes(
            slide: slide, enabled: means != nil, key: means == .back ? "back" : "beside",
            hasNext: ways?.next ?? false, hasPrevious: ways?.previous ?? false,
            inFront: { means == .back ? opened : session.currentTimeline.id },
            step: { step in
                guard means == .back else { return session.stepTimeline(by: step) }
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
            guard step != 0 else { return }
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
    static func pull(offered: Bool, reload: () -> Void, settled: () async -> Void) async {
        guard offered else { return }
        reload()
        // The press starts its read on the next turn; the wait must not look before it has.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        await settled()
    }
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
