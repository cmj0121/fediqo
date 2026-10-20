import FediqoCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Places on the left, the current page on the right, compose over it.
public struct FediqoRootView: View {
    @State private var session: ShellSession
    @State private var place: ShellPlace = .launch
    /// The launch's one decision about where to land (#101), and the record that it has been
    /// made. Held here because `place` is held here, and asked in the `.task` below — the first
    /// moment the store has said whether anything is joined.
    @State private var launch = ShellLaunch()
    /// Each stream place's walk and lamp — the timeline's, and Trends' (DESIGN-trends, Root).
    /// `walk` and `selectedItemID` are the side of the stream the session follows.
    @State private var sides = StreamSides()
    /// Which tab of Trends is in front, and each tab's lamp: for the run, starting on Posts
    /// (decision 20).
    @State private var trendsFront = TrendsFront()
    /// The lamp of the stream in front: the row the keys stand on.
    private var selectedItemID: String? {
        get { sides[session.stream].lamp }
        nonmutating set { sides[session.stream].lamp = newValue }
    }
    /// How far the reader has walked out from the stream in front, and by which steps (#122).
    ///
    /// **One stack for conversations and people both.** They were two pieces of state — a stack
    /// of thread ids, and one person with the lamp's place kept beside them — which is what made
    /// the order between them something `DummyLayer` had to settle once and for all, and what
    /// made a row on somebody's page a thing that lit and went no further. `ShellWalk` says why
    /// one stack is the honest shape. Held here because leaving it is `Escape` and `q`, and the
    /// keys are read here. **One a stream place**: a page opened from Trends' posts is Trends'
    /// step, and the timeline under it is where it was.
    private var walk: ShellWalk {
        get { sides[session.stream].walk }
        nonmutating set { sides[session.stream].walk = newValue }
    }
    /// What sources say of the people whose pages were opened this run (#310). Beside the walk,
    /// because the keys that walk a page's rows and read it again are read here.
    @State private var people = ShellPersonPages()
    /// The line the lamp is on in Notices (#323), and under a finger the line being read
    /// there: that page's own, so walking its lines leaves the timeline's lamp where it was.
    @State private var noticeSelectedID: String?
    @State private var noticeMark = ShellReadingMark()
    @State private var noticeJump = 0
    /// The walk a press on another place began — a notice's line (#323), the reader's own page
    /// from Account (#310) — until its last step is left. See `PlaceErrand`.
    @State private var errand: PlaceErrand?
    /// The line whose post could not be opened: older than this device keeps.
    @State private var noticeTooOld: String?
    /// What `/` opened (#32). Its results stand in for the stream while it is open.
    @State private var search = ShellSearch()
    @State private var jumpToTop = 0
    @State private var composing = false
    @State private var showingShortcuts = false
    @State private var shortcutTab: DummyShortcutGroup = .move
    /// The launch overlay. Starts true; `LandingView` clears it after the jet, and
    /// `playsLanding` is false from the first frame when reduce motion is on.
    @State private var showingLanding = true
    /// Bumped so a press of `r` remounts the overlay from rest rather than showing a
    /// view that has already jetted.
    @State private var landingTick = 0
    #if os(macOS)
    /// Owns the sign-in window so that it outlives the body that opened it — a window held only
    /// by a view's local is a window that closes the next time SwiftUI rebuilds.
    @State private var signInWindows = ForumSignInWindows()
    #endif
    @State private var railExpanded = false
    /// Which card each row's deck is turned to, and which rows the reader has uncovered. Held
    /// here rather than in the list, because a list is replaced by every refresh and `m` and `s`
    /// are read here.
    @State private var decks = ShellDecks()
    /// Which post the reader has opened over the app, where there is one.
    ///
    /// **The post, not the picture.** Which card is on top lives in `decks`, so a viewer holding
    /// the post reads the same answer the row does and `m` turns both at once. A viewer holding
    /// its own index would be a second copy of the deck's position, drifting from the row behind
    /// it from the first press of `m`.
    @State private var viewing: String?
    /// What is playing, and the one `AVPlayer` in the app. See `ShellPlayback`.
    @State private var playback = ShellPlayback()
    @State private var prefs = DummyPrefs()
    /// The page the reader opened out of a post's words, where there is one (#34). Held here
    /// beside `viewing` and for its reason: a layer over the shell belongs to the shell, and a
    /// pane that owned it would be a pane the next surface to draw a post's words could not
    /// reach.
    @State private var linkReader = ShellReader()
    /// Where a hashtag pressed in a post's words goes (#124): this view's walk, handed down as the
    /// link reader is.
    @State private var tags = ShellTags()
    /// Where somebody mentioned in a post's words, pressed, goes (#310): handed down as the tags are.
    @State private var mentions = ShellMentions()
    /// Where a press on a quote goes (#214): this view's walk, handed down as the tags are.
    @State private var quotes = ShellQuotes()
    /// Up once at launch when the index on disk was written by a newer build and this run left it
    /// alone: without it the reader sees an empty app and nothing to say why.
    @State private var storeIsNewer: Bool
    /// Told when the reader dismisses that notice, so a window opened later does not raise it
    /// again: each window is its own root view with its own state.
    private let storeNoticeSeen: (@MainActor () -> Void)?
    /// Up once at launch when the store did not simply open (#295): it could not be opened, it
    /// was damaged and put aside, or a read back left two. Without it the reader sees an empty
    /// app, or a run that saves nothing, and nothing to say why.
    @State private var storeTrouble: StoreTrouble?
    /// Told what the reader answered to that notice — that they were told, or which of two
    /// stores they chose — so what waits on their answer can go ahead.
    private let storeTroubleAnswered: (@MainActor (StoreTroubleAnswer) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The same scale every `RemoteImage` on this screen reads, so a wake asks for the keys the
    /// screen actually holds rather than for a second decode of each of them.
    @Environment(\.displayScale) private var displayScale

    /// Where the next wake starts scanning. Counts up and is taken modulo what is eligible, so
    /// the handful a wake asks for is a different handful each time — see
    /// `stranded(among:scale:from:)` for what goes wrong when it is not.
    @State private var wakeCursor = 0

    /// Where this launch is put with nothing pressed, where it is put anywhere. See `ShellStaged`.
    private let staged: ShellStaged?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    public init(
        // **A bare `URLSessionClient`, and it must stay one**: `SourceReach.small()` holds an
        // ask known to be small to its ceiling *as it transfers* only where the plain client
        // is this type; wrapped in anything else, the ceiling is applied after the body came.
        http: any HTTPClient = URLSessionClient(),
        store: ItemStore = ItemStore(),
        forums: ForumSessions = ForumSessions(),
        mastodon: MastodonSessions = MastodonSessions(),
        persist: (@MainActor () async -> Bool)? = nil,
        persistUnsent: (@MainActor () async -> Bool)? = nil,
        savesLanded: (@Sendable () async -> AsyncStream<Void>)? = nil,
        measureStore: (@Sendable () async -> Int)? = nil,
        compactStore: (@Sendable () async throws -> Void)? = nil,
        letWordsGo: (@Sendable () async throws -> Void)? = nil,
        weighStore: (@Sendable () async -> Int)? = nil,
        readPage: (@Sendable (PageQuery, PageAsk, Int) async throws -> Page)? = nil,
        readEarly: (@Sendable (PageQuery, Int) async throws -> Page?)? = nil,
        readSearch: (@Sendable (PageQuery, NoteSearch, PageAsk, Int) async throws -> Page?)? = nil,
        afterFirstPage: (@Sendable () async -> Void)? = nil,
        limits: (any LimitAccountStore)? = nil,
        storeIsNewer: Bool = false,
        storeNoticeSeen: (@MainActor () -> Void)? = nil,
        storeTrouble: StoreTrouble? = nil,
        storeTroubleAnswered: (@MainActor (StoreTroubleAnswer) -> Void)? = nil,
        carrier: (any StoreCarrier)? = nil,
        storeWritable: Bool = true,
        lists: ListFiles? = nil,
        nearby: (any NearbyLink)? = nil,
        deviceName: String = "",
        staged: ShellStaged? = nil
    ) {
        let session = ShellSession(
            http: http, store: store, forums: forums, mastodon: mastodon,
            // A launch made for a picture writes no timeline down: one it makes for itself
            // (`ShellStaged.Step.empty`) is gone with the launch.
            timelines: staged == nil ? WrittenTimelineStore(defaults: .standard, file: lists?.timelines) : nil,
            hides: staged == nil ? ShellHides(defaults: .standard, file: lists?.hides) : nil
        )
        session.persist = persist
        session.persistUnsent = persistUnsent
        session.savesLanded = savesLanded
        session.carrier = carrier
        session.storeWritable = storeWritable
        session.nearbyLink = nearby
        session.deviceName = deviceName
        session.measureStore = measureStore
        session.compactStore = compactStore
        session.letWordsGo = letWordsGo
        session.weighStore = weighStore
        session.readPage = readPage
        session.readEarly = readEarly
        session.readSearch = readSearch
        session.afterFirstPage = afterFirstPage
        session.limitStore = limits
        _session = State(initialValue: session)
        _storeIsNewer = State(initialValue: storeIsNewer)
        self.storeNoticeSeen = storeNoticeSeen
        _storeTrouble = State(initialValue: storeTrouble)
        self.storeTroubleAnswered = storeTroubleAnswered
        self.staged = staged
        // Before anything asks whether there is a keyboard (`ShellHands`).
        if staged?.noKeyboard == true { ShellKeyboard.stagedAbsent = true }
        // A launch put somewhere is photographed there, and the mascot would be in the picture.
        _showingLanding = State(initialValue: staged == nil)
    }

    /// From here on, nothing leaves for a host that is not one of `hosts` — the sources the person
    /// added — or something one of them pointed to (#220). Said once, at launch, before anything
    /// is asked. After that `store` alone keeps it current, in the order its sources are added and
    /// let go — one writer, however many windows are open; a host the person names to add is
    /// theirs from the moment they name it.
    ///
    /// What may be reached beyond a source is the person's list (#226), read here from its file
    /// beside the store (`lists`, #344) — said to the book before the book is first touched.
    /// Where the store was `read` whole, a host they added for a source that is not in it
    /// goes; from then on one goes with its source, **in the order the store lets its sources
    /// go** — one stream, read on the main actor.
    public static func onlyToSources(
        _ hosts: [String], kept store: ItemStore, read: Bool = true, lists: ListFiles? = nil
    ) {
        if let lists { AllowanceBook.kept = lists.allowances }
        let work = SourceWork.shared
        work.govern(sources: hosts)
        // A launch that did not read its store asks for nothing nobody pressed for (#293, #295).
        ShellSession.loadsStartWith = read
        let book = AllowanceBook.shared
        book.launched(with: hosts, read: read)
        let (changes, feed) = AsyncStream<[String]>.makeStream()
        Task { @MainActor in
            for await hosts in changes { book.sourcesChanged(hosts) }
        }
        Task {
            await store.watchSources { hosts in
                work.sourcesChanged(hosts)
                feed.yield(hosts)
            }
        }
    }

    /// Hands the copies of pictures already on this device to the one picture cache every row
    /// draws from, once, at launch — and first drops the copies of any host not in `hosts`, the
    /// servers the reader still reads. Queued ahead of every picture a row can ask for, so the
    /// sweep never races a copy being written for a server just added. What is left is then
    /// trimmed to the cap (#7), so a cap lowered by a new build holds from its first launch.
    ///
    /// **Only where `hosts` is the list the person has** (`read`, #295). A run whose store could
    /// not be opened holds no sources, and dropping the copies of every host not among none
    /// would take every picture on the device while the notice says nothing was changed: the
    /// copies are then handed over as they are, neither swept nor trimmed, and still drawn from.
    public static func keepPictures(in copies: any MediaCopies, for hosts: [String], read: Bool = true) {
        ShellPictures.shared.disk = keptPictures(in: copies, for: hosts, read: read)
    }

    /// `keepPictures`' work, apart from where its result is put.
    static func keptPictures(in copies: any MediaCopies, for hosts: [String], read: Bool) -> DiskCopies {
        let disk = DiskCopies(copies)
        if read {
            disk.keepOnly(hosts: hosts)
            disk.trim()
        }
        return disk
    }

    private var availability: ShellAvailability { session.availability }

    /// Reduce motion never mounts the overlay, so a reader who asked for stillness does not
    /// get one frame of the jet and then a skip.
    private var playsLanding: Bool { showingLanding && !reduceMotion }

    /// Whether the join sheet is up, derived from the stage rather than stored beside it.
    ///
    /// Written out here rather than inline, because a `Binding` built inside the modifier chain
    /// pushes `body` past what the type-checker will solve in reasonable time.
    ///
    /// **Both halves of this were wrong the moment a preview could be drawn in the page, and
    /// neither is reachable from a test** — risk 12's class, on a path only a person walks.
    ///
    /// *The getter.* `session.stage != nil` is true for a preview that `AccountPane` is drawing
    /// between the field and the sources list, so this would put an empty sheet over it — empty
    /// because `JoinSheet` draws nothing it is not asked for, and over a screen the reader is
    /// reading. It asks the stage which surface draws it instead, which is what decision 20's
    /// `surface` exists for.
    ///
    /// *The setter.* `dismissStage()` cancels the whole errand. On the boards sheet that is wrong
    /// twice over: a swipe there is Back, and the preview it would throw away is still on screen
    /// underneath. `sheetDismissed()` is the routing, and it is a named method a test can call.
    private var stagePresented: Binding<Bool> {
        Binding(
            get: { session.stage?.surface == .sheet },
            set: { shown in if !shown { session.sheetDismissed() } }
        )
    }

    /// What the link reader is showing, as a sheet can drive it. Written out here rather than
    /// inline for the reason `stagePresented` is: a `Binding` built inside the modifier chain
    /// pushes `body` past what the type-checker will solve in reasonable time.
    ///
    /// Dismissed by any route at all — the button, a swipe, Escape — it is closed, and closing it
    /// takes nothing away: the timeline underneath was never torn down, so the reader is back at
    /// the post they left because they never left it. See `ShellReader`.
    private var linkReading: Binding<ShellReading?> {
        Binding(
            get: { linkReader.sheet },
            set: { shown in if shown == nil { linkReader.close() } }
        )
    }

    public var body: some View {
        layout
            // The reader's time window is set on the store once at launch, before the store is
            // adopted, so a window chosen last run binds what was kept and everything read after
            // (#7). `prefs` is its one owner; a change is handed on, and written only if it dropped.
            .task {
                // Before anything can be pressed: a page read out of a post is drawn in place on
                // a Mac (#169), and the reader asks the walk here where it may be.
                placeLinksInPage()
                tags.placing = { tag, row in openTag(tag, from: row) }
                placeMentions()
                placeQuotes()
                // What the search and the person pages draw is said to the store with the rest
                // of what is drawn (#359).
                session.openSearch = search
                session.personPages = people
                // What an earlier run could not put back and did not live to (#344): said once,
                // as the launch begins, and from here — a listing of the store's folder is no
                // work for an initializer that runs every time the view is made.
                if let carrier = session.carrier { session.carry.say(leftBy: carrier) }
                await session.loadLimitAccount()
                // The months limit before any page: every page is cut by it (#357). What it lets
                // go is let go a step at a time once the first page is in (below, #360).
                await session.cut(months: prefs.keepMonths)
                // **Where this launch lands is the sources' answer, and nothing else's** (#101,
                // #357): the timeline is there where a source is, whether or not a row of it has
                // been read, and its pane reads its first page as it shows — drawn as being read
                // until it lands. Asked here and nowhere else, so it is asked once.
                await session.reprojectSources()
                if let landing = launch.settle(availability, standingOn: place) {
                    place = landing
                }
                await session.reloadFromStore()
                await session.adoptUnsent()
                // The room as set (#249), then the months limit kept in the file, in a task of its
                // own so no page waits for more than one step of it (#360), and the launch's room
                // check once it has had its turn.
                session.roomBytes = prefs.roomBytes
                let months = prefs.keepMonths
                let keeping = Task { await session.keepAtLaunch(months: months) }
                defer { keeping.cancel() }
                // Ended with this view's own task, so a window closed stops saying its notice.
                let arriving = staged.map { staged in Task { await arrive(at: staged) } }
                defer { arriving?.cancel() }
                // Last, because it does not return: from here every landing renews what is in
                // front, with no key pressed (#175).
                await session.followStore()
            }
            .onChange(of: prefs.keepMonths) { _, months in
                Task { await session.keep(months: months) }
            }
            // Posts their source deleted go on this device's wait (#179).
            .modifier(LettingGoneGo(session: session))
            // A save that lands after one failed takes down what was said of the failure.
            .modifier(FollowingSaves(session: session))
            // And the store is held within the room the person gave it (#249).
            .modifier(KeepingWithinRoom(session: session))
            .modifier(AsksOnAWait(session: session, minutes: prefs.askMinutes))
            .modifier(AnnouncementsAsk(session: session, announcements: people.announcements))
            // The pages open over the timeline, whose rows the store keeps while they are (#359).
            .modifier(PinsPages(session: session, pages: openPages))
            // And the open search read from the file, past what is held (#360).
            .modifier(CoversSearch(session: session, ask: session.searchAsk(search, latest: prefs.latestDate)))
            .onChange(of: place) { old, new in
                let accepted = availability.placing(old, as: new)
                if accepted != new { place = accepted }
                guard accepted != old else { return }
                // A walk a notice began is come back from by leaving it, and not by leaving
                // the timeline some other way.
                if accepted != .timeline { errand = nil }
                // Nothing is asked for notices while their page is closed.
                if old == .notices { session.noticeList.stop() }
                // Closed on the stream it was opened over, before the session follows another.
                if search.closes(leaving: old, for: accepted) { closeSearch() }
                if let stream = ShellStream(accepted) { follow(stream) }
                // A picture opened over the timeline is not opened over the account page.
                _ = closeViewer()
                // And the film stops — **including one playing in a row**, which is the half
                // `closeViewer` cannot do, because with a row playing the viewer was never open.
                playback.stop()
                // A source's detail left behind on Usage is not waiting there on the way back.
                session.usageOpened = nil
                session.preferencesOpened = nil
            }
            // The rail and the tab bar both draw only the places that can be entered.
            // If that set ever narrows under the reader — a sign-out, a source
            // dropped — the selection would point at a tab that is no longer there.
            .onChange(of: availability) { _, new in
                // Trends gone with the last source that had it: its walk ends, so nothing of it is
                // held for a page nobody can reach, and `h` lands on nothing left of it later.
                if !new.allows(.trends), let cleared = Self.trendsGone(&sides, tagAsk: session.reload.tagAsk?.timeline) {
                    letGo(cleared)
                }
                settleTrendsFront(among: new.trendsTabs)
                let accepted = new.placing(place, as: place)
                if accepted != place { place = accepted }
            }
            // A timeline switched is the list every step of the walk was standing on being
            // replaced, so the walk ends rather than unwinds: there is no row left to hand the
            // lamp back to. Where the lamp lands is #100's, and `TimelinePane` answers it on the
            // same change. Here rather than in the pane because the walk is held here — the pane
            // used to do it through a binding whose one meaning was "close the thread".
            // A tag's page in front stays, and is asked again of the new timeline (#197).
            .onChange(of: session.timelineID) { left, arrived in timelineSwitched(from: left, to: arrived) }
            .sheet(isPresented: $composing) {
                ComposerSheet()
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    #endif
            }
            // Taking back what the reader wrote (#109): the one act that asks first. A modifier of
            // its own rather than the dialog spelled here — see `WithdrawQuestion`.
            .modifier(WithdrawQuestion(session: session))
            .modifier(PartQuestion(session: session))
            .modifier(PersonPresenters(people: people, session: session))
            .modifier(UnsentPresenters(session: session))
            // An answer, over the conversation it belongs to (#108). Driven by the session's one
            // value, so the key and the mark open the same surface by writing the same thing.
            .sheet(item: $session.answering) { target in
                AnswerSheet(target: target)
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    #endif
            }
            // **A link the reader pressed in somebody's words, drawn over the shell** (#34). On
            // the root beside the other presenters and for their stated reason: one presenter
            // driven by one piece of state survives a second call site, and this one has three
            // already — a timeline row, a row in an open thread, and a row of the search's
            // results.
            //
            // **Over, and never instead of.** A sheet leaves the page under it standing, so the
            // list, where it is scrolled to and which post is selected are all exactly as they
            // were when it closes. That is the whole of "the reader comes back to the post they
            // left": there is nothing to restore, because nothing was taken away.
            //
            // **On a Mac, only where the page cannot be drawn in place** (#169): pressed on the
            // timeline place, the page is a step of the walk and fills that place instead —
            // still over the page it came from, which `LinkInPlace` leaves standing — and this
            // sheet is not presented for it. See `ShellReader.inPlace`.
            .sheet(item: linkReading) { reading in
                LinkReaderSheet(presented: reading, reader: linkReader) { linkReader.close() }
            }
            // **On the root, beside the composer's, and not on a pane.** A sign-in is asked for
            // from Account, where a refusal is reported, and it will be asked for from a timeline
            // the day a forum's session lapses mid-scroll — so a sheet attached to either pane
            // would be a sheet that does not open from the other. One presenter, driven by one
            // piece of session state, is the shape that survives both call sites.
            // **A window on macOS, a sheet on iOS**, and the split is about what the reader can
            // do rather than about taste: a macOS sheet cannot be resized by anybody, and what is
            // inside this one is somebody else's login page drawn at whatever size this app
            // guessed. A reader who could not see the password field had no way to make it
            // bigger. On iOS a sheet already fills the screen, so there is nothing a window would
            // add. See `ForumSignInWindows`.
            #if os(macOS)
            .onChange(of: session.signingIn) { _, request in
                if let request {
                    signInWindows.show(request, sessions: session.forums) { reached in
                        signInReturned(reached: reached, host: request.host)
                    }
                } else {
                    signInWindows.close()
                }
            }
            #else
            .sheet(item: $session.signingIn) { request in
                ForumSignInSheet(request: request, sessions: session.forums) { reached in
                    signInReturned(reached: reached, host: request.host)
                }
            }
            #endif
            // **Adding a source, all three stages of it, on the root beside the other two.**
            // Nothing has been added at any of them, so dismissing this by any route at all — the
            // button, a swipe, Escape — is a complete cancel with nothing to undo. Attached here
            // rather than to Account for the reason the sign-in sheet is: one presenter, driven by
            // one piece of session state, survives a second call site.
            //
            // **`isPresented` and not `item:`, which is the correction and not the shortcut.** A
            // stable `id` is precisely what stops SwiftUI re-presenting a sheet, so with `item:`
            // whether the content builder re-runs when the stage changes under the same host is
            // version-dependent behaviour rather than contract — and the likely outcome on a
            // device is the preview sitting on screen while the session says boards. `JoinSheet`
            // reads `session.stage` inside its own body and switches there, which is a redraw.
            .sheet(isPresented: stagePresented) {
                JoinSheet(session: session, onOwnPage: ownPageOpener, onPeople: directoryOpener, more: people.more, you: people.you, announcements: people.announcements)
            }
            // The timeline editor (#27), on the root beside the other presenters for their reason.
            // Dismissed by any route it is Cancel: the draft is dropped (Decision 21).
            .sheet(item: $session.editing) { draft in
                TimelineEditor(session: session, draft: draft)
            }
            // The notice that a server ended a sign-in: a modifier of its own rather than spelled
            // here. See `WithdrawQuestion` for why. Remove's question and Clear's are not on the
            // root: each is asked by the `…` it is chosen from (`ShellMoreAsks`).
            .modifier(EndedSignInNotice(session: session))
            .modifier(ActivitySheet(session: session))
            .modifier(StoreNewerNotice(shown: $storeIsNewer, seen: storeNoticeSeen))
            .modifier(StoreTroubleNotice(trouble: $storeTrouble, answered: storeTroubleAnswered))
            .overlay {
                if showingShortcuts {
                    ShortcutGuide(tab: $shortcutTab) { showingShortcuts = false }
                }
            }
            // Outside the guide's overlay and after it, which is what puts it on top of
            // everything this view draws. The order of the two `if`s here and the order of
            // `DummyLayer`'s cases say the same thing, and they have to: one is what a reader
            // sees in front, the other is what a press to leave takes away.
            //
            // **Everything under the viewer leaves the accessibility tree while it is open.**
            // A plain `.overlay` draws on top and removes nothing, so without this a reader using
            // VoiceOver, or a focus traversal, could still reach a row's play mark and start a
            // film behind a ground they can neither see through nor stop — the exact fault
            // `openViewer` stops playback to avoid, arriving by another route. Applied here so it
            // covers the guide as well, which the viewer is also allowed to open over.
            .accessibilityHidden(viewedItem != nil)
            .overlay { viewer }
            // After the viewer, so the mascot is the first thing a launch draws over.
            .overlay {
                // **Drawn over, and never in the way** (#357): a press, a key or a pointer goes to
                // the app under it, which is there and usable from the first frame.
                if playsLanding {
                    LandingView { showingLanding = false }
                        .id(landingTick)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: showingShortcuts)
            .animation(.easeInOut(duration: 0.18), value: viewing)
            // A viewer whose post the last refresh took away is not a layer any more, and the id
            // that named it must not survive to spring it open again when the post comes back.
            .onChange(of: currentListIDs) { _, _ in forgetAVanishedViewer() }
            // On a Mac this is not only a return from the background: `scenePhase` goes
            // `.inactive` whenever the window stops being the key one, so this fires on every
            // regain of focus. That is more often than the outage needs and still far less often
            // than anything the stranded cohort could cause itself, which is the rule that
            // matters — and the cache's own dedup makes a fetch nobody needs free.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    wakeTheCaches()
                    // A Keychain read at launch on a locked device finds no token; the sign-in
                    // is read again once the reader is here.
                    session.mastodon.cameToFront()
                } else if ShellSession.windowLeft(phase),
                          session.stage?.closesWhenTheWindowLeaves == true {
                    // **The selectors only**, and the stage is what says so. The editor and a new
                    // post are `composing` and `signingIn` below, which this cannot reach: a
                    // sign-in closed because the reader went to their password manager would be
                    // the worst version of this feature, and it is unreachable rather than
                    // remembered.
                    session.dismissStage()
                }
            }
            .dummyShellKeys(home: search.submits) { character, shift, control, command in
                performDummyKey(character, shift: shift, control: control, command: command)
            }
            .environment(prefs)
            // **The session, for the panes that are handed no binding.** `UsagePane` reads
            // it out of the environment, and without this it is nil on every real launch — so the
            // pane draws its empty state and tells a reader who has already joined a server to go
            // and add one. A pane whose whole purpose is not to say a false thing, saying one.
            //
            // A hand-off rather than a local need: this view is the only place that holds the
            // session, so it is the only place that can put it there. See `PLAN.md`, Cross-worktree
            // hand-offs.
            .environment(session)
            // **Where a link in a post's words goes, handed down once from the one place that
            // can.** Every line of every post reads this, and it reaches a timeline row, a row in
            // an open thread and a row of the search's results by the same hand-off — they are
            // all drawn under here. The object is handed down rather than a closure: a closure
            // has no identity, so it would differ on every pass of this view and invalidate every
            // line on the screen with it. See `ShellReader`.
            .environment(\.shellReader, linkReader)
            .environment(\.shellTags, tags)
            .environment(\.shellMentions, mentions)
            .environment(\.shellQuotes, quotes)
            // The hosts still here, handed down once for the same reason: a row from a source
            // since removed says so wherever it is drawn (#250), and only the root knows which.
            .environment(\.shellSourcesHere, Set(session.sources.map(\.host)))
            // Whether there is nothing here but a finger (#303), asked once and handed down.
            .environment(\.shellTouch, ShellHands.shared.touch)
            .environment(\.shellCovered, Self.covered(viewing: viewedItem != nil, shortcuts: showingShortcuts, landing: playsLanding))
            .overlay(alignment: .top) {
                if staged?.reports == true { StagedReport(session: session, counts: staged?.counts == true) }
            }
            .overlay {
                if staged?.menus == true { StagedMenus(session: session) }
            }
            .environment(\.locale, prefs.language.locale)
            .preferredColorScheme(prefs.theme.colorScheme)
            .dynamicTypeSize(prefs.fontSize.dynamicType)
            .id(prefs.language)
    }

    /// A forum's own page closed, on the window a Mac opens it in or the sheet elsewhere — **one
    /// body for both**, because this branch once lost the retry and the host when the page moved
    /// out of the sheet: the window was given the body the sheet had at the time, and the sheet
    /// grew them afterwards.
    ///
    /// **A sign-in that was reached goes straight back to the join.** The reader typed a host,
    /// was turned away, and went and signed in; the errand was always "add this forum", and
    /// without the retry the page closes onto the refusal it was opened from, which reads as a
    /// sign-in that did nothing. This second pass goes through the browser that now holds the
    /// session — see `ShellSession.joiner`.
    ///
    /// **`resumeAfterSignIn` and not `add`**, because `add` stops at the preview — a screen this
    /// reader has already read and already answered. They pressed Subscribe before they were
    /// turned away; this finishes that press rather than asking for it again.
    ///
    /// **And the `if` is not only "was it reached".** A sign-in pressed on a row of a server
    /// already joined is an errand that ends with the sign-in itself, and `signInFinished` says
    /// no to those — see its doc comment for what the reader sees instead.
    private func signInReturned(reached: Bool, host: String) {
        if session.signInFinished(reached: reached, host: host) {
            Task { await session.resumeAfterSignIn() }
        }
    }

    private func performDummyKey(
        _ character: Character,
        shift: Bool,
        control: Bool,
        command: Bool
    ) -> Bool {
        guard let mapped = DummyCommand.from(
            character,
            shift: shift,
            control: control,
            command: command,
            typing: composing,
            fieldFocused: session.searchFocused || search.fieldFocused
        ) else {
            return false
        }
        // The editor is a sheet and owns its keys; nothing under it moves. Nor under the record
        // of this run's requests, which is a sheet too.
        if session.editing != nil || session.activityShown { return false }
        let did = apply(mapped)
        return DummyCommand.consumes(character, did: did)
    }

    private func apply(_ command: DummyCommand) -> Bool {
        // Before any rule reads `openLayers`, so no press can act on a viewer that is not there.
        forgetAVanishedViewer()
        switch command {
        case .nextTab:
            guard DummyCommand.outermost(of: openLayers) == .shortcuts else {
                return rotatePlaceTab(by: 1)
            }
            shortcutTab = DummyShortcutGroup.rotated(from: shortcutTab, by: 1)
            return true
        case .previousTab:
            guard DummyCommand.outermost(of: openLayers) == .shortcuts else {
                return rotatePlaceTab(by: -1)
            }
            shortcutTab = DummyShortcutGroup.rotated(from: shortcutTab, by: -1)
            return true
        case .nextPage:
            place = availability.rotate(from: place, by: 1)
            return true
        case .previousPage:
            place = availability.rotate(from: place, by: -1)
            return true
        case .nextPost:
            return place == .notices ? moveInNotices(by: 1) : moveInList(by: 1)
        case .previousPost:
            return place == .notices ? moveInNotices(by: -1) : moveInList(by: -1)
        case .goTop:
            return place == .notices ? jumpNoticesToTop() : jumpListOrThreadToTop()
        case .expandPost:
            return place == .notices ? openFocusedNotice() : openThread()
        case .nextAttachment:
            return onActedItem(turn)
        case .reveal:
            return revealFocused()
        case .viewAttachment:
            return openViewer()
        case .playAttachment:
            return playFocused()
        case .back:
            // `q` leaves what is in front of it and reaches past nothing — the same one
            // expression of the order `Escape` reads. It used to intersect a local subset of the
            // layers, which was the order written down a second time.
            //
            // **No `default:`, and this one was found still here.** The plan records a `default:`
            // over a protocol kind shipping a silent wrong answer once already and says the shape
            // is gone; it was not — it was in this switch, over `DummyLayer?`, six commits later.
            // `.dismiss` below has always enumerated all four and `nil` besides, which is what
            // made the difference invisible: the two halves of one rule, written two ways, one of
            // them free to fall through. A fifth layer added to `DummyLayer` now has to say what
            // `q` does about it.
            // Only what is on screen, as Escape reads it.
            switch DummyCommand.outermost(of: Self.escapeSees(openLayers, place: place)) {
            case .viewer: return closeViewer()
            // One step back, whichever kind of step it was. The two lines used to be two
            // methods over two pieces of state; they are one walk now, and unwinding it in the
            // order the reader walked is the whole of what a press to leave does (#122).
            case .person, .tag, .people, .rising, .thread, .link: return leaveWalk()
            case .search, .shortcuts, .selection, nil: return false
            }
        case .reload:
            return reload()
        case .showShortcuts:
            // Closing is always allowed; opening obeys the entry rule, so `?` under an open
            // viewer does nothing and yields rather than closing the viewer to make room.
            if showingShortcuts {
                showingShortcuts = false
                return true
            }
            guard DummyCommand.canOpen(.shortcuts, whenOpen: openLayers) else { return false }
            showingShortcuts = true
            return true
        case .search:
            return openSearch()
        case .boost:
            return actFocused(.boost)
        case .favourite:
            return actFocused(.favourite)
        case .keep:
            return onFocusedItem { item in
                Task { await session.toggleKept(item) }
                return true
            }
        case .answer:
            return answerFocused()
        case .withdraw:
            return place == .notices ? dismissFocusedNotice() : onFocusedItem { session.askToWithdraw($0) }
        case .openAuthor:
            return place == .notices ? openFocusedNoticePerson() : openAuthor()
        case .openTag:
            return openTagFocused()
        case .openQuote:
            return onFocusedItem { openQuote(of: $0) }
        case .openTrends:
            return openTrends()
        case .follow:
            return followByKey()
        case .compose:
            guard availability.canCompose else { return false }
            showingShortcuts = false
            composing = true
            return true
        case .replayLanding:
            showingShortcuts = false
            _ = closeViewer()
            playback.stop()
            landingTick += 1
            showingLanding = true
            return true
        case .editTimeline:
            guard place == .timeline, DummyCommand.canEditTimeline(whenOpen: openLayers) else { return false }
            return session.editCurrentTimeline()
        case .dismiss:
            // A running reload is the first thing Escape stops (#29); the next one leaves.
            // So is a thread's next page on its way (#177), before the thread itself closes.
            // **The page in front's, and nobody else's** (decision 17).
            if place.isStream, stopInFront() { return true }
            // On Notices: the read on the wire, then that page's own lamp.
            if Self.noticesInFront(place: place, open: openLayers) {
                // A reading-on goes on to its end, as the timeline's does (DESIGN-reload).
                if session.noticeList.ask().stoppable, session.noticeList.stop() { return true }
                if noticeSelectedID != nil {
                    noticeSelectedID = nil
                    return true
                }
            }
            // Only what is on screen: a walk left open on the timeline is not unwound from Usage.
            let open = Self.escapeSees(openLayers, place: place)
            // A source's detail on Usage goes back to its list before anything further out.
            if place == .usage, open.subtracting([.selection]).isEmpty, session.closeUsageSource() { return true }
            // And a detail on Preferences, to its list (#233).
            if place == .preferences, open.subtracting([.selection]).isEmpty,
               session.closePreferencesDetail() { return true }
            switch DummyCommand.outermost(of: open) {
            case .viewer: return closeViewer()
            case .shortcuts:
                showingShortcuts = false
                return true
            case .person, .tag, .people, .rising, .thread, .link: return leaveWalk()
            case .search:
                closeSearch()
                return true
            case .selection:
                selectedItemID = nil
                return true
            case nil: return false
            }
        }
    }

    /// The open layers Escape may take away on `place`: all of them on a stream place — the
    /// timeline, Trends — and away from them none of their own — a walk (person, tag, thread,
    /// link) and a search are drawn only there, so on Usage or Preferences they are open but not
    /// on screen, and a press that unwound them there would change nothing the reader can see
    /// (#239).
    static func escapeSees(_ open: Set<DummyLayer>, place: ShellPlace) -> Set<DummyLayer> {
        place.isStream ? open : open.subtracting([.person, .tag, .people, .rising, .thread, .link, .search])
    }

    /// What is open, in the order a press to leave takes it away. See `DummyLayer`.
    private var openLayers: Set<DummyLayer> {
        Set(DummyLayer.allCases.filter(isOpen))
    }

    /// Whether one layer is open, answered case by case.
    ///
    /// **An exhaustive `switch` over `DummyLayer` rather than a run of `if`s**, and deliberately
    /// the same shape the suite's harness uses. A run of `if`s lets the product describe a
    /// smaller world than the test — a layer added later would be silently absent from every set
    /// this builds, so `outermost` would put the new layer nowhere and `canOpen` would wave it
    /// through. Written this way, a fifth case stops the app and its harness compiling together
    /// until both answer it.
    ///
    /// The order is still nowhere near here. This says what is open; `DummyLayer.allCases` says
    /// what is in front of what, and it says it once.
    private func isOpen(_ layer: DummyLayer) -> Bool {
        switch layer {
        case .viewer: viewedItem != nil
        case .shortcuts: showingShortcuts
        // **Only the innermost step of the walk is open**, so these two are never both true
        // (#122). That is what lets the order between them go unasked: `outermost` is handed at
        // most one of them, and `DummyCommand.canWalk` asks about the pair rather than either.
        case .person: walk.openedPerson != nil
        case .people: walk.openedPeople != nil
        // The pages of the hashtags a search found and of those followed (#318, #319).
        case .rising: walk.openedFoundTags != nil || walk.openedFollowedTags != nil
        case .tag: walk.openedTag != nil
        case .thread: walk.openedThread != nil
        case .link: walk.openedLink != nil
        case .search: search.isOpen
        case .selection: selectedItemID != nil
        }
    }

    /// Whether a picture may be opened over the app at all right now. Read by `v` and by a press
    /// on a card, which is `v`'s touch path (#33) — one expression, so the key and the press
    /// cannot come to disagree about when the viewer may open.
    private var canOpenViewer: Bool {
        viewedItem == nil && DummyCommand.canOpen(.viewer, whenOpen: openLayers)
    }

    /// Opens what is on top of the focused row's deck, over the whole app.
    ///
    /// A second `v` while it is open does nothing. `Escape` and `q` are how this is left, and one
    /// key that both opens and closes a layer is the conditional rule the order above is kept
    /// free of. The letter is still ours either way — see `DummyCommand.consumes`.
    ///
    /// The guard is here as well as in `view(_:)` so that a second `v` while the viewer is up
    /// moves nothing: `onFocusedItem` lights the first row when nothing is lit, and a press that
    /// is about to be refused must not do that either. That is the whole of what it covers — the
    /// viewer is the outermost layer there is, so it may open over anything, the keys list
    /// included.
    private func openViewer() -> Bool {
        guard canOpenViewer else { return false }
        return onFocusedItem(view)
    }

    /// One post's picture, opened over the app. What `v` does, and what a press on a card does.
    private func view(_ item: DummyItem) -> Bool {
        guard canOpenViewer, decks.showing(item.attachments, of: item.id) != nil else { return false }
        // Whatever the row was playing stops. It would go on playing behind an opaque ground
        // where nobody can see it or stop it, which is the "sound from a row that has scrolled
        // off" fault arriving by another route.
        playback.stop()
        viewing = item.id
        return true
    }

    /// One post's deck, turned. What `m` does, and what a press on the counter in a card's corner
    /// does.
    private func turn(_ item: DummyItem) -> Bool {
        let inViewer = viewedItem != nil
        guard decks.turn(item.id, of: item.attachments.count) else { return false }
        // Sound out of a card the reader has just turned away from is a fault, and so is a
        // thumbnail still moving after it has stopped being the thumbnail. Only where something
        // actually turned: a deck of one leaves nothing behind to stop.
        playback.stop()
        // And the viewer stops holding the card it has turned away from. Without this, `v` and
        // three presses of `m` on a post carrying four pictures hold four addresses at viewer
        // tier, which is the contract broken by ordinary use.
        if inViewer { ShellPictures.shared.releaseViewerTier() }
        return true
    }

    /// A press on a card, which is the touch path to `v` (#33) — and a press on the counter in
    /// its corner, which is the one to `m`.
    ///
    /// **The rules live here and not in the pane**, exactly as `playRow` says: a mark and the key
    /// it stands for must not come to mean two different things, so both read the same function
    /// the key reads. On the row that was pressed rather than on the focused one — a press says
    /// which row it means.
    private func viewRow(_ item: DummyItem) {
        _ = view(item)
    }

    private func turnRow(_ item: DummyItem) {
        _ = turn(item)
    }

    /// Says whether a viewer a reader could see was closed — and tidies up either way.
    ///
    /// The tidying runs on a stale id too, which is what keeps an id left pointing at a post the
    /// last refresh took away from springing the viewer open again when that post comes back.
    private func closeViewer() -> Bool {
        guard viewing != nil else { return false }
        let wasOpen = viewedItem != nil
        viewing = nil
        playback.stop()
        // The viewer stops drawing, so the cache stops holding what it was drawing. See
        // `ShellPictures.releaseViewerTier()`: this is what keeps the unit 7 contract true by
        // construction rather than by everybody remembering it.
        ShellPictures.shared.releaseViewerTier()
        return wasOpen
    }

    /// Drops a viewer whose post the list no longer has.
    ///
    /// The drawing half was already safe — `viewedItem` looks up rather than trusts — but the id
    /// itself has to go too, and `Escape` will not do it: with the post gone the viewer is not a
    /// layer, so the dismiss resolves to something underneath and never reaches `closeViewer`.
    private func forgetAVanishedViewer() {
        if viewing != nil, viewedItem == nil { _ = closeViewer() }
    }

    /// A press on a card's own play mark, which is the pointer's way to `a`.
    ///
    /// **The rule lives here and not in the pane**, so that a mark and the key cannot come to mean
    /// two different things. On the row that was pressed rather than on the focused one — a
    /// pointer says which row it means.
    private func playRow(_ item: DummyItem) {
        guard viewedItem == nil, !isCovered(item) else { return }
        let file = ShellPlaying.playable(decks.showing(item.attachments, of: item.id))
        playback.toggle(file, of: item.id, on: .row, from: item.source.host)
    }

    /// The post the viewer is showing, where there is one to show.
    ///
    /// **Looked up rather than trusted.** A refresh can take the post away under an open viewer,
    /// and an id that names nothing would otherwise be a layer that is counted as open, closed by
    /// `Escape`, and drawn by nobody.
    private var viewedItem: DummyItem? {
        guard let viewing else { return nil }
        return currentListItems.first { $0.id == viewing }
    }

    /// Starts what is on top, or stops it if it is what is already playing.
    ///
    /// The stage is decided here and nowhere else: with the viewer open `a` means the viewer's
    /// full player, and otherwise the slot's silent one.
    ///
    /// **Nothing plays under a cover.** The row is blurred and the viewer draws its notice over
    /// the picture, so a film started there is one the reader has not agreed to see, playing where
    /// they cannot see it. `s` first, then `a`.
    private func playFocused() -> Bool {
        let stage: ShellPlaying.Stage = viewedItem == nil ? .row : .viewer
        return onActedItem { item in
            guard !isCovered(item) else { return false }
            let file = ShellPlaying.playable(decks.showing(item.attachments, of: item.id))
            return playback.toggle(file, of: item.id, on: stage, from: item.source.host)
        }
    }

    private func isCovered(_ item: DummyItem) -> Bool {
        item.covered && !decks.isLifted(item.id)
    }

    /// The post a press acts on: what the viewer is showing where it is open, and the focused row
    /// otherwise.
    ///
    /// This is the whole of what makes `m`, `a` and `s` mean the same thing with the viewer open.
    /// The same three keys, on the same post, against the same `decks` — not three keys that have
    /// learned a second meaning, which is what a viewer with state of its own would have needed.
    private func onActedItem(_ act: (DummyItem) -> Bool) -> Bool {
        guard let item = viewedItem else { return onFocusedItem(act) }
        return act(item)
    }

    /// What `v` opened, drawn over everything else this view draws.
    @ViewBuilder
    private var viewer: some View {
        if let item = viewedItem {
            AttachmentViewer(
                attachments: item.attachments,
                top: decks.top(of: item.id, of: item.attachments.count),
                covered: isCovered(item),
                hasCover: item.covered,
                coverLine: coverLine(of: item),
                emojis: item.emojis,
                host: item.source.host,
                player: playback.player(
                    for: ShellPlaying.playable(decks.showing(item.attachments, of: item.id)),
                    of: item.id,
                    on: .viewer
                ),
                onToggleCover: { _ = apply(.reveal) },
                onPlay: { _ = apply(.playAttachment) },
                onTurn: { _ = apply(.nextAttachment) },
                onGone: { playback.stop() },
                onClose: { _ = closeViewer() }
            )
        }
    }

    /// The author's warning, or nothing where they flagged it and wrote none — no sentence of
    /// ours in their place, the same as the row.
    private func coverLine(of item: DummyItem) -> String? {
        let spoiler = item.spoiler ?? ""
        return spoiler.isEmpty ? nil : spoiler
    }

    /// Asks again for the pictures on this screen that were written off while the network was down.
    ///
    /// **The cache cannot start this by itself, and that is deliberate.** Every stranded row
    /// re-asks correctly the moment *any* fetch gets through — the arrival clears the whole
    /// outage cohort and bumps the generation, which is what every `RemoteImage` is waiting on.
    /// But nothing inside the cache can produce that first success, so a reader who opened the
    /// app with no signal, put it down and came back to a working one sees a screen of `photo`
    /// glyphs until they scroll. Coming back to the front is an event the stranded cohort cannot
    /// cause itself, which is exactly what the cache's rule about relief asks for.
    ///
    /// **Driven from here rather than from inside the cache**, for two reasons that are in
    /// `stranded(among:scale:)` in full: a `Key` carries no host and a fetch needs one, and a
    /// wake that reached keys nobody is drawing could mark them `.crowded`, which is terminal.
    /// This view is the one place that holds both an address and the server it arrived through.
    ///
    /// Every address a row can draw is offered, not only the card currently on top of a deck:
    /// the filter is `.unreachable`, and only an address that was actually fetched and failed
    /// carries that mark, so what is offered but never drawn cannot be woken.
    ///
    /// **Started together, never awaited one after another.** That is not house style, it is the
    /// two-phase precondition admission rests on: a call site that asks and satisfies in the same
    /// pass makes each newcomer the most recently wanted thing in the cache, which defeats
    /// admission entirely. See `ShellPictures`, I5.
    ///
    /// **These are not speculative fetches and may evict.** A stranded key whose row is still on
    /// screen has been re-stamped by `picture(…)` on every body pass since, so it arrives with a
    /// real `interest` and is admitted on its merits like any other. That is the right answer —
    /// the row genuinely is wanted — but it is not the "displaces nothing" case, which belongs to
    /// a key no body has read at all.
    ///
    /// When the emoji catalogue's pictures land they have the same problem and belong on this
    /// line, beside this one.
    private func wakeTheCaches() {
        let cache = ShellPictures.shared
        let drawn = currentListItems.flatMap { item in
            ((item.avatarURL.map { [$0] } ?? []) + item.attachments.compactMap(\.displayURL))
                // The source the post arrived through, which is the only kind of server a Clear
                // button can ever name. Not the author's home instance — see the avatar in
                // `DummyItemRow`.
                .map { DrawnPicture(url: $0, host: item.source.host) }
        }
        let woken = cache.stranded(among: drawn, scale: displayScale, from: wakeCursor)
        // Moved on by what was actually asked for, so the next activation starts where this one
        // stopped and a handful that keeps failing cannot be the whole of every activation. See
        // `stranded(among:scale:from:)`.
        wakeCursor += woken.count
        for picture in woken {
            Task { @MainActor in
                await cache.fetch(picture.url, scale: displayScale, tier: .deck, host: picture.host)
            }
        }
    }

    /// Does something to the post the reader is on, and says whether anything happened.
    ///
    /// The rule about where a press lands is `DummyCommand.focused(in:selected:)`, which is where
    /// it can be tested; this is the acting half. On a post with nothing to do — a deck of one,
    /// a row with no cover — the press moves nothing and says so.
    private func onFocusedItem(_ act: (DummyItem) -> Bool) -> Bool {
        guard place.isStream else { return false }
        switch Self.focused(in: currentListItems, selected: selectedItemID, open: drawnOpenLayers) {
        case .nothing:
            return false
        case .first(let id):
            selectedItemID = id
            return true
        case .post(let item):
            return act(item)
        }
    }

    /// Where a key that acts on a post lands, under what is open: `DummyCommand.focused`, and
    /// nothing where its answer is to light a first row that may not be lit — the lamp entering
    /// under a layer in front. Static so a test presses the rule the root does, as `moved` is.
    ///
    /// **So a mark's key does nothing with the lamp on a row that is no post** — a figure on
    /// somebody's page that opens a list (#311): the lamp is lit, so it is not entering, and
    /// it is not moved off the figure onto a post the reader did not choose.
    static func focused(in items: [DummyItem], selected: String?, open: Set<DummyLayer>) -> DummyFocus {
        let focus = DummyCommand.focused(in: items, selected: selected)
        if case .first = focus, !DummyCommand.canOpen(.selection, whenOpen: open) { return .nothing }
        return focus
    }

    /// j/k and the arrows walk whichever list is in front: the stream, or the open conversation.
    private func moveInList(by step: Int) -> Bool {
        guard place.isStream,
              let next = Self.moved(
                  in: currentListIDs, from: selectedItemID, by: step, open: drawnOpenLayers, entry: currentListEntry
              ) ?? ShellSearchFound.firstLit(
                  foundRowIDs, firstPost: streamItems.first?.id, selected: selectedItemID,
                  fieldFocused: search.fieldFocused, open: drawnOpenLayers
              )
        else { return false }
        selectedItemID = next
        return true
    }

    /// Where `j` or `k` puts the lamp in the list in front, or nothing where the press moves
    /// nothing. Static so a test that follows the reader's keys presses the rule the root does
    /// (#168), rather than a copy of it.
    ///
    /// Entering the selection obeys the entry rule the same as any other layer — asked with the
    /// walk set aside (`DummyCommand.canLightRow`), since the rows walked are the walk's own
    /// step's: a page reached with nothing lit takes a first `j`. Moving an existing lamp asks
    /// nothing — it is already on, and `j` means move rather than enter. So this refuses a
    /// first press under the viewer or the guide — or among a search's results, which is why
    /// Return lights the first rather than leaving `j` to; a page opened from a result is a step
    /// over the search, and takes it.
    ///
    /// **`entry` is where a lamp that is on none of the rows comes down to**, where the list
    /// has rows over the one reading starts at — the figures over somebody's posts (#311): `j`
    /// lands on their first post, as it did before anything stood above it, and `k` from there
    /// climbs to the figures. A lamp already on a row steps from that row, whichever it is.
    static func moved(
        in ids: [String]?, from selected: String?, by step: Int, open: Set<DummyLayer>, entry: String? = nil
    ) -> String? {
        guard let ids else { return nil }
        if selected == nil, !DummyCommand.canLightRow(whenOpen: open) { return nil }
        if let entry, step > 0, ids.contains(entry), selected.map(ids.contains) != true { return entry }
        return DummyCommand.stepped(ids, from: selected, by: step)
    }

    /// The stream `j` and `k` move through: a search's results while one is open, otherwise the
    /// current query over the store.
    private var streamItems: [DummyItem] {
        searchItems ?? session.timelineItems(latest: prefs.latestDate)
    }

    private var searchItems: [DummyItem]? {
        session.searched(search, latest: prefs.latestDate)
    }

    /// Whether `/` — and the mark in the header that is its touch path (#33) — can do anything
    /// now.
    ///
    /// **One expression, two readers.** The key asks it before opening, and the timeline's header
    /// asks it to decide whether to draw the mark at all: decision 4's rule is a control that is
    /// absent rather than dead, and the only way a mark and a key cannot come to disagree about
    /// when the search may open is for both to read this.
    ///
    /// An open search is still searchable — `canOpen` of a layer that is already the outermost is
    /// true — because that is exactly what a second `/` does: it hands the field the keys again.
    static func canSearch(place: ShellPlace, open: Set<DummyLayer>) -> Bool {
        place.isStream && DummyCommand.canOpen(.search, whenOpen: open)
    }

    /// `canSearch` here and now: never over a tab of Trends that lists what is rising, whose rows
    /// are no posts — the search is the stream's, and Posts is where it is.
    private var canSearchNow: Bool {
        risingInFront == nil && Self.canSearch(place: place, open: drawnOpenLayers)
    }

    /// `/` on the timeline: an empty search over what the timeline in front lets through (#145), or
    /// the field again if one is open. The selection is put aside, to come back when the search closes.
    private func openSearch() -> Bool {
        guard canSearchNow else { return false }
        // Over a step that cannot be drawn the stream is what is searched, and the step goes.
        leaveUndrawnWalk()
        if search.isOpen {
            search.focus()
        } else {
            search.open(from: selectedItemID, over: session.notes)
            selectedItemID = nil
            people.found.opened(in: session)
        }
        return true
    }

    /// The timeline back as it was, with the post that was selected before the search. Its ask
    /// of the sources ends with it (#176), and so does what they found beside posts (#319).
    private func closeSearch() {
        clearWalk()
        selectedItemID = search.close()
        session.reload.endSearch()
        people.found.closed()
    }

    /// Return in the field: the first result lit, and the pattern asked of the sources of the
    /// timeline in front as well (#176). What this device holds is already lit; what the sources
    /// send lands in the store and joins it.
    private func searchSubmitted() {
        selectedItemID = streamItems.first?.id
        let pattern = search.pattern
        let timeline = session.currentTimeline
        let found = people.found
        Task { await session.reload.search(pattern, timeline: timeline, found: found, in: session) }
    }

    /// The field emptied: the timeline is back, so the post selected before the search is too.
    private func searchCleared() {
        session.reload.endSearch()
        people.found.closed()
        search.cleared { selection in
            clearWalk()
            selectedItemID = selection
        }
    }

    /// Whichever list is in front: somebody's own posts, the open conversation, or the stream
    /// under both.
    ///
    /// **Whatever step the walk is standing on**, which is what the reader is looking at and
    /// what `j` and `k` walk. It used to ask about a person first and a conversation second,
    /// which was the layer order restated here; the walk answers it once and no surface decides
    /// it a second time. **No `default:`.**
    ///
    /// **Of the walk as the keys have it** (`keyed`): over a page that cannot be drawn, the
    /// stream drawn in its stead.
    private var currentListItems: [DummyItem] {
        // A tab of what is rising has no posts: its rows are hashtags and links (`currentListIDs`).
        guard risingInFront == nil else { return [] }
        return Self.listItems(on: keyedWalk, pages: people, stream: streamItems, latest: prefs.latestDate, in: session)
    }

    /// The posts of the list in front of `walk` — the walk as the keys have it (`keyed`) —
    /// with `stream` what the stream draws. Static so a check asks what the root walks.
    static func listItems(
        on walk: ShellWalk, pages people: ShellPersonPages, stream streamItems: @autoclosure () -> [DummyItem],
        latest: LatestDate?, in session: ShellSession
    ) -> [DummyItem] {
        switch walk.standing {
        case .person(let person):
            // What the page draws: the source's posts once it answered, what is held until then.
            return people.walked(of: person, in: session)
        case .tag(let tag):
            // Its posts, where they are in front: About's blocks are no posts (`currentListIDs`).
            guard people.tags.front(of: tag, in: session).listsPosts else { return [] }
            return session.heldPosts(under: tag, latest: latest)
        // A list of people has no posts: its rows are people, walked by who they are
        // (`currentListIDs`), and no mark of a post acts on one.
        case .people:
            return []
        // Nor has the page of what a search found, or the list of the hashtags the reader follows.
        case .found, .followedTags:
            return []
        case .thread(let opened):
            guard let item = session.held(opened) else { return streamItems() }
            return session.conversations.conversation(around: item).inOrder
        // A page read out of a post has no rows: nothing on it is walked with `j` and `k`, and
        // the list under it is not what the reader is looking at (#169).
        case .link:
            return []
        case nil:
            return streamItems()
        }
    }

    private var currentListIDs: [String]? {
        let rising = risingInFront.map { people.rising.walked($0, in: session) }
        // The stream's own ids where the stream is what is in front (#357): no walk a body pass.
        let stream = keyedWalk.standing == nil && searchItems == nil && rising == nil
        return Self.listIDs(
            on: keyedWalk, pages: people, found: foundRowIDs, items: currentListItems,
            drawn: stream ? session.timelineIDs(latest: prefs.latestDate) : nil, rising: rising, in: session
        )
    }

    /// The rows `j` and `k` walk on `walk` — the walk as the keys have it (`keyed`) — with
    /// `found` the rows of what the sources found over a search's posts and `items` the posts
    /// of the list in front (`listItems`) — or `drawn`, their ids as the drawn timeline holds
    /// them, where the stream is in front (#357) — or `rising`, the rows of the tab of Trends
    /// in front where it lists what is rising, with nothing walked over it. Nothing where there
    /// are none.
    static func listIDs(
        on walk: ShellWalk, pages people: ShellPersonPages, found: [String], items: [DummyItem],
        drawn: [String]? = nil, rising: [String]? = nil, in session: ShellSession
    ) -> [String]? {
        // On a list of people the rows are the people the source gave, as the page draws them;
        // on somebody's page the figures that open such a list stand over their posts (#311).
        let listed = walk.openedPeople.map { people.lists.walked($0, in: session) }
        let rising = walk.isEmpty ? rising : nil
        let foundTags = walk.openedFoundTags.map { people.found.walked($0, in: session) }
            ?? walk.openedFollowedTags.map { people.followed.walked($0, in: session) }
        let person = walk.openedPerson.map { people.walkedIDs(of: $0, in: session) }
        // On a hashtag's About the rows are its blocks (F10).
        let tagAbout = walk.openedTag.flatMap { people.tags.walkedAbout(of: $0, in: session) }
        let opened = listed ?? rising ?? foundTags ?? person ?? tagAbout
        // Over a search's posts stand the rows of what the sources found (#319).
        let posts = drawn ?? items.map(\.id)
        let ids = opened ?? (found.isEmpty ? posts : found + posts)
        return ids.isEmpty ? nil : ids
    }

    /// The walk as the keys have it — `j`, `k`, Return and a mark's key — where it stands on a
    /// step whose page cannot be drawn (`TimelinePane.drawn`): none, since the stream is drawn
    /// in its stead and is what the reader can move on. The walk itself where its page is drawn.
    /// **For every page alike**, as `drawnLayers` is for `r` and `stepTab` for Tab.
    static func keyed(_ walk: ShellWalk, drawn: Bool) -> ShellWalk {
        drawn ? walk : ShellWalk()
    }

    /// Whether the page of the step in front is drawn: `TimelinePane.drawn`, asked once here
    /// for the keys, `r` and Tab.
    private var standingDrawn: Bool {
        TimelinePane.drawn(walk.standing, of: people, in: session).drawn
    }

    /// Whether the search field is drawn under the timeline place: asked of what the pane stands
    /// on — beneath a page read out of a post — as its head is (`TimelinePane.searchFieldDrawn`).
    private var searchFieldDrawn: Bool {
        let beneath = walk.beneath
        let drawn = TimelinePane.drawn(beneath, of: people, in: session).drawn
        return TimelinePane.searchFieldDrawn(open: search.isOpen, over: beneath, drawn: drawn)
    }

    /// `keyed` of the walk now.
    private var keyedWalk: ShellWalk { Self.keyed(walk, drawn: standingDrawn) }

    /// **A press on the stream drawn in a step's stead acts from the stream** (`keyed`): the walk
    /// is let go of first — all of it, since a step under the one that cannot be drawn may be a
    /// page the reader is not looking at — so what the press opens is one step over the stream,
    /// and Back leaves it for the stream the reader saw. Nothing where the step in front is
    /// drawn. Called once the press is known to act, so a press that opens nothing moves nothing.
    private func leaveUndrawnWalk() {
        if Self.letsGoOfWalk(walk, drawn: standingDrawn) { clearWalk() }
    }

    /// Whether a press acting on what is drawn lets go of `walk` first (`leaveUndrawnWalk`):
    /// where the walk the keys have is not the walk itself (`keyed`).
    static func letsGoOfWalk(_ walk: ShellWalk, drawn: Bool) -> Bool {
        keyed(walk, drawn: drawn) != walk
    }

    /// The rows of what the sources found for the search in front, where its results are what
    /// the reader is looking at: none with no search, and none on a page opened over it — but
    /// over one that cannot be drawn, which draws them.
    private var foundRowIDs: [String] {
        Self.foundRows(on: keyedWalk, searching: search.isSearching, found: people.found.walked(for: search.pattern, in: session))
    }

    /// The rows of what the sources `found` that stand over a search's posts, on `walk` — the
    /// walk as the keys have it (`keyed`): all of them with nothing walked and a pattern
    /// searched, none otherwise. Static so a check asks what the root walks.
    static func foundRows(on walk: ShellWalk, searching: Bool, found: @autoclosure () -> [String]) -> [String] {
        walk.isEmpty && searching ? found() : []
    }

    /// Where the lamp lands when `j` first brings it onto somebody's page: their first post,
    /// under the figures (`ShellPersonPages.entry`) — and among a search's results the first
    /// post, under what the sources found. Nothing anywhere else.
    private var currentListEntry: String? {
        walk.openedPerson.flatMap { people.entry(of: $0, in: session) }
            ?? (foundRowIDs.isEmpty ? nil : streamItems.first?.id)
    }

    private func jumpListOrThreadToTop() -> Bool {
        Self.jumpedToTop(
            in: currentListIDs, standing: walk.standing, place: place,
            selected: &selectedItemID, jump: &jumpToTop
        )
    }

    /// `g`: the lamp on the first row of the list in front, and the list scrolled so that row
    /// is at the top. Static so a test presses the rule the root does, as `moved` is.
    ///
    /// **The first row `j` and `k` walk, in a conversation too.** A conversation is drawn as its
    /// ancestors, then the post it was opened from, then the answers — `DummyConversation.inOrder`,
    /// the same list `k` climbs — so its top is the first ancestor, or the opened post where
    /// there are none. It used to be the opened post always, which left every ancestor above
    /// where `g` landed and, with the opened post already lit, moved nothing at all.
    ///
    /// The jump is bumped even where the lamp is already on the first row: the rows may have
    /// been scrolled away from it, and the press is what brings them back. **No `default:`.**
    static func jumpedToTop(
        in rows: [String]?, standing: ShellStep?, place: ShellPlace,
        selected: inout String?, jump: inout Int
    ) -> Bool {
        guard place.isStream else { return false }
        switch standing {
        // A page read out of a post is somebody else's page, and its top is its own business.
        case .link:
            return false
        case .person, .tag, .people, .found, .followedTags, .thread, nil:
            guard let first = rows?.first else { return false }
            selected = first
        }
        jump += 1
        return true
    }

    /// `s` — the author's cover where there is one, the rest of the topic where there is not.
    ///
    /// **The acting half only.** Which of the two this press means is
    /// `DummyCommand.reveal(hasCover:repliesWanted:)` and is decided nowhere else; what is here is
    /// the three things to do about the answer, and the two facts the rule needs. Written this way
    /// so that the pane's mark and this key read one function rather than two agreeing `if`s —
    /// this branch's own arrangement for `a` and the card's play mark, stated in `playRow`.
    ///
    /// Everything about the cover is exactly as it was, including that it lands on the viewed post
    /// where the viewer is open: `onActedItem` is what makes `m`, `a` and `s` mean the same thing
    /// with the viewer up, and none of that moved. **No `default:`** — a fourth thing `s` could
    /// mean has to be given a line here.
    private func revealFocused() -> Bool {
        onActedItem { item in
            switch DummyCommand.reveal(
                hasCover: item.covered,
                repliesWanted: repliesWanted(of: item)
            ) {
            case .cover:
                // **Blurs in place and never navigates.** Not "toggle, and also close the viewer
                // if that leaves nothing to show" — a conditional rule inside the layer order is
                // the named risk, and the blur at size is what confirms the press took. Two
                // intents, two keys: `Escape` is still how a reader leaves.
                return decks.toggleCover(item.id)
            case .replies:
                guard let thread = ForumThreadRef(item) else { return false }
                // The replies, or the next page of them where they are drawn (#177).
                Task { await session.posts.press(thread) }
                return true
            case .nothing:
                return false
            }
        }
    }

    /// `b` and `f` — the post the lamp is on, boosted to the source it was read through or the
    /// boost taken back (#106), and favourited there or the favourite taken back (#107).
    ///
    /// **The acting half only.** Whether this post offers the act at all is `session.acts(on:)`,
    /// read here and by the mark under the post from the one place, so a key that acted where no
    /// mark is drawn — or a mark drawn over a key that refuses — cannot happen. A post that does
    /// not offer it moves nothing and says so, which is what leaves the press available to the
    /// platform.
    ///
    /// `onFocusedItem` and not `onActedItem`: the viewer is a picture over a post, and the post
    /// it is over is the one the lamp is on, so there is no second post for this key to mean.
    private func actFocused(_ act: PostAct) -> Bool {
        onFocusedItem { item in
            guard session.acts(on: item).offers(act) else { return false }
            Task { await session.toggle(act, on: item) }
            return true
        }
    }

    /// `w` — an answer to the post the lamp is on, written from inside its conversation (#108).
    ///
    /// **Only with a conversation in front**, because that is where the answer lands and where
    /// the post being answered is in its place; on the bare timeline, and on somebody's page even
    /// when it is open over a conversation, the key moves nothing and yields. The conversation is
    /// the walk's (#122) and its root is looked up among everything held, the pane's own lookup.
    /// Whether the post offers it is `session.openAnswer`'s one guard, the one the mark reads.
    private func answerFocused() -> Bool {
        guard let opened = walk.openedThread, let root = session.held(opened) else { return false }
        return onFocusedItem { item in
            session.openAnswer(to: item, in: root)
        }
    }

    /// Whether pressing for this post's replies could do anything at all.
    ///
    /// Three conditions, and each one is a real state rather than a guard written defensively.
    ///
    /// 1. **The pane is open on this very post.** The replies are drawn in `DummyThreadPane` and
    ///    nowhere else, so from the timeline `s` would put a page on the wire for something the
    ///    reader cannot see — work with no visible result, which is the fault the whole unit is
    ///    about. `Return` reads the first page of replies as the pane opens (#198); `s` there
    ///    asks it again where it did not arrive, and the next page after it.
    /// 2. **With no viewer over it.** `onActedItem` hands `s` the viewed post while the viewer is
    ///    up, and a fetch landing behind an opaque picture is the same invisible work one layer
    ///    further out. With the viewer open `s` keeps its one old meaning and nothing else.
    /// 3. **It is a Discuz! thread whose replies want asking for.** A Discourse topic and a
    ///    microblog post are both `nil` at `ForumThreadRef`, for the reason that type gives, and
    ///    `wantsPressing` is where "asking again could change the answer" already lives — and,
    ///    since #177, whether the next page of them could: a reply is no row the keys walk, so
    ///    `s` is how a reader on the keys reads a topic past its first page.
    ///
    /// **`standing(of:)` stamps interest, and that is fine here.** It is the same read the pane's
    /// body makes on every pass; stamping more often can only make an entry look *less* stale to
    /// the eviction predicate. What I8 forbids is a band that stops reading, not one read twice.
    private func repliesWanted(of item: DummyItem) -> Bool {
        guard place.isStream, viewedItem == nil, walk.openedThread == item.id,
              let thread = ForumThreadRef(item)
        else { return false }
        return session.posts.wantsPressing(thread)
    }

    /// Whether the reader may walk one step further out from where they are: `Return` and the
    /// press of a finger on a row that is its touch path (#33), and the press on a face or a
    /// name that opens somebody (#99). One expression, and now one for both steps.
    ///
    /// **Two names for one rule was how #122's gap was written down.** A conversation asked
    /// `canOpen(.thread,)` and a face asked `canOpen(.person,)`, and because those two layers
    /// were ordered against each other the first refused wherever the second had already been
    /// taken. They are one walk, so there is one guard: `DummyCommand.canWalk` reads the order
    /// out of `DummyLayer` once and asks only what stands in front of the pair.
    ///
    /// Nothing here is about *which* post or *which* person: the lamp is the key's business and
    /// a press carries its own id.
    static func canWalk(place: ShellPlace, open: Set<DummyLayer>) -> Bool {
        place.isStream && DummyCommand.canWalk(whenOpen: open)
    }

    /// A launch put where `staged` says, by the same functions a press goes through, so nothing
    /// is reached here that a reader could not reach: a place the rail has turned off is not
    /// entered, a row not held opens nothing, and the composer stays shut for a reader who may
    /// not write.
    ///
    /// **The place first, and the rest once the page has been drawn on it.** The first timeline
    /// being chosen is a timeline switched, which ends a walk (`timelineSwitched`), and that
    /// change is answered when the view is next drawn — after this would have opened the post.
    /// A wait and not a signal, because nothing says a view has answered its changes; it costs
    /// a picture a third of a second and a reader nothing, since no reader's launch comes here.
    private func arrive(at staged: ShellStaged) async {
        if let wanted = staged.place { place = availability.placing(place, as: wanted) }
        if let page = staged.preferences.flatMap(PreferencesPane.Purpose.init(rawValue:)) { session.preferencesPurpose = page }
        guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
        // **The steps first, and what is opened after them.** A step may change the timeline in
        // front, and that ends a walk: a post opened before the steps was shut again by them,
        // and every picture of an opened post since timelines were staged was of the list.
        for step in staged.steps {
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            take(step, of: staged)
        }
        if !staged.steps.isEmpty {
            guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
        }
        if let row = staged.opens { _ = openThread(row) }
        if staged.composing, availability.canCompose { composing = true }
        if let url = staged.reads { _ = linkReader.open(url) }
        if let host = staged.signsIn { session.signingIn = ForumSignInRequest(host: host, stop: .noCredential) }
        // Said again before it goes, for as long as the launch lasts.
        if let says = staged.says {
            for tick in 1... {
                session.toast = ShellToast(tick: -tick, text: says)
                guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            }
        }
    }

    /// Whether something is drawn over the shell in this same view (#305): the opened picture,
    /// the keys' guide, the landing. Every question, the composer, the editor, a sign-in, the
    /// list of timelines and a link read out of a post on a phone are sheets — views of their
    /// own, which a gesture on them never reaches the shell through.
    static func covered(viewing: Bool, shortcuts: Bool, landing: Bool) -> Bool {
        viewing || shortcuts || landing
    }

    /// One step of a staged launch, done as the person's own press or scroll would do it.
    private func take(_ step: ShellStaged.Step, of staged: ShellStaged) {
        switch step {
        case .scroll(let down): staged.scroll?(down)
        case .all: session.timelineID = .all
        case .trends: place = availability.placing(place, as: .trends)
        case .empty:
            if !session.written.contains(where: { $0.name == "Nobody" }),
               let nobody = Rule.author("@nobody@nowhere.example", in: .every, sources: []) {
                var draft = TimelineDraft(new: session.written.count + 1)
                draft.name = "Nobody"
                draft.rules = [nobody]
                draft.position = session.written.count
                session.commit(draft)
            }
            if let made = session.written.first(where: { $0.name == "Nobody" }) { session.timelineID = .written(made.id) }
        case .timelines:
            let host = session.sources.first?.host ?? ""
            let written: [(String, Rule?)] = [
                ("A timeline with a rather long name, to see where a long name goes", Rule.author("@ada@\(host)", in: .every, sources: [])),
                ("From a source that left", Rule.source("gone.example")),
                ("Lin", Rule.author("@lin@\(host)", in: .every, sources: [])),
            ]
            for (name, rule) in written {
                guard let rule else { continue }
                var draft = TimelineDraft(new: session.written.count + 1)
                draft.name = name
                draft.rules = [rule]
                draft.position = session.written.count
                session.commit(draft)
            }
            // Writing one puts it in front; the one that was in front is put back before
            // anything is drawn, so no timeline is switched to that nobody pressed for.
            session.goToTimeline(at: 0)
        case .go(let index): session.goToTimeline(at: index)
        case .list: session.timelineListShown = true
        case .unvisited: session.timelinePlaces = TimelinePlaces()
        case .reload: _ = reload()
        case .refused:
            if session.sources.count > 1 { session.rowRefusal = (host: session.sources[1].host, key: "account.bookmarks.failed") }
        case .slid(let page, let share):
            let slide = session.slide(page)
            slide.x = -CGFloat(share) * slide.width
            slide.lean = CGFloat(share)
        case .tabsList(let page): session.slide(page).listShown = true
        case .editor: session.newTimeline()
        case .usageNext:
            let tabs = Array(UsagePane.Purpose.allCases)
            if let to = TimelineSwipe.target(from: tabs.firstIndex(of: session.usagePurpose), count: tabs.count, step: 1) {
                session.usagePurpose = tabs[to]
            }
        case .next: session.stepTimeline(by: 1)
        case .previous: session.stepTimeline(by: -1)
        }
    }

    /// `Return`: the conversation around the post the lamp is on.
    private func openThread() -> Bool {
        guard let selectedItemID else { return false }
        return openThread(selectedItemID)
    }

    /// The same thing on the post a finger named — a press on a row, which is `Return`'s touch
    /// path (#33), and the one action a reader using VoiceOver activates a row with.
    ///
    /// **The lamp and the push happen here, in one turn, under one guard.** The pane used to
    /// write the selection and then call the no-argument half, which read that write back out of
    /// `@State` on the very next statement — true today, and where it is not, the root opens the
    /// post that *was* lit instead of the one pressed. An id in hand needs no such reading. The
    /// lamp moves only where the open is allowed, for `openViewer`'s reason: a press that can
    /// open nothing must not move anything either.
    private func openThread(_ id: String) -> Bool {
        // The walk as the keys have it: over a page that cannot be drawn, the row the lamp is on
        // is one of the stream drawn in its stead (`keyed`).
        let keyed = keyedWalk
        // On a tab of Trends that lists what is rising the row the lamp is on is a hashtag or a
        // link (#320).
        if let which = risingInFront {
            guard let listed = people.rising.row(id, of: which, in: session) else { return false }
            return openRisingRow(listed.row, lit: listed.id)
        }
        // Over a search's posts, and on the page of the hashtags it found, the row the lamp is
        // on may be what a source found (#319): Return opens it.
        if let page = keyed.openedFoundTags {
            guard let row = people.found.row(id, of: page, in: session) else { return false }
            return openFound(row)
        }
        if keyed.isEmpty, search.isSearching, let row = people.found.row(id, for: search.pattern, in: session) {
            return openFound(row)
        }
        // On the list of the hashtags followed the row the lamp is on is a hashtag (#318), and
        // on the reader's own page the lamp may be on the way to that list: Return opens each.
        if let page = keyed.openedFollowedTags {
            guard let row = people.followed.row(id, of: page, in: session) else { return false }
            return openRisingRow(row.listed)
        }
        // On About the lamp may be on the way to that list, or on another block that is a
        // press (F9): Return presses it, and does nothing on a block that is words.
        if let person = walk.openedPerson, people.front(of: person, in: session) == .about {
            if let entry = people.followedEntry(of: person, in: session), entry.id == id { return followedPressed(entry) }
            if id == RequestsEntry.id, let entry = people.requestsEntry(of: person, in: session) { return requestsPressed(entry) }
            if let entry = people.keepingEntries(of: person, in: session).first(where: { $0.id == id }) { return keepingPressed(entry) }
            if let press = people.featured(of: person, in: session)?.press(on: id) {
                return featuredPressed(press, from: id)
            }
            return people.pressAbout(id, of: person, in: session)
        }
        // On a hashtag's About the lamp is on a source's row: Return makes its press (F10).
        if let tag = walk.openedTag, !people.tags.front(of: tag, in: session).listsPosts {
            return people.tags.pressAbout(id, of: tag, in: session)
        }
        // On a list of people the row the lamp is on is somebody (#311): Return opens them.
        if let list = keyed.openedPeople {
            guard let person = people.lists.person(id, on: list, in: session) else { return false }
            return openListed(person)
        }
        // And on a tab of somebody's page that lists people (F9), the same: a new step, and
        // leaving it gives their page back on that tab, the lamp on that row.
        if let person = walk.openedPerson,
           let list = people.list(people.front(of: person, in: session), of: person, in: session)
        {
            guard let listed = people.lists.person(id, on: list, in: session) else { return false }
            return openListed(listed)
        }
        // A post read for somebody's page is no item until it is opened (#310): opening holds
        // it, and then opens it as any held post opens. One the store will not take opens nothing.
        if let person = walk.openedPerson, Self.canWalk(place: place, open: openLayers),
           people.isOnlyOnPage(id, of: person, in: session)
        {
            selectedItemID = id
            Task {
                guard await people.holding(id, of: person, in: session) != nil, walk.openedPerson == person else { return }
                _ = openThread(id)
            }
            return true
        }
        // A reblog opens the post it reblogs (#290), and one whose post is not held opens nothing.
        guard Self.canWalk(place: place, open: openLayers), let opened = session.rowOpened(by: id) else {
            return false
        }
        leaveUndrawnWalk()
        selectedItemID = id
        // A forum's ranked blog opens here too, and reads in the app (#209): its pane is a
        // thread's, with no replies under it, and its page is what that pane offers where the
        // blog could not be read. Leaving it gives back this row, as leaving a thread does.
        //
        // The lamp is read back after the press has moved it, which is how a conversation comes
        // back to its own opening post and a person's page comes back to the row the lamp was
        // on: one sentence for what used to be two. See `ShellWalk`.
        return walk.walk(to: .thread(opened), from: selectedItemID)
    }

    /// Whether `r` — and the mark in the header that is its touch path (#33) — has anything to
    /// ask for now.
    ///
    /// **One expression, two readers**, for the reason `canSearch` gives. It is the whole of the
    /// old guard, moved out of the acting half and given the arguments it used to read off a
    /// view, so both the key and the mark are answered by one function and a test can ask it.
    ///
    /// It says nothing about a reload already running: `r` pressed then is taken and does
    /// nothing, so the mark stays where it is rather than blinking out from under the finger
    /// that pressed it. What is on the wire is the bottom toast, not a plate on the mark.
    ///
    /// **No `default:`**, for `.back`'s reason: a sixth layer has to say what `r` does about it.
    ///
    /// **`risingAsked` is Trends on Hashtags or Links**, with nothing walked over it: whether
    /// the tab's sources may be asked again (`ShellRising.canAskAgain`) — and nothing on Posts
    /// and on the timeline, where the stream is what `r` asks for.
    ///
    /// **`tagAsked` is a hashtag's page in front**: whether any source of the timeline in front
    /// keeps tags, and so is asked for its posts under it (`ShellReload.tagReach`).
    static func canReload(
        place: ShellPlace, editing: Bool, hasSources: Bool, open: Set<DummyLayer>, personAsked: Bool = false,
        risingAsked: Bool? = nil, tagAsked: Bool = false
    ) -> Bool {
        guard place.isStream, !editing, hasSources else { return false }
        switch DummyCommand.outermost(of: open) {
        // A search's results are what this device holds, found without asking anybody.
        case .viewer, .shortcuts, .search: return false
        // **Nothing to ask for on the page of somebody whose source is not asked who people
        // are**: what is drawn there is what this device already holds. Where their source says
        // who they are (#310) the page is its word, and `r` asks it again.
        // And a list of people is its source's word too (#311): `r` asks it from the top.
        // And the hashtags followed are their source's word (#318): `r` asks it again.
        case .person, .people, .rising: return personAsked
        // A tag's page asks its sources as it opens (#124), and `r` asks them again (decision 11).
        case .tag: return tagAsked
        // A page read out of a post is not a timeline; there is nothing of ours on it to ask for.
        case .link: return false
        // And a tab of what is rising is its sources' word (#320): `r` asks them again.
        case .thread, .selection, nil: return risingAsked ?? true
        }
    }

    /// Whether the page in front is somebody's whose source says who people are.
    private var personAsked: Bool {
        if let list = walk.openedPeople { return people.lists.canAskAgain(list, in: session) }
        if let page = walk.openedFollowedTags { return people.followed.canAskAgain(page, in: session) }
        return walk.openedPerson.map { people.canAskAgain($0, in: session) } ?? false
    }

    /// Whether the hashtag's page in front has a source to ask: one of the timeline in front's
    /// that keeps tags. Nothing is worked out with no such page.
    private var tagAsked: Bool {
        guard walk.openedTag != nil else { return false }
        return !session.reload.tagReach(of: session.currentTimeline, in: session).asked.isEmpty
    }

    /// What is open, as far as what is drawn goes: a step in front whose page cannot be drawn
    /// (`TimelinePane.drawn`) is not, since the stream is drawn in its stead — so `r`, its mark
    /// and a pull answer for the stream there, as Tab does (`stepTab`), and the lamp enters the
    /// stream's rows as it would with no step (`keyed`). For every page alike.
    static func drawnLayers(_ open: Set<DummyLayer>, standing: ShellStep?, drawn: Bool) -> Set<DummyLayer> {
        guard !drawn, let standing else { return open }
        return open.subtracting([standing.layer])
    }

    /// `canReload` here and now: what `r`, the head's mark and a pull ask.
    private var canReloadNow: Bool {
        Self.canReload(
            place: place, editing: session.editing != nil, hasSources: !session.sources.isEmpty, open: drawnOpenLayers,
            personAsked: personAsked, risingAsked: risingInFront.map { people.rising.canAskAgain($0, in: session) },
            tagAsked: tagAsked
        )
    }

    /// `drawnLayers` of what is open now.
    private var drawnOpenLayers: Set<DummyLayer> {
        Self.drawnLayers(openLayers, standing: walk.standing, drawn: standingDrawn)
    }

    /// `Escape`'s stop on a stream place (decision 17): the ask of the page in front — somebody's
    /// page, a list, the hashtags followed, a hashtag's page, a tab of Trends that lists what is
    /// rising — and nothing under it; where the stream is in front, its reload, and a thread's
    /// next page on its way. **The pane's own decision of what is in front** (`TimelinePane.askInFront`), so
    /// `Escape` stops what the toast says and the mark stops. Whether anything was stopped.
    private func stopInFront() -> Bool {
        let rising = place == .trends ? trendsTab?.rising : nil
        if let front = TimelinePane.askInFront(walk.beneath, rising: rising, of: people, in: session) {
            return TimelinePane.stop(front, of: people, in: session)
        }
        return session.reload.stop() || session.stopReadingFurther()
    }

    /// `r`: the open thread, or else the selected timeline — and only on what the reader can see,
    /// so not under the viewer, the keys list or the timeline editor. A second press while the
    /// same one runs is taken and does nothing (`ShellReload.press`); Esc is what stops it.
    private func reload() -> Bool {
        if place == .notices { return readNotices() }
        let open = drawnOpenLayers
        guard canReloadNow else { return false }
        // On Hashtags or Links of Trends `r` asks every source of that tab again (#320).
        if let which = risingInFront {
            Task { await people.rising.again(which, in: session) }
            return true
        }
        // On somebody's page `r` asks their source again: who they are, and their newest posts.
        if DummyCommand.outermost(of: open) == .person, let person = walk.openedPerson {
            Task { await people.again(person, in: session) }
            return true
        }
        // On a list of people `r` asks the source for it again, from the top (#311).
        if DummyCommand.outermost(of: open) == .people, let list = walk.openedPeople {
            Task { await people.lists.again(list, in: session) }
            return true
        }
        // On the list of the hashtags followed `r` asks its source for it again, from the top (#318).
        if DummyCommand.outermost(of: open) == .rising, let page = walk.openedFollowedTags {
            Task { await people.followed.again(page, in: session) }
            return true
        }
        // On a hashtag's page `r` asks its sources again, of the timeline in front (decision 11).
        if DummyCommand.outermost(of: open) == .tag, let tag = walk.openedTag {
            let timeline = session.currentTimeline
            Task { await session.reload.tagAgain(tag, timeline: timeline, in: session) }
            return true
        }
        // The thread as `TimelinePane` draws it: one it cannot find draws the timeline instead.
        let opened = walk.openedThread.flatMap(session.held)
        session.reload.press(thread: opened, timeline: session.currentTimeline, in: session)
        return true
    }

    // MARK: - Notices — #323

    /// Whether the notices page is what the keys act on: it is in front, and nothing is drawn
    /// over it. The timeline's own layers are not on screen here (`escapeSees`), and its lamp
    /// is not this page's.
    static func noticesInFront(place: ShellPlace, open: Set<DummyLayer>) -> Bool {
        place == .notices && escapeSees(open, place: place).subtracting([.selection]).isEmpty
    }

    /// Whether `r` — and the page's reload mark, its touch path — has anybody to ask:
    /// `canReload`'s shape, for the page whose sources are those whose sign-in may read notices.
    static func canReadNotices(place: ShellPlace, open: Set<DummyLayer>, asked: Bool) -> Bool {
        noticesInFront(place: place, open: open) && asked
    }

    /// `r` on Notices: every source's newest stretch. A press while one is on the wire waits
    /// on that one and asks nothing twice (`ShellNoticeList.read`); Esc is what stops it.
    private func readNotices() -> Bool {
        guard Self.canReadNotices(
            place: place, open: openLayers, asked: !ShellNoticeList.asked(in: session).isEmpty
        ) else { return false }
        noticeTooOld = nil
        Task { await session.noticeList.acts.readPage(in: session) }
        return true
    }

    /// The lines `j` and `k` walk: what the page draws.
    private var shownNotices: [Notice] {
        session.noticeList.shown(hiding: prefs.noticesHidden)
    }

    private func moveInNotices(by step: Int) -> Bool {
        guard Self.noticesInFront(place: place, open: openLayers) else { return false }
        let moved = Self.noticesStep(
            in: shownNotices.map(\.id), from: noticeSelectedID, by: step,
            hasMore: session.noticeList.hasMore(in: session)
        )
        switch moved {
        case .lamp(let id):
            noticeSelectedID = id
        case .readOn:
            Task { await session.noticeList.readOn(in: session) }
        case .nothing:
            return false
        }
        return true
    }

    /// What `j` or `k` does on Notices.
    enum NoticesStep: Equatable {
        /// The lamp moves to this line.
        case lamp(String)
        /// Already on the last line, and older notices can be asked for: the keys' press on
        /// the foot.
        case readOn
        case nothing
    }

    /// The lamp walks the lines; **`j` pressed on the last one reads on**, one stretch a press.
    /// `hasMore` is `ShellNoticeList.hasMore`, which is false while a read is on the wire, so a
    /// key held down asks no faster than answers land. And where a stretch brought only kinds
    /// left out — the lamp has nowhere new to go — the next press reads on again.
    static func noticesStep(in ids: [String], from selected: String?, by step: Int, hasMore: Bool) -> NoticesStep {
        if step > 0, let selected, selected == ids.last { return hasMore ? .readOn : .nothing }
        if step > 0, ids.isEmpty { return hasMore ? .readOn : .nothing }
        guard let next = DummyCommand.stepped(ids, from: selected, by: step), next != selected else { return .nothing }
        return .lamp(next)
    }

    private func jumpNoticesToTop() -> Bool {
        guard Self.noticesInFront(place: place, open: openLayers), let first = shownNotices.first else { return false }
        noticeSelectedID = first.id
        noticeJump += 1
        return true
    }

    private var focusedNotice: Notice? {
        noticeSelectedID.flatMap { id in shownNotices.first { $0.id == id } }
    }

    /// `Return` on Notices: what the line the lamp is on is about.
    private func openFocusedNotice() -> Bool {
        focusedNotice.map(openNotice) ?? false
    }

    /// `p` on Notices: whoever the line the lamp is on names first.
    private func openFocusedNoticePerson() -> Bool {
        guard let notice = focusedNotice, let person = notice.firstPerson else { return false }
        return openNoticePerson(person, of: notice)
    }

    /// `d` on the notices page: asks to dismiss the line the lamp is on, as its `…` asks.
    private func dismissFocusedNotice() -> Bool {
        guard Self.noticesInFront(place: place, open: openLayers), let notice = focusedNotice else { return false }
        return NoticeActs.askToDismiss(notice, in: session)
    }

    /// A line opened: its post in its conversation, or the person — a step of the timeline
    /// place's walk, come back from by leaving it. A line that is only words opens nothing.
    private func openNotice(_ notice: Notice) -> Bool {
        guard Self.noticesInFront(place: place, open: openLayers) else { return false }
        switch NoticeWords.opens(notice) {
        case .nothing:
            return false
        case .person(let person):
            return openNoticePerson(person, of: notice)
        case .post(let post):
            Task { await openNoticePost(post, of: notice) }
            return true
        }
    }

    /// A face or a name on a line, pressed: that person, as a face on a post's row opens them.
    private func openNoticePerson(_ person: DummyPerson, of notice: Notice) -> Bool {
        guard Self.noticesInFront(place: place, open: openLayers) else { return false }
        return setOutFromNotices(to: .person(person), for: notice, lighting: nil)
    }

    /// The post is held first, as a thread's posts are, and the conversation opens from what is
    /// held. One the store would not take — older than the person keeps — is said on its line.
    private func openNoticePost(_ post: Note, of notice: Notice) async {
        guard let row = await session.landed(noticePost: post) else {
            noticeTooOld = notice.id
            return
        }
        // The reader went elsewhere while the store answered: nothing is opened under them.
        guard Self.noticesInFront(place: place, open: openLayers) else { return }
        _ = setOutFromNotices(to: .thread(row), for: notice, lighting: row)
    }

    /// The step itself: the walk takes it keeping the timeline's own lamp to hand back, the
    /// page remembers which line it left by, and the timeline place comes in front.
    private func setOutFromNotices(to step: ShellStep, for notice: Notice, lighting row: String?) -> Bool {
        guard availability.allows(.timeline) else { return false }
        noticeTooOld = nil
        // The timeline's walk takes the step, whichever stream was followed last.
        follow(.timeline)
        errand = PlaceErrand.setOut(to: step, from: .notices, line: notice.id, on: &walk, lamp: selectedItemID)
        if let row { selectedItemID = row }
        place = .timeline
        return true
    }

    /// Leaving the last step such a walk took puts the reader back on the place they pressed —
    /// and on Notices, on the line they pressed: lit with a keyboard or a pointer, marked and at
    /// the top under a finger.
    private func returnFromErrand() {
        guard let left = errand, left.isOver(walk) else { return }
        errand = nil
        if left.from == .notices, let line = left.line {
            noticeMark.keep(line)
            if !ShellHands.shared.touch { noticeSelectedID = line }
        }
        place = left.from
    }

    // MARK: - A hashtag — #124

    /// A hashtag pressed in a post's words: what this device holds under it, over whatever it was
    /// pressed on, and its sources asked for more.
    ///
    /// **The row the press was made on is lit first**, so the walk remembers that row and leaving
    /// gives it back — the post the press was made from, on its row. A face does not do this,
    /// because a face is not a post; the words a tag is written in are. Words that stand on no
    /// row leave the lamp where it is.
    private func openTag(_ tag: PostTag, from row: String?) -> Bool {
        guard Self.canWalk(place: place, open: openLayers),
              Self.opensAnew(tag, standing: walk.openedTag)
        else { return false }
        // Refused before anything moves, as `openThread` is: a press that opens nothing leaves
        // the lamp where it was.
        let lamp = row ?? selectedItemID
        leaveUndrawnWalk()
        guard walk.walk(to: .tag(tag), from: lamp) else { return false }
        selectedItemID = lamp
        let timeline = session.currentTimeline
        Task {
            // Asked only while this is still the page in front: a press answered after the page
            // was left, or another tag opened, asks for nothing nobody is reading.
            guard walk.openedTag == tag else { return }
            await session.reload.tag(tag, timeline: timeline, in: session)
        }
        return true
    }

    /// Whether pressing `tag` opens a page, where `standing` is the tag whose page is in front:
    /// `#SWIFT` pressed on `#Swift`'s page is the page already open (#124).
    static func opensAnew(_ tag: PostTag, standing: PostTag?) -> Bool {
        standing.map { !HeldUnderTag.same($0, tag) } ?? true
    }

    /// `t` — a hashtag of the post the lamp is on (#124): the press a finger makes on its pill,
    /// from the keyboard. The first the post carries that is not the page already in front, so on
    /// a tag's page `t` goes on to the post's other tag rather than standing still. Refused where
    /// the post is covered and its words are not drawn, as its pills are not.
    private func openTagFocused() -> Bool {
        guard Self.canWalk(place: place, open: openLayers) else { return false }
        return onFocusedItem { item in
            guard let tag = Self.tagToOpen(in: item, lifted: decks.isLifted(item.id), standing: walk.openedTag)
            else { return false }
            return openTag(tag, from: item.id)
        }
    }

    /// Which of a post's tags `t` opens, given whether its cover is lifted and the tag in front.
    static func tagToOpen(in item: DummyItem, lifted: Bool, standing: PostTag?) -> PostTag? {
        guard !item.covered || lifted else { return nil }
        return PostTag.found(in: item.body).first { tag in
            standing.map { !HeldUnderTag.same($0, tag) } ?? true
        }
    }

    // MARK: - Somebody mentioned — #310

    /// A mention's press, answered by the walk: set once, before anything can be pressed.
    private func placeMentions() {
        mentions.placing = { handle, host, row in openMentioned(handle, at: host, from: row) }
    }

    /// Somebody mentioned in a post's words, pressed: their page at the source the words were
    /// read through, one more step of the walk — the page a face on a row of theirs opens.
    ///
    /// **The row the press was made on is lit first**, as a hashtag's is (`openTag`): the words
    /// are a post's, so leaving the page gives that post back.
    private func openMentioned(_ handle: String, at host: String, from row: String?) -> Bool {
        guard Self.canWalk(place: place, open: openLayers),
              let lamp = Self.walkToMentioned(handle, at: host, from: row ?? selectedItemID, on: &walk)
        else { return false }
        selectedItemID = lamp.row
        return true
    }

    /// The step onto the page of whoever `handle` names at `host`, remembering `row` as the lamp
    /// to give back: the row the lamp goes to now, or nothing where there is no step to take —
    /// no handle, or their page already in front. Static, so a test can walk it without a window.
    static func walkToMentioned(
        _ handle: String, at host: String, from row: String?, on walk: inout ShellWalk
    ) -> (row: String?, who: DummyPerson)? {
        guard let who = DummyPerson(handle: handle, host: host), walk.walk(to: .person(who), from: row)
        else { return nil }
        return (row, who)
    }

    /// The pages open over the timeline as the session is handed them (#359): every step of
    /// the walk, the search, and the latest date the timeline is drawn to.
    private var openPages: OpenPages {
        OpenPages(
            // Both stream places' steps: a page left open under Trends is still open (#359).
            steps: Self.openSteps(sides), searching: search.isOpen, pattern: search.pattern, indexed: search.isIndexed,
            latest: prefs.latestDate
        )
    }

    // MARK: - A quoted post — #214

    /// The quote's press and `o`, answered by the walk: set once, before anything can be pressed.
    private func placeQuotes() {
        quotes.opening = { item in openQuote(of: item) }
        quotes.target = { item in session.quotedRow(of: item) }
    }

    /// The post `item` quotes, opened as a post of its own over whatever it was quoted on.
    ///
    /// **The quoting post is the lamp the step remembers**, so leaving the quoted post gives back
    /// the post that quoted it — on the timeline, in its thread, or wherever it was pressed. Refused
    /// before anything moves, as `openThread` is: a quote that may not be shown, or one this device
    /// holds nothing of, opens nothing and leaves the lamp where it was.
    private func openQuote(of item: DummyItem) -> Bool {
        guard Self.canWalk(place: place, open: openLayers),
              let lamp = Self.walkToQuote(from: item, quoted: session.quotedRow(of: item), on: &walk)
        else { return false }
        selectedItemID = lamp
        return true
    }

    /// The step onto the quoted post, remembering the quoting post as the lamp to give back: the
    /// row the lamp goes to now, or nothing where there is no step to take. Static, so a test can
    /// walk it without a window.
    static func walkToQuote(from item: DummyItem, quoted: String?, on walk: inout ShellWalk) -> String? {
        guard let quoted, walk.walk(to: .thread(quoted), from: item.id) else { return nil }
        return quoted
    }

    // MARK: - Whoever wrote it — #99

    /// A press on a face or a name: that person's page, over whatever is under it.
    ///
    /// **A named method, not a closure written into the pane's call site.** Three controls in
    /// this milestone were wired inside a `View` body where no test could call them, and all
    /// three stayed green while doing the wrong thing. This is the guard and the act together,
    /// where a test can press it.
    ///
    /// The lamp is not moved. A face is not a row, so pressing one says nothing about which post
    /// the reader is standing on, and the walk keeps that row to hand back when the page is left.
    private func openPerson(_ person: DummyPerson) -> Bool {
        guard Self.canWalk(place: place, open: openLayers) else { return false }
        leaveUndrawnWalk()
        return walk.walk(to: .person(person), from: selectedItemID)
    }

    /// The way to the people who ask to follow the reader, pressed on their own page (#313):
    /// the list, one more step of the walk — or, where the line is the lock of a sign-in that
    /// does not see who follows them and may be asked, the question that asks it.
    private func requestsPressed(_ entry: RequestsEntry) -> Bool {
        guard entry.locked == nil else {
            guard entry.asks else { return false }
            session.askFor([.follows], host: entry.list.host)
            return true
        }
        // Left, the list gives the line back: the lamp is on it again, and nothing in the list is lit.
        guard Self.canWalk(place: place, open: openLayers), walk.walk(to: .people(entry.list), from: RequestsEntry.id)
        else { return false }
        selectedItemID = nil
        return true
    }

    /// A way to whom the reader mutes or blocks, pressed on their own page (#314): the list, one
    /// more step of the walk; the servers they block, on their sheet — or, where the line is the
    /// lock of a sign-in that does not see them and may be asked, the question that asks it.
    private func keepingPressed(_ entry: KeepingEntry) -> Bool {
        guard entry.locked == nil else {
            guard entry.asks else { return false }
            session.askFor([.blocks], host: entry.host)
            return true
        }
        guard let list = entry.list else {
            Task { await people.servers.show(entry.host, in: session) }
            return true
        }
        guard Self.canWalk(place: place, open: openLayers), walk.walk(to: .people(list), from: entry.id) else { return false }
        selectedItemID = nil
        return true
    }

    /// What somebody features, pressed on About of their page (#315, #318): the hashtag's page,
    /// or the list of the people they feature — one more step of the walk, from the row the
    /// lamp is on, or from the row pressed (`from`), which is lit first so leaving gives it back.
    private func featuredPressed(_ press: FeaturedPress, from row: String?) -> Bool {
        switch press {
        case .tag(let tag):
            let before = selectedItemID, lamp = row ?? FeaturedSaid.lamp(of: tag)
            selectedItemID = lamp
            let opened = openTag(tag, from: lamp)
            if !opened { selectedItemID = before }
            return opened
        case .people(let list):
            guard Self.canWalk(place: place, open: openLayers), walk.walk(to: .people(list), from: row ?? FeaturedSaid.peopleID)
            else { return false }
            selectedItemID = nil
            return true
        case .takeOff:
            return false
        }
    }

    /// A row of such a list opened: that person's page. **The lamp and the step in one turn**,
    /// as a post's row opens (`openThread`): the row is lit and is what the walk remembers, so
    /// leaving their page gives it back — under a finger too, where nothing was lit before.
    private func openListed(_ person: Person) -> Bool {
        guard Self.canWalk(place: place, open: openLayers) else { return false }
        leaveUndrawnWalk()
        selectedItemID = person.id
        return walk.walk(to: .person(DummyPerson(person)), from: person.id)
    }

    // MARK: - What is rising — #320

    /// `h`: Trends in front, from any place (decision 7), on the tab and the walk it was left
    /// with (decision 18). Not where there is no Trends, and not under what is drawn over the
    /// shell (`opensTrends`); never in a text field, where the key is the field's.
    private func openTrends() -> Bool {
        guard Self.opensTrends(availability, open: openLayers) else { return false }
        place = .trends
        return true
    }

    /// Whether `h` brings Trends in front: some source has it, and neither the picture opened
    /// nor the keys' guide is over the shell. Static so a test asks the rule the key does.
    static func opensTrends(_ availability: ShellAvailability, open: Set<DummyLayer>) -> Bool {
        availability.allows(.trends) && open.isDisjoint(with: [.viewer, .shortcuts])
    }

    /// The tabs Trends has, and the one drawn in front of them (`TrendsTab.front`).
    private var trendsTabs: [TrendsTab] { availability.trendsTabs }
    private var trendsTab: TrendsTab? { TrendsTab.front(trendsFront.tab, among: trendsTabs) }

    /// What Trends' tab in front lists of what is rising, where the keys have that tab: Trends
    /// in front, on Hashtags or Links, with no step walked over it that is drawn. Nothing on
    /// Posts and everywhere else.
    private var risingInFront: RisingWhich? {
        guard place == .trends, keyedWalk.isEmpty else { return nil }
        return trendsTab?.rising
    }

    /// A tab of Trends pressed, swiped or keyed to (decision 2): brought in front, each tab
    /// keeping its own lamp. A search over Posts closes first — it is Posts' — and a step that
    /// cannot be drawn is let go of, as any press on what is drawn lets go of it.
    private func turnTrends(to tab: TrendsTab) -> Bool {
        settleTrendsFront(among: trendsTabs)
        guard session.stream == .trends, trendsTab != tab, trendsTabs.contains(tab) else { return false }
        if search.isOpen { closeSearch() }
        leaveUndrawnWalk()
        var turning = trendsFront
        let turned = TrendsTab.turned(
            &turning.tab, to: tab, among: trendsTabs, rows: trendsRows(of: tab) ?? [], lamps: &turning.lamps, lamp: &selectedItemID
        )
        trendsFront = turning
        return turned
    }

    /// The rows `tab` of Trends walks: what is rising of its kind, or on Posts the stream's —
    /// nothing to be had where the session follows the timeline, whose stream is not Posts.
    private func trendsRows(of tab: TrendsTab) -> [String]? {
        if let which = tab.rising { return people.rising.walked(which, in: session) }
        return session.stream == .trends ? session.timelineIDs(latest: prefs.latestDate) : nil
    }

    /// The tab of Trends in front, brought to the one left where no source has it any more
    /// (`TrendsFront.fell`): its lamp kept, and the lamp the tab fallen to was left with given
    /// back — where Trends' walk is empty, so the lamp is the tab's and not a step's.
    private func settleTrendsFront(among tabs: [TrendsTab]) {
        var front = trendsFront
        if sides[.trends].walk.isEmpty {
            var lamp = sides[.trends].lamp
            guard front.fell(among: tabs, lamp: &lamp, rows: trendsRows) else { return }
            sides[.trends].lamp = lamp
        } else {
            var kept: String?
            guard front.fell(among: tabs, lamp: &kept, rows: trendsRows) else { return }
        }
        trendsFront = front
    }

    /// Tab and ⇧Tab on Trends with nothing walked: its tabs round their ring, taken with one
    /// tab, and nobody's under the picture opened (`TrendsTab.keyed`).
    private func rotateTrendsTab(by step: Int) -> Bool {
        guard let front = trendsTab else { return false }
        switch TrendsTab.keyed(trendsTabs, front: front, by: step, covered: openLayers.contains(.viewer)) {
        case .turn(let tab):
            _ = turnTrends(to: tab)
            return true
        case .taken: return true
        case .unheard: return false
        }
    }

    /// What the pane is handed of Trends' tabs.
    private var trendsHead: TrendsHead {
        Self.trendsHead(tabs: trendsTabs, kept: trendsFront.tab, onTurn: trendsTurned)
    }

    /// Trends' head for the `tabs` it has, with `kept` the tab left in front: the one drawn is
    /// that one, or the first left where no source has it any more (`TrendsTab.front`).
    static func trendsHead(tabs: [TrendsTab], kept: TrendsTab, onTurn: @escaping (TrendsTab) -> Void) -> TrendsHead {
        TrendsHead(tabs: tabs, front: TrendsTab.front(kept, among: tabs) ?? .posts, onTurn: onTurn)
    }

    /// `turnTrends`, as the pane hands a tab over: whether it turned is nobody's to read there.
    private func trendsTurned(_ tab: TrendsTab) {
        _ = turnTrends(to: tab)
    }

    /// The session made to follow `stream` (DESIGN-trends, option C): the row at the top of the
    /// list left is kept on its side, and the stretch round where it was left kept to be drawn
    /// at once on the way back (#359), as a timeline switched keeps it. Nothing where it is the
    /// stream followed already.
    ///
    /// **A page read out of a post is left with the stream it was read over** (`StreamSides.
    /// follow`): there is one reader, drawn over the stream followed, so its step is taken back
    /// and the reader closed — a link opened on the timeline is not drawn over Trends, nor left
    /// a step nobody can leave there. Every other step of each walk stays as it was.
    private func follow(_ stream: ShellStream) {
        if Self.follow(stream, sides: &sides, in: session) { linkReader.close() }
    }

    /// `follow`'s sides and session, given what it reads, so a test takes the step the root
    /// takes. Whether a page read out of a post was left, for the reader to be closed.
    static func follow(_ stream: ShellStream, sides: inout StreamSides, in session: ShellSession) -> Bool {
        let from = session.stream
        guard stream != from else { return false }
        let top = session.scrolledTop
        session.timelineLeft(session.currentTimeline, at: sides[from].lamp ?? top)
        let followed = sides.follow(from: from, to: stream, top: top)
        session.stream = stream
        session.scrolledTop = followed.top
        return followed.leftLink
    }

    /// `l`: follows whoever's page is in front, or the hashtag whose page is. Where the key
    /// answers, and what it then does, is the pages' own (`ShellPersonPages.followByKey`).
    private func followByKey() -> Bool {
        people.followByKey(
            place: place, open: openLayers, person: walk.openedPerson, tag: walk.openedTag, in: session
        )
    }

    /// A row of such a page opened, lit as `lit` where the list it stands on calls it that —
    /// Trends' one list, whose row is of no source (`RisingListed`). **The lamp and the step in
    /// one turn**, as a post's row opens: a hashtag is the page a hashtag pressed in a post's
    /// words opens, and a link goes through the door a post's link goes through, listed under
    /// the source that named it — on Trends, the first to.
    private func openRisingRow(_ row: RisingRow, lit: String? = nil) -> Bool {
        guard Self.canWalk(place: place, open: openLayers) else { return false }
        // Lit first, so the step taken remembers this row — and put back where nothing opened.
        let before = selectedItemID
        let id = lit ?? row.id
        selectedItemID = id
        let opened: Bool
        switch row {
        case .tag(let tag, _): opened = openTag(tag.tag, from: id)
        case .link(let link, let source): opened = linkReader.open(link.link.url, from: source)
        }
        selectedItemID = ShellRising.lamp(after: opened, of: id, before: before)
        return opened
    }

    /// The way to the hashtags the reader follows, pressed on their own page (#318): the list,
    /// one more step of the walk with its line lit — or, where the line is a lock, the question
    /// that asks the sign-in for who the reader follows, and no step.
    private func followedPressed(_ entry: FollowedTagsEntry) -> Bool {
        if entry.locked != nil { return entry.asks && session.askFor([.follows], host: entry.page.host) }
        guard Self.canWalk(place: place, open: openLayers) else { return false }
        return walk.open(entry.page, lamp: &selectedItemID)
    }

    // MARK: - What a search found at the sources — #319

    /// A row of what a source found, opened. **The lamp and the step in one turn**, as every
    /// row opens: somebody's page, a hashtag's page, or the page of what that source found on
    /// the tab of the kind pressed for (F10) — so leaving it gives the press back.
    private func openFound(_ row: SearchFoundRow) -> Bool {
        switch row {
        case .person(let person):
            return openListed(person)
        case .tag(let tag, _):
            guard Self.canWalk(place: place, open: openLayers) else { return false }
            let before = selectedItemID
            selectedItemID = row.id
            let opened = openTag(tag.tag, from: row.id)
            if !opened { selectedItemID = before }
            return opened
        case .allPeople, .allTags:
            guard Self.canWalk(place: place, open: openLayers), let step = people.found.step(opening: row, in: session)
            else { return false }
            leaveUndrawnWalk()
            guard walk.walk(to: step, from: row.id) else { return false }
            selectedItemID = row.id
            return true
        }
    }

    /// A tab of that page pressed or swiped to: the step turned in place, no step more (F10).
    private func foundTurned(_ which: FoundWhich) {
        people.found.turn(&walk, to: which, lamp: &selectedItemID, in: session)
    }

    /// The press about looking somebody up through a source: the source asked, or the page of
    /// whoever it found opened — asked again where that is the page already in front.
    private func lookUpPressed(_ press: SearchLookUpLine.Press) {
        switch press {
        case .lookUp(let address, let host):
            let found = people.found
            Task { await found.lookUp(address, through: host, in: session) }
        case .open(let person):
            let who = DummyPerson(person)
            if let standing = walk.openedPerson, ShellSearchFound.isThePage(standing, of: person) {
                Task { await people.again(standing, in: session) }
            } else {
                _ = openPerson(who)
            }
        }
    }

    /// "Your page there" on Account, and "Signed in as …" on a source's page: the signed-in
    /// reader's own page at that source — anybody's page, opened for their own account (#310).
    ///
    /// **Set out as a notice's line sets out** where the press was made on another place: the
    /// page is drawn in the timeline place, the walk takes the step keeping the timeline's own
    /// lamp to hand back, and leaving the step comes back to the place pressed. On the timeline
    /// place it is a face pressed, and nothing more.
    private func openOwnPage(_ me: DummyPerson) {
        setOut(to: .person(me))
    }

    /// "Its directory of people" on a source's page (#315): the directory, set out to as the
    /// reader's own page is.
    private var directoryOpener: ((PeopleList) -> Void)? {
        guard availability.allows(.timeline) else { return nil }
        return { list in setOut(to: .people(list)) }
    }

    /// One step taken from a source's page or from Account: on the timeline place a step like
    /// any other, keeping the lamp to hand back; from another place an errand (`PlaceErrand`).
    private func setOut(to step: ShellStep) {
        guard !place.isStream else {
            if Self.canWalk(place: place, open: openLayers) { _ = walk.walk(to: step, from: selectedItemID) }
            return
        }
        guard availability.allows(.timeline) else { return }
        // The timeline's walk takes the step, whichever stream was followed last.
        follow(.timeline)
        errand = PlaceErrand.setOut(to: step, from: place, on: &walk, lamp: selectedItemID)
        place = .timeline
    }

    /// What the entries to the reader's own page press, or nothing where the timeline place —
    /// the one place a page is drawn — cannot be entered: **the entries are then not drawn**, so
    /// no press takes a sheet down and then opens nothing.
    private var ownPageOpener: ((DummyPerson) -> Void)? {
        guard availability.allows(.timeline) else { return nil }
        return { me in openOwnPage(me) }
    }

    /// `p` — whoever wrote the post the lamp is on (#140). The face's own press, from the keyboard.
    ///
    /// **Through `openPerson` and not beside it**, so the key and the face are one act with one
    /// guard: the walk remembers the row the lamp is on, and leaving by `Escape` or `q` gives it
    /// back exactly as leaving a page opened by a finger does.
    ///
    /// The guard is asked before `onFocusedItem`, for `openViewer`'s reason: a press that is about
    /// to be refused must not light the first row on its way to refusing. On somebody's own page
    /// that is the whole of the answer — nothing moves, nothing is said, and the letter is still
    /// ours (`DummyCommand.consumes`), so it does not fall through to the platform as a beep. A
    /// row that names nobody (`DummyPerson(_:)` is nil) is refused the same way its face is:
    /// there is no page to open, so there is no press.
    private func openAuthor() -> Bool {
        guard Self.canOpenAuthor(place: place, open: openLayers) else { return false }
        return onFocusedItem { item in
            guard let person = DummyPerson(item) else { return false }
            return openPerson(person)
        }
    }

    /// Whether `p` has anybody to open now: `canWalk`'s place, and `DummyCommand.canOpenAuthor`'s
    /// order. Static and given its inputs, for `canWalk`'s reason.
    static func canOpenAuthor(place: ShellPlace, open: Set<DummyLayer>) -> Bool {
        place.isStream && DummyCommand.canOpenAuthor(whenOpen: open)
    }

    /// One step back out of the walk: whatever the reader took that step from is what they get
    /// back, standing on the row they took it from.
    ///
    /// **One method for both kinds of step**, which is #122's whole shape. Leaving a person used
    /// to restore a lamp kept in a second piece of state and leaving a conversation used to
    /// restore the post it was opened from, and because they were two methods a walk that
    /// alternated between them could not unwind in the order it was walked.
    private func leaveWalk() -> Bool {
        guard let left = walk.back() else { return false }
        // The page read out of a post goes with its step, and the page under it — never torn
        // down — is simply in front again (#169).
        if case .link = left.step { linkReader.close() }
        // A tag's ask goes with its page (#124).
        if case .tag = left.step { session.reload.endTag() }
        // What a list of the hashtags followed was told goes with its step (#318).
        if case .followedTags(let page) = left.step { people.followed.closed(page) }
        // The tab in front of somebody's page goes with its last step (F9, decided 2026-10-13) —
        // on either stream place's walk.
        people.left(left.step, of: walk, besides: sides[session.stream.other].walk)
        // A hashtag met twice in one walk is one page, on the tab it was left on: a row its
        // first step was taken from may not be one of the tab now in front.
        selectedItemID = Self.lampBack(left.lamp, onto: walk.standing, rows: currentListIDs)
        returnFromErrand()
        return true
    }

    /// The lamp a step left hands back, as the page come back to takes it: on a hashtag's page
    /// only a row of the tab in front — `rows` — and no lamp otherwise; everywhere else as the
    /// walk kept it.
    static func lampBack(_ lamp: String?, onto standing: ShellStep?, rows: [String]?) -> String? {
        guard case .tag = standing else { return lamp }
        return TagTab.lamp(lamp, among: rows ?? [])
    }

    /// The lamp of a hashtag's page whose timeline changed under it (#197), given what the
    /// timeline now in front holds under the tag: a post it no longer shows is put out, and
    /// **a block of About is left lit** — About is not the timeline's.
    static func lampOverSwitch(_ lamp: String?, aboutInFront: Bool, held: [String]) -> String? {
        aboutInFront ? lamp : TagTab.lamp(lamp, among: held)
    }

    /// The Back on a page read out of a post: one step back out of the walk, which is that page
    /// wherever the Back can be pressed (#169).
    private func leaveLink() {
        guard walk.openedLink != nil else { return }
        _ = leaveWalk()
    }

    /// A timeline switched: the walk ends, unless a tag's page is in front — that stays, and asks
    /// the sources of the timeline now in front (#197). `tagSwitched` asks nothing of a timeline
    /// already switched away from by the time it runs.
    ///
    /// **Nothing on a tag's page switches a timeline any more** (F10): Tab is the page's own,
    /// and the timelines' names are not drawn over it. This is kept for the switches that are
    /// nobody's press there — the timeline in front removed with its last source, a launch
    /// staged — where a page asked of a timeline that is gone would say what is no longer so.
    ///
    /// **The places are this handler's, whole, where the page stays**, and `TimelinePane` leaves
    /// them alone while it stands on a tag: two handlers of one change, each writing the lamp,
    /// would answer by whichever ran last. The lamp stays on the page's row where the page still
    /// shows it under the new timeline's rules, and goes out where it does not.
    private func timelineSwitched(from left: TimelineQuery?, to arrived: TimelineQuery?) {
        // The list a notice's walk stood on is replaced: there is no step left to come back by.
        errand = nil
        // Switched under Trends — the timeline in front removed with its last source — the
        // timeline's walk ends where it is kept, and Trends' is not the timeline's to end.
        guard session.stream == .timeline else {
            return letGo(Self.timelineSwitchedUnderTrends(&sides, tagAsk: session.reload.tagAsk?.timeline))
        }
        let hadLink = walk.openedLink != nil
        let lists = walk.followedTags
        guard let tag = Self.timelineSwitched(
            on: &walk, places: &session.timelinePlaces, from: left, to: arrived,
            shown: session.timelineItems(latest: prefs.latestDate).map(\.id),
            results: session.searched(search, latest: prefs.latestDate)?.map(\.id)
        ) else { return clearWalk() }
        if hadLink { linkReader.close() }
        for page in lists { people.followed.closed(page) }
        // Only the tag's page is left of the walk: no person's page is in it any more, and no
        // other hashtag's — but those still on Trends' walk.
        people.leftAll(keeping: tag, besides: sides[.trends].walk)
        let held = session.heldPosts(under: tag, latest: prefs.latestDate).map(\.id)
        let lamp = Self.lampOverSwitch(selectedItemID, aboutInFront: !people.tags.front(of: tag, in: session).listsPosts, held: held)
        if lamp != selectedItemID { selectedItemID = lamp }
        // And the lamp its Posts were left with, where About is in front, by the same rule.
        people.tags.timelineSwitched(under: tag, held: held)
        let timeline = session.currentTimeline
        Task { await session.reload.tagSwitched(to: timeline, in: session) }
    }

    /// `timelineSwitched`'s walk and places, given what it reads, so a test takes the step the
    /// root takes. With a search open the row under the page is a result, and the timeline's place
    /// is the search's parked post, which `TimelinePane` files (#145): the row is kept where the
    /// new timeline's `results` still hold it, and goes out where they do not. `results` is
    /// nothing with no search open.
    static func timelineSwitched(
        on walk: inout ShellWalk, places: inout TimelinePlaces,
        from left: TimelineQuery?, to arrived: TimelineQuery?, shown: [String], results: [String]?
    ) -> PostTag? {
        walk.timelineSwitched { lamp in
            guard let results else {
                return places.switched(from: left, to: arrived, standingOn: lamp, among: shown)
            }
            return lamp.flatMap { results.contains($0) ? $0 : nil }
        }
    }

    /// Back to the stream in one go, for a list that has been replaced. A page read out of a post
    /// that was one of the steps goes with them: nothing is left for it to be drawn in place of,
    /// and a reading left open would be presented as a sheet instead.
    ///
    /// **Of one stream place's walk** — the one followed, unless `side` names the other — and
    /// what is kept of a page that is still a step of the other's stays.
    private func clearWalk(_ side: ShellStream? = nil) {
        letGo(Self.cleared(side ?? session.stream, sides: &sides, tagAsk: session.reload.tagAsk?.timeline))
    }

    /// What a walk ended in one go owes, beyond its side's steps: worked out where the sides are
    /// (`cleared`), done here where the reader, the asks and the pages are.
    struct Cleared: Equatable {
        let side: ShellStream
        /// A page read out of a post was one of its steps: the reader is closed.
        var leftLink = false
        /// The ask of a hashtag's page was this side's stream's: it ends.
        var endsTag = false
        /// The lists of the hashtags followed it held, and the other side does not.
        var lists: [FollowedTags] = []
        /// The other side's walk, as it stands: what is kept of its pages stays.
        var other = ShellWalk()
    }

    private func letGo(_ cleared: Cleared) {
        if cleared.leftLink { linkReader.close() }
        if cleared.endsTag { session.reload.endTag() }
        // What each list of the hashtags followed was told goes with its step (#318).
        for page in cleared.lists { people.followed.closed(page) }
        people.leftAll(besides: cleared.other)
        // A notice's errand is the timeline's walk.
        if cleared.side == .timeline { errand = nil }
    }

    /// `side`'s walk ended in one go, the other's as it was, with `tagAsk` the timeline the ask
    /// of a hashtag's page in front was made of, where one is: what is owed besides (`Cleared`).
    /// **The ask ends where it was this side's stream's** — Trends' for `.trends`, any
    /// timeline's for `.timeline` — or where there is none, which ends nothing but what it said.
    static func cleared(_ side: ShellStream, sides: inout StreamSides, tagAsk: TimelineQuery?) -> Cleared {
        let walk = sides[side].walk, other = sides[side.other].walk
        sides[side].walk.clear()
        return Cleared(
            side: side, leftLink: walk.openedLink != nil,
            endsTag: tagAsk.map { ShellStream(of: $0) == side } ?? true,
            lists: walk.followedTags.filter { !other.followedTags.contains($0) }, other: other
        )
    }

    /// The timeline switched while the session follows Trends — the timeline in front removed
    /// with its last source: the timeline's walk ends where it is kept, and its lamp and the row
    /// at its top, which were of the list replaced, go with it. Trends' side is not the
    /// timeline's to end.
    static func timelineSwitchedUnderTrends(_ sides: inout StreamSides, tagAsk: TimelineQuery?) -> Cleared {
        let cleared = cleared(.timeline, sides: &sides, tagAsk: tagAsk)
        sides[.timeline].lamp = nil
        sides[.timeline].top = nil
        return cleared
    }

    /// Trends gone with the last source that had it: its side ends whole — walk, lamp and top —
    /// so nothing of it is held for a page nobody can reach (`openSteps`), and `h` lands on
    /// nothing left of it later. Nothing where there was nothing on it.
    static func trendsGone(_ sides: inout StreamSides, tagAsk: TimelineQuery?) -> Cleared? {
        guard sides[.trends] != StreamSide() else { return nil }
        let cleared = cleared(.trends, sides: &sides, tagAsk: tagAsk)
        sides[.trends] = StreamSide()
        return cleared
    }

    /// The steps open over both stream places, the timeline's first: what the store keeps the
    /// rows of (#359).
    static func openSteps(_ sides: StreamSides) -> [ShellStep] {
        sides[.timeline].walk.steps + sides[.trends].walk.steps
    }

    /// Hands the link reader the question of where a page opens (#169). On a Mac it is one more
    /// step of the walk wherever one may be taken, and a sheet elsewhere; on iPad and iPhone it is
    /// always the sheet.
    private func placeLinksInPage() {
        let reload = session.reload
        linkReader.gone = { [weak reload] source in reload?.gone.contains(source) ?? false }
        #if os(macOS)
        linkReader.placing = { url in placeLink(url) }
        #endif
    }

    /// A page read out of a post's words, drawn in place of the page it was pressed on: one step
    /// of the walk, from the row the lamp is on, so leaving it gives that row back (#169).
    ///
    /// **Under `canWalk`'s guard**, as a conversation and a person are — so not under the viewer
    /// or the keys list, and not from another place's page, where there is no walk to take a step
    /// in. Those read it in the sheet, as before.
    private func placeLink(_ url: URL) -> Bool {
        Self.placeLink(url, on: &walk, from: selectedItemID, place: place, open: openLayers)
    }

    /// `placeLink`'s rule, given what it reads, so a test takes the step the root takes.
    static func placeLink(
        _ url: URL, on walk: inout ShellWalk, from lamp: String?, place: ShellPlace, open: Set<DummyLayer>
    ) -> Bool {
        guard canWalk(place: place, open: open) else { return false }
        return walk.walk(to: .link(url), from: lamp) || walk.openedLink == url
    }

    /// Tab rotates this page's tabs: named queries on the timeline, purposes on Usage, on
    /// Preferences and on Account. Elsewhere it is the platform's.
    ///
    /// **The walk is asked first, whatever step is in front** (F9, F10): a page that answers
    /// has the key, and the timelines are not turned from under it — to change timeline the
    /// reader leaves first. **Asked only of a page that is drawn**: a step that cannot be
    /// drawn draws the stream under the timelines' head, and there the key is the timelines'.
    private func rotatePlaceTab(by step: Int) -> Bool {
        if place.isStream, let key = walk.tabKey {
            switch Self.stepTab(key, drawn: standingDrawn, open: openLayers) {
            case .page: return rotateStepTab(key, by: step)
            case .covered: return false
            case .timelines: break
            }
        }
        return switch place {
        case .timeline: session.rotateTab(by: step)
        case .trends: rotateTrendsTab(by: step)
        case .usage: session.rotateUsageTab(by: step)
        case .preferences: session.rotatePreferencesTab(by: step)
        case .account: session.rotateAccountTab(by: step)
        default: false
        }
    }

    /// Whose Tab is with a step in front, as the walk answered for it (`key`).
    enum StepTab: Equatable, Sendable {
        /// The page's: its tabs turned, or — on a page with none — taken, turning nothing.
        case page
        /// Nobody's: something is drawn over a page with no tabs.
        case covered
        /// The timelines': the step's page is not drawn, and the stream is, under their head.
        case timelines
    }

    /// Whose Tab is with the step `key` answers for in front, drawn or not (`TimelinePane.drawn`),
    /// under what is `open`. Somebody's page and a hashtag's say for themselves whether they
    /// are covered (`rotateStepTab`).
    static func stepTab(_ key: StepTabKey, drawn: Bool, open: Set<DummyLayer>) -> StepTab {
        guard drawn else { return .timelines }
        if case .sole(let layer) = key, !pageInFront(layer, open: open) { return .covered }
        return .page
    }

    /// Tab on the page in front, as the walk answered for it. With somebody's page the tabs
    /// are that page's, round their ring; under anything drawn over the page the key does nothing.
    /// With a page that has no tabs the key is taken, and turns nothing (`stepTab` said it is
    /// in front). A hashtag's page is either: its two tabs where it has them, and taken all
    /// the same where it has its posts alone.
    private func rotateStepTab(_ key: StepTabKey, by step: Int) -> Bool {
        switch key {
        case .sole: return true
        case .tag(let tag):
            return people.tags.rotate(
                tag, by: step, covered: !Self.pageInFront(.tag, open: openLayers), lamp: &selectedItemID, in: session
            )
        case .found(let at, let which):
            let layer = ShellStep.found(at, which).layer
            return people.found.rotate(
                &walk, by: step, covered: !Self.pageInFront(layer, open: openLayers), lamp: &selectedItemID, in: session
            )
        case .person(let person):
            guard Self.turnsPersonTabs(open: openLayers) else { return false }
            return people.rotate(person, by: step, lamp: &selectedItemID, in: session)
        }
    }

    /// Whether Tab turns the tabs of somebody's page, given what is open: their page is what
    /// is in front, with nothing drawn over it.
    static func turnsPersonTabs(open: Set<DummyLayer>) -> Bool {
        pageInFront(.person, open: open)
    }

    /// Whether the opened page `layer` is what is in front, with nothing drawn over it: the
    /// one condition under which Tab is that page's, whatever it does there.
    static func pageInFront(_ layer: DummyLayer, open: Set<DummyLayer>) -> Bool {
        DummyCommand.outermost(of: open) == layer
    }

    /// The arrangement this window gets for the width it has (#110). See `ShellLayout`.
    ///
    /// **Asked on every pass, from a width measured on every change.** A Mac window being dragged
    /// reports a new width for each step of the edge, so the arrangement swaps while the drag is
    /// still happening rather than when it is let go, and a window dragged back over the line
    /// swaps back at the same width, because the rule has one line and no memory.
    ///
    /// An iPad answers its width the same way, in both orientations and at every size beside
    /// another app (#111); a phone keeps its size class, for the reason
    /// `ShellLayout.answering(width:phoneIsCompact:)` gives.
    private func arrangement(for width: CGFloat?) -> ShellLayout {
        #if os(iOS)
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        return ShellLayout.answering(width: width, phoneIsCompact: phone ? sizeClass == .compact : nil)
        #else
        return ShellLayout.answering(width: width)
        #endif
    }

    /// **Nothing the reader is standing on is held in either arrangement.** The place, the lamp,
    /// the walk and the rail's state are all this view's own, so swapping what is drawn around
    /// the page leaves every one of them where it was; the list drawn afresh centres on the lamp
    /// as it does coming back from a thread, and on the row that was at the top where there is
    /// no lamp — see `TimelinePane.list`.
    private var layout: some View {
        ShellArranged(answer: arrangement) { layout in
            switch layout {
            case .narrow: narrow
            case .wide: columns
            }
        }
    }

    private var columns: some View {
        HStack(spacing: 0) {
            RailView(
                place: placeBinding,
                expanded: $railExpanded,
                availability: availability,
                onCompose: {
                    guard availability.canCompose else { return }
                    composing = true
                }
            )
            ShellRule(.vertical)
            page
        }
        .background(ShellChrome.page(colorScheme))
    }

    /// Rejects a disabled destination so compact TabView snaps back.
    private var placeBinding: Binding<ShellPlace> {
        Binding(
            get: { place },
            set: { place = availability.placing(place, as: $0) }
        )
    }

    enum Compact {
        static let button: CGFloat = 56
        /// Clear of the tab bar, which the overlay knows nothing about. A Mac draws its tabs
        /// across the top rather than the bottom, so there the button only keeps its room.
        #if os(iOS)
        static let clearance: CGFloat = 72
        #else
        static let clearance: CGFloat = ShellSpace.room
        #endif
    }

    /// The corner of every page the compose button floats over in the narrow arrangement, and
    /// nothing where it does not float (#112). See `EnvironmentValues.shellFloatingCorner`.
    ///
    /// **Measured from the page's own edges, and generous rather than exact.** The button is laid
    /// against the tabs' whole frame, so on a phone it is `clearance` above the frame's bottom and
    /// the tab bar is somewhere under that; the page ends at the bar. The room asked for is the
    /// button, its clearance and a step besides, which is more than the page needs wherever the
    /// bar is below it — a list that stops a little short, which costs nothing, rather than one
    /// that stops under the button, which costs its last row's marks.
    static func composeCorner(canCompose: Bool) -> CGSize {
        guard canCompose else { return .zero }
        return CGSize(
            width: Compact.button + ShellSpace.room + ShellSpace.snug,
            height: Compact.button + Compact.clearance + ShellSpace.snug
        )
    }

    /// The narrow arrangement: the places as tabs where their names fit, and as one pop-up named
    /// for them where a Mac window is too narrow to write them side by side (#141). See
    /// `ShellFold`.
    ///
    /// **The compose button and the corner it takes are the arrangement's, not the tabs'**, so
    /// they are put on here, around either one. A fold that moved the button to make room for
    /// its name would be moving something it did not fold.
    private var narrow: some View {
        // **The tabs' names are measured, and the pop-up lists every place**: Usage is no tab
        // (decision 9), so five names decide the fold, and folded it is a place of its own again.
        ShellNarrow(titles: availability.tabbedPlaces.map(\.title)) {
            tabbed
        } folded: {
            FoldedPlaces(place: placeBinding, places: availability.enabledPlaces) {
                placedPage(place)
            }
        }
        .tint(ShellChrome.phosphor(colorScheme))
        // Every page under the button is told the corner it takes, so the end of a list and the
        // search bar leave it clear (#112).
        .environment(\.shellFloatingCorner, Self.composeCorner(canCompose: availability.canCompose))
        .overlay(alignment: .bottomTrailing) {
            if availability.canCompose { composeButton }
        }
        // Behind the folded places' own bar, which is no page's.
        .background(ShellChrome.page(colorScheme))
    }

    /// Tabs instead of a rail, and only for the places it can enter. Drawn on a Mac as well
    /// since #110, for a window dragged narrower than the rail allows. A tab bar has no disabled
    /// state worth the name: tapping a dead tab selected it, the binding put it back, and the
    /// reader was told nothing at all. A place that is not ready is not a tab yet.
    ///
    /// **Usage is no tab** (decision 9): a phone's bar holds five, so it is drawn in Preferences'
    /// tab, entered from a row at the head of Preferences and left by a back row (`OpensUsage`).
    private var tabbed: some View {
        TabView(selection: tabSelection) {
            ForEach(availability.tabbedPlaces) { item in
                placedPage(item.drawn(standingOn: place))
                    .tabItem { Label(item.title, systemImage: item.symbolName) }
                    .tag(item)
            }
        }
        .environment(\.shellOpensUsage, opensUsage)
    }

    /// The tab lit for where the reader stands: Preferences' while they stand on Usage, so a key,
    /// an errand or a state put back that stands them there finds a tab and not a missing one.
    private var tabSelection: Binding<ShellPlace> {
        Binding(
            get: { place.tab },
            set: { place = Self.selecting($0, standingOn: place) }
        )
    }

    /// Where a tab set by the bar stands the reader: on that tab's place, but **a set of the tab
    /// already lit leaves them where they are**. A bar may set its own tab again — a reselect on
    /// a phone, the tabs rebuilt as Trends comes or goes — and with Usage drawn in Preferences'
    /// tab that would otherwise drop the reader from Usage onto Preferences, on one platform and
    /// not another. Leaving Usage is the back row's (`OpensUsage`).
    static func selecting(_ tab: ShellPlace, standingOn place: ShellPlace) -> ShellPlace {
        tab == place.tab ? place : tab
    }

    /// Preferences' way into Usage and Usage's way back, handed to the tabs alone.
    private var opensUsage: OpensUsage {
        OpensUsage(go: { place = availability.placing(place, as: $0) })
    }

    /// Solid ink, not phosphor: the lamp says where the reader is, and a button that
    /// writes a post is not a place. It is here only when it can be pressed.
    private var composeButton: some View {
        Button { composing = true } label: {
            Image(systemName: "square.and.pencil")
                .shellFont(.pane)
                .frame(width: Compact.button, height: Compact.button)
                .background(Circle().fill(ShellChrome.ink(colorScheme)))
                .foregroundStyle(ShellChrome.page(colorScheme))
        }
        .buttonStyle(.plain)
        .shellNamed("compose.title")
        .padding(.trailing, ShellSpace.room)
        .padding(.bottom, Compact.clearance)
    }

    @ViewBuilder
    private var page: some View {
        placedPage(place)
    }

    @ViewBuilder
    private func pageFor(_ item: ShellPlace) -> some View {
        switch item {
        case .timeline: streamPage(.timeline)
        case .trends: streamPage(.trends)
        case .notices:
            NoticesPane(
                session: session,
                selectedID: $noticeSelectedID,
                mark: noticeMark,
                canReload: Self.canReadNotices(
                    place: place, open: openLayers, asked: !ShellNoticeList.asked(in: session).isEmpty
                ),
                onReload: { _ = readNotices() },
                onOpen: { _ = openNotice($0) },
                onOpenPerson: { person, notice in _ = openNoticePerson(person, of: notice) },
                tooOld: noticeTooOld,
                jumpToTop: noticeJump
            )
        case .account: AccountPane(session: session, onOwnPage: ownPageOpener, announced: people.announcements)
        case .usage: UsagePane()
        case .preferences: PreferencesPane()
        }
    }

    /// A stream place's page: the timeline, or Trends — the same pane on its own side's walk and
    /// lamp, handed Trends' tabs on Trends (DESIGN-trends, Root).
    ///
    /// **Only the stream the session follows is drawn.** On a compact `TabView` every tab stays
    /// alive, and the other stream's pane would draw the followed stream's rows under its own
    /// walk; it is the ground until it is followed again, and drawn afresh then at its lamp, or
    /// at the row that was at its top, as a list drawn afresh always is.
    @ViewBuilder
    private func streamPage(_ stream: ShellStream) -> some View {
        if stream == session.stream {
            TimelinePane(
                session: session,
                selectedID: lampBinding(stream),
                // What the page under a link stands on: a page read out of a post is drawn over
                // it by `LinkInPlace`, and it stays drawn (#169).
                standing: sides[stream].walk.beneath,
                onOpenPerson: { _ = openPerson($0) },
                decks: $decks,
                playback: playback,
                onPlayRow: playRow,
                onViewRow: viewRow,
                onTurnRow: turnRow,
                onOpenThread: { _ = openThread($0) },
                jumpToTop: jumpToTop,
                onBack: { _ = leaveWalk() },
                // The two marks in the timeline's header, and whether there is anything for them
                // to do — the same two functions the keys ask (#33).
                ways: TimelineWays(
                    canSearch: canSearchNow,
                    onSearch: { _ = openSearch() },
                    canReload: canReloadNow,
                    onReload: { _ = reload() }
                ),
                search: search,
                people: people,
                onOpenListed: { _ = openListed($0) },
                onOpenRisingRow: { _ = openRisingRow($0) },
                onOpenRising: { _ = openRisingRow($0.row, lit: $0.id) },
                onOpenFound: { _ = openFound($0) },
                onTurnFound: foundTurned,
                onFollowed: { _ = followedPressed($0) },
                onRequests: { _ = requestsPressed($0) },
                onKeeping: { _ = keepingPressed($0) },
                onOpenFeatured: { _ = featuredPressed($0, from: nil) },
                onLookUp: lookUpPressed,
                trends: stream == .trends ? trendsHead : nil
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if searchFieldDrawn {
                    SearchBar(
                        search: search,
                        timeline: session.name(of: session.currentTimeline),
                        found: search.isIndexed ? searchItems?.count : nil,
                        counted: session.searchCount(found: searchItems?.count ?? 0, searched: search.searchedCount),
                        reach: session.reload.reach?.sentence,
                        lookUp: people.found.line(typed: search.text, in: session),
                        onLookUp: lookUpPressed,
                        onSubmit: searchSubmitted,
                        onCleared: searchCleared,
                        onClose: closeSearch
                    )
                }
            }
            .modifier(LinkInPlace(reader: linkReader, onBack: leaveLink))
        } else {
            Color.clear
        }
    }

    /// The lamp of `stream`'s side, as the pane binds it: written, as everything is, to the
    /// side it was read from.
    private func lampBinding(_ stream: ShellStream) -> Binding<String?> {
        Binding(
            get: { sides[stream].lamp },
            set: { sides[stream].lamp = $0 }
        )
    }

    /// One page, told whether it is the one the reader is looking at.
    ///
    /// **Per page rather than once at the root**, because on a compact `TabView` every tab stays
    /// alive and a value set above them all would be true in the tab nobody can see. See
    /// `EnvironmentValues.shellPlaceIsActive`.
    ///
    /// **And each page says what did not happen** (`SaidStrip`), so it is said whichever place
    /// is in front, and stands inside the page rather than over what is drawn around it.
    ///
    /// **Each page brings the ground with it**, in the narrow arrangement as in the wide one: a
    /// tab is drawn on the system's own background unless its page covers it, and the chassis
    /// has one ground whatever is drawn around the page.
    @ViewBuilder
    private func placedPage(_ item: ShellPlace) -> some View {
        pageFor(item)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // What did not happen is said at the foot of every page, inside it: over no rail,
            // no tab and no sheet. A modifier of its own — see `SaidStrip`.
            .modifier(SaidStrip(said: session.said, session: session, held: item != place || composing || stagePresented.wrappedValue || session.raisesOverPages))
            .background(ShellChrome.page(colorScheme))
            .environment(\.shellPlaceIsActive, item == place)
    }
}

/// Taking back what the reader wrote (#109): the one act that asks first. It names what goes, and
/// nothing goes until it is confirmed; any route that is not the confirm button — Cancel, a click
/// outside, Escape — is a cancel, and leaves all as it was.
///
/// **A modifier of its own, and not the dialog spelled inside `FediqoRootView.body`.** Written
/// there, a `presenting:` dialog with its two closures took `body` past what Swift 6.0 on the
/// runner would type-check in reasonable time, while the newer compiler here solved it without a
/// word — twice, the second time with its binding and title already lifted out. Out here the
/// chain gains one plain call, which is a cost no compiler has to solve against the rest of it.
private struct WithdrawQuestion: ViewModifier {
    let session: ShellSession

    /// The row asked about, and the copy that goes through — kept together, so the sheet still
    /// names the same post as it slides away after the session has let go of the question.
    struct Asked {
        let item: DummyItem
        let copy: DummyItem
    }

    func body(content: Content) -> some View {
        content.shellConfirm(asked, question: { ShellQuestion.withdraw($0.copy) }) { asked, _ in
            Task { await session.withdraw(asked.item) }
        }
    }

    private var asked: Binding<Asked?> {
        Binding(
            get: { session.withdrawing.map { Asked(item: $0, copy: session.withdrawingCopy ?? $0) } },
            set: { if $0 == nil { session.cancelWithdraw() } }
        )
    }
}

/// What a person's page puts up over everything — their profile, the mute or block asked, and the
/// servers the reader blocks — gathered in one modifier so the root's chain of presenters stays
/// short enough to type-check in time (`test-before-push`).
private struct PersonPresenters: ViewModifier {
    let people: ShellPersonPages
    let session: ShellSession

    func body(content: Content) -> some View {
        content
            .modifier(ProfileSheetPresenter(profile: people.profile, session: session))
            .modifier(StandingSheetPresenter(people: people, session: session))
            .modifier(BlockedServersPresenter(servers: people.servers, session: session))
    }
}

/// A text that waits to be sent, opened again, and the question before one is discarded
/// (`ShellOutbox`) — out of the chain for `WithdrawQuestion`'s reason. The sheet closing by any
/// way changes nothing of the text, and keeps what was typed for the next time it is opened;
/// a question answered any way but its yes changes nothing. And the question before a text
/// that may have been posted is sent all the same.
private struct UnsentPresenters: ViewModifier {
    let session: ShellSession

    func body(content: Content) -> some View {
        content
            .sheet(item: editing) { asked in
                UnsentSheet(id: asked.id)
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    #endif
            }
            .shellConfirm(discarding, question: { ShellQuestion.discard($0) }) { sending, _ in
                session.outbox.discardSoon(sending.id, in: session)
            }
            .shellConfirm(resending, question: { ShellQuestion.resend($0, changed: session.outbox.changed($0.id) != nil) }) { sending, _ in
                session.outbox.sendAnyway(sending.id, in: session)
            }
    }

    private var editing: Binding<UnsentAsk?> {
        Binding(get: { session.editingUnsent }, set: { session.editingUnsent = $0 })
    }

    private var resending: Binding<ShellOutbox.Sending?> {
        Binding(
            get: { session.resendingUnsent.flatMap { session.outbox.sending($0.id) } },
            set: { if $0 == nil { session.resendingUnsent = nil } }
        )
    }

    private var discarding: Binding<ShellOutbox.Sending?> {
        Binding(
            get: { session.discardingUnsent.flatMap { session.outbox.sending($0.id) } },
            set: { if $0 == nil { session.discardingUnsent = nil } }
        )
    }
}

/// A server ended a sign-in on its own side, said — out of the chain for `WithdrawQuestion`'s reason.
/// The row already reads signed out, and this says why rather than leaving a timeline to go quiet.
private struct EndedSignInNotice: ViewModifier {
    let session: ShellSession

    func body(content: Content) -> some View {
        content.shellConfirm(ended, question: { ShellQuestion.signedOut(hosts: $0, left: session.mastodon.endedLeft) }) { _, _ in }
            .modifier(LeftSignInsNotice(mastodon: session.mastodon))
    }

    private var ended: Binding<[String]?> {
        Binding(
            get: { session.mastodon.ended.isEmpty ? nil : session.mastodon.ended },
            set: { if $0 == nil { session.mastodon.endedSeen() } }
        )
    }
}

/// The store did not simply open (#295): said at the first thing the person sees.
///
/// **Only a press on the notice answers it.** Being told of a damaged store is its own button,
/// and choosing between two stores is theirs; the sheet going away any other way — Escape, a
/// swipe, the system taking it down, another presenter winning, the view replaced while the app
/// is still launching — answers nothing, and the notice is shown again at the next launch. What
/// waits on being told is a deletion that cannot be taken back.
///
/// A modifier of its own, so the root view's chain gains one line and no closure of its own.
private struct StoreTroubleNotice: ViewModifier {
    @Binding var trouble: StoreTrouble?
    let answered: (@MainActor (StoreTroubleAnswer) -> Void)?

    func body(content: Content) -> some View {
        content.shellConfirm($trouble, question: { ShellQuestion.storeTrouble($0) }) { _, id in
            if let answer = ShellQuestion.storeTroubleChose(id) { answered?(answer) }
        }
    }
}

/// The store was written by a newer build: said once, and seen by whatever route it is put
/// down — the press, Escape, a swipe.
private struct StoreNewerNotice: ViewModifier {
    @Binding var shown: Bool
    let seen: (@MainActor () -> Void)?

    func body(content: Content) -> some View {
        content.shellConfirm(asked, question: { _ in ShellQuestion.storeNewer() }) { _, _ in }
    }

    private var asked: Binding<Bool?> {
        Binding(
            get: { shown ? true : nil },
            set: { if $0 == nil { shown = false; seen?() } }
        )
    }
}
