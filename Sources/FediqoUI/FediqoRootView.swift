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
    @State private var selectedItemID: String?
    /// How far the reader has walked out from the stream, and by which steps (#122).
    ///
    /// **One stack for conversations and people both.** They were two pieces of state — a stack
    /// of thread ids, and one person with the lamp's place kept beside them — which is what made
    /// the order between them something `DummyLayer` had to settle once and for all, and what
    /// made a row on somebody's page a thing that lit and went no further. `ShellWalk` says why
    /// one stack is the honest shape. Held here because leaving it is `Escape` and `q`, and the
    /// keys are read here.
    @State private var walk = ShellWalk()
    /// What `/` opened (#32). Its results stand in for the stream while it is open.
    @State private var search = ShellSearch()
    @State private var jumpToTop = 0
    @State private var composing = false
    @State private var showingShortcuts = false
    @State private var shortcutTab: DummyShortcutGroup = .move
    /// The launch overlay. Starts true; `LandingView` clears it after the flips, and
    /// `playsLanding` is false from the first frame when reduce motion is on.
    @State private var showingLanding = true
    /// Bumped so a press of `r` remounts the overlay from rest rather than showing a
    /// view that has already flipped.
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
    /// Up once at launch when the index on disk was written by a newer build and this run left it
    /// alone: without it the reader sees an empty app and nothing to say why.
    @State private var storeIsNewer: Bool
    /// Told when the reader dismisses that notice, so a window opened later does not raise it
    /// again: each window is its own root view with its own state.
    private let storeNoticeSeen: (@MainActor () -> Void)?
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

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    public init(
        http: any HTTPClient = URLSessionClient(),
        store: ItemStore = ItemStore(),
        forums: ForumSessions = ForumSessions(),
        mastodon: MastodonSessions = MastodonSessions(),
        persist: (@MainActor () async -> Void)? = nil,
        storeIsNewer: Bool = false,
        storeNoticeSeen: (@MainActor () -> Void)? = nil
    ) {
        let session = ShellSession(
            http: http, store: store, forums: forums, mastodon: mastodon,
            timelines: WrittenTimelineStore(defaults: .standard)
        )
        session.persist = persist
        _session = State(initialValue: session)
        _storeIsNewer = State(initialValue: storeIsNewer)
        self.storeNoticeSeen = storeNoticeSeen
    }

    /// Hands the copies of pictures already on this device to the one picture cache every row
    /// draws from, once, at launch — and first drops the copies of any host not in `hosts`, the
    /// servers the reader still reads. Queued ahead of every picture a row can ask for, so the
    /// sweep never races a copy being written for a server just added. What is left is then
    /// trimmed to the cap (#7), so a cap lowered by a new build holds from its first launch.
    public static func keepPictures(in copies: any MediaCopies, for hosts: [String]) {
        let disk = DiskCopies(copies)
        disk.keepOnly(hosts: hosts)
        disk.trim()
        ShellPictures.shared.disk = disk
    }

    private var availability: ShellAvailability { session.availability }

    /// Reduce motion never mounts the overlay, so a reader who asked for stillness does not
    /// get one frame of a flip and then a skip.
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
                await session.keep(months: prefs.keepMonths)
                await session.reloadFromStore()
                // The store has now said what is held, which is the first moment this launch can
                // be asked where it lands (#101). Asked here and nowhere else, so it is asked
                // once.
                if let landing = launch.settle(availability, standingOn: place) {
                    place = landing
                }
                // Last, because it does not return: from here every landing renews what is in
                // front, with no key pressed (#175).
                await session.followStore()
            }
            .onChange(of: prefs.keepMonths) { _, months in
                Task { await session.keep(months: months) }
            }
            .modifier(AsksOnAWait(session: session, minutes: prefs.askMinutes))
            .onChange(of: place) { old, new in
                let accepted = availability.placing(old, as: new)
                if accepted != new { place = accepted }
                guard accepted != old else { return }
                if search.closes(leavingFor: accepted) { closeSearch() }
                // A picture opened over the timeline is not opened over the account page.
                _ = closeViewer()
                // And the film stops — **including one playing in a row**, which is the half
                // `closeViewer` cannot do, because with a row playing the viewer was never open.
                playback.stop()
            }
            // The rail and the tab bar both draw only the places that can be entered.
            // If that set ever narrows under the reader — a sign-out, a source
            // dropped — the selection would point at a tab that is no longer there.
            .onChange(of: availability) { _, new in
                let accepted = new.placing(place, as: place)
                if accepted != place { place = accepted }
            }
            // A timeline switched is the list every step of the walk was standing on being
            // replaced, so the walk ends rather than unwinds: there is no row left to hand the
            // lamp back to. Where the lamp lands is #100's, and `TimelinePane` answers it on the
            // same change. Here rather than in the pane because the walk is held here — the pane
            // used to do it through a binding whose one meaning was "close the thread".
            .onChange(of: session.timelineID) { _, _ in clearWalk() }
            .sheet(isPresented: $composing) {
                ComposerSheet()
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    #endif
            }
            // Taking back what the reader wrote (#109): the one act that asks first. A modifier of
            // its own rather than the dialog spelled here — see `WithdrawQuestion`.
            .modifier(WithdrawQuestion(session: session))
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
                JoinSheet(session: session)
            }
            // The timeline editor (#27), on the root beside the other presenters for their reason.
            // Dismissed by any route it is Cancel: the draft is dropped (Decision 21).
            .sheet(item: $session.editing) { draft in
                TimelineEditor(session: session, draft: draft)
            }
            // Remove's question, Clear's, and the notice that a server ended a sign-in: each a
            // modifier of its own rather than spelled here. See `HostQuestion` for why.
            .modifier(HostQuestion.remove(session))
            .modifier(HostQuestion.clear(session))
            .modifier(EndedSignInNotice(session: session))
            .alert(Text(L10n.t("store.newer.title")), isPresented: $storeIsNewer) {
                Button(L10n.t("store.newer.ok"), role: .cancel) { storeNoticeSeen?() }
            } message: {
                Text(L10n.t("store.newer.detail"))
            }
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
            .accessibilityHidden(viewedItem != nil || playsLanding)
            .overlay { viewer }
            // After the viewer, so the mascot is the first thing a launch draws over.
            .overlay {
                if playsLanding {
                    LandingView { showingLanding = false }
                        .id(landingTick)
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
                    session.mastodon.refresh()
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
            .environment(\.locale, prefs.language.locale)
            .preferredColorScheme(prefs.theme.colorScheme)
            .dynamicTypeSize(prefs.fontSize.dynamicType)
            .id(prefs.language)
    }

    /// What the Remove question says goes, which depends on whether there are boards to lose.
    ///
    /// **Two whole sentences and two keys, not one sentence with a clause appended.** "the 3 boards
    /// you picked" must never appear over a microblog, and a second half joined on with `+` is a
    /// half no translator can put first. `ShellSession.clear` argues why the boards are the part
    /// worth naming: pictures come back by themselves and a pick of eight boards out of forty does
    /// not, so Remove — the act that takes them — is the act that has to say so before the press.
    ///
    /// Static and given the list, so the sentence is a function of its inputs that a test can read
    /// without standing a view up.
    static func removeDetail(for host: String, in sources: [Source]) -> String {
        let boards = sources.first { $0.host == host }?.boards.count ?? 0
        guard boards > 0 else { return L10n.t("account.remove.detail") }
        return String(format: L10n.t("account.remove.detail.boards"), boards)
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
        // The overlay is not a layer a press can leave, so dummy keys are swallowed until
        // the flips finish rather than driving the shell underneath. Unmapped chords —
        // ⌘Q, ⌘C — have already returned false, so a quit still quits.
        if playsLanding { return true }
        // The editor is a sheet and owns its keys; nothing under it moves.
        if session.editing != nil { return false }
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
            return moveInList(by: 1)
        case .previousPost:
            return moveInList(by: -1)
        case .goTop:
            return jumpListOrThreadToTop()
        case .expandPost:
            return openThread()
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
            switch DummyCommand.outermost(of: openLayers) {
            case .viewer: return closeViewer()
            // One step back, whichever kind of step it was. The two lines used to be two
            // methods over two pieces of state; they are one walk now, and unwinding it in the
            // order the reader walked is the whole of what a press to leave does (#122).
            case .person, .thread, .link: return leaveWalk()
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
        case .answer:
            return answerFocused()
        case .withdraw:
            return onFocusedItem { session.askToWithdraw($0) }
        case .openAuthor:
            return openAuthor()
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
            if place == .timeline, session.reload.stop() { return true }
            switch DummyCommand.outermost(of: openLayers) {
            case .viewer: return closeViewer()
            case .shortcuts:
                showingShortcuts = false
                return true
            case .person, .thread, .link: return leaveWalk()
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
        playback.toggle(file, of: item.id, on: .row)
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
            return playback.toggle(file, of: item.id, on: stage)
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
        guard place == .timeline else { return false }
        switch DummyCommand.focused(in: currentListItems, selected: selectedItemID) {
        case .nothing:
            return false
        case .first(let id):
            guard DummyCommand.canOpen(.selection, whenOpen: openLayers) else { return false }
            selectedItemID = id
            return true
        case .post(let item):
            return act(item)
        }
    }

    /// j/k and the arrows walk whichever list is in front: the stream, or the open conversation.
    private func moveInList(by step: Int) -> Bool {
        guard place == .timeline,
              let next = Self.moved(in: currentListIDs, from: selectedItemID, by: step, open: openLayers)
        else { return false }
        selectedItemID = next
        return true
    }

    /// Where `j` or `k` puts the lamp in the list in front, or nothing where the press moves
    /// nothing. Static so a test that follows the reader's keys presses the rule the root does
    /// (#168), rather than a copy of it.
    ///
    /// Entering the selection obeys the entry rule the same as any other layer. Moving an
    /// existing one does not — the lamp is already on, and `j` means move rather than enter.
    /// With a thread or the viewer open the selection is always already on, so in practice
    /// this only ever refuses a first press under the guide — or under a search, which is why
    /// Return lights the first result rather than leaving `j` to.
    static func moved(in ids: [String]?, from selected: String?, by step: Int, open: Set<DummyLayer>) -> String? {
        guard let ids else { return nil }
        if selected == nil, !DummyCommand.canOpen(.selection, whenOpen: open) { return nil }
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
        place == .timeline && DummyCommand.canOpen(.search, whenOpen: open)
    }

    /// `/` on the timeline: an empty search over what the timeline in front lets through (#145), or
    /// the field again if one is open. The selection is put aside, to come back when the search closes.
    private func openSearch() -> Bool {
        guard Self.canSearch(place: place, open: openLayers) else { return false }
        if search.isOpen {
            search.focus()
        } else {
            search.open(from: selectedItemID, over: session.notes)
            selectedItemID = nil
        }
        return true
    }

    /// The timeline back as it was, with the post that was selected before the search.
    private func closeSearch() {
        clearWalk()
        selectedItemID = search.close()
    }

    /// The field emptied: the timeline is back, so the post selected before the search is too.
    private func searchCleared() {
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
    private var currentListItems: [DummyItem] {
        switch walk.standing {
        case .person(let person):
            return session.heldPosts(of: person)
        case .thread(let opened):
            guard let item = session.held(opened) else { return streamItems }
            return session.conversations.conversation(around: item).inOrder
        // A page read out of a post has no rows: nothing on it is walked with `j` and `k`, and
        // the list under it is not what the reader is looking at (#169).
        case .link:
            return []
        case nil:
            return streamItems
        }
    }

    private var currentListIDs: [String]? {
        let ids = currentListItems.map(\.id)
        return ids.isEmpty ? nil : ids
    }

    private func jumpListOrThreadToTop() -> Bool {
        guard place == .timeline else { return false }
        // The top of a conversation is its own opening post, which is not the first row of the
        // list the walk is standing on — every other case is. **No `default:`.**
        switch walk.standing {
        case .thread(let opened) where session.held(opened) != nil:
            selectedItemID = opened
        // A page read out of a post is somebody else's page, and its top is its own business.
        case .link:
            return false
        case .person, .thread, nil:
            guard let first = currentListItems.first else { return false }
            selectedItemID = first.id
        }
        jumpToTop += 1
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
    ///    about. A reader reaches the replies the way they always have: `Return`, then `s`.
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
        guard place == .timeline, viewedItem == nil, walk.openedThread == item.id,
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
        place == .timeline && DummyCommand.canWalk(whenOpen: open)
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
        guard Self.canWalk(place: place, open: openLayers) else { return false }
        selectedItemID = id
        // **A forum's ranked blog is a page, not a conversation**: opening it reads its page in
        // the app's own reader, as a link pressed in its words would — on a Mac in place of the
        // timeline (#169), and Back returns to this row.
        if let page = session.held(id)?.page { return linkReader.open(page) }
        // The lamp is read back after the press has moved it, which is how a conversation comes
        // back to its own opening post and a person's page comes back to the row the lamp was
        // on: one sentence for what used to be two. See `ShellWalk`.
        return walk.walk(to: .thread(id), from: selectedItemID)
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
    static func canReload(place: ShellPlace, editing: Bool, hasSources: Bool, open: Set<DummyLayer>) -> Bool {
        guard place == .timeline, !editing, hasSources else { return false }
        switch DummyCommand.outermost(of: open) {
        // A search's results are what this device holds, found without asking anybody.
        case .viewer, .shortcuts, .search: return false
        // **Nothing to ask for on somebody's page**, and that is the whole of 0.4.0's boundary
        // rather than an oversight: what is drawn there is what this device already holds, and a
        // reload that went and got more of the world would be 0.5.0 arriving through `r`.
        case .person: return false
        // A page read out of a post is not a timeline; there is nothing of ours on it to ask for.
        case .link: return false
        case .thread, .selection, nil: return true
        }
    }

    /// `r`: the open thread, or else the selected timeline — and only on what the reader can see,
    /// so not under the viewer, the keys list or the timeline editor. A second press while the
    /// same one runs is taken and does nothing (`ShellReload.press`); Esc is what stops it.
    private func reload() -> Bool {
        guard Self.canReload(
            place: place,
            editing: session.editing != nil,
            hasSources: !session.sources.isEmpty,
            open: openLayers
        ) else { return false }
        // The thread as `TimelinePane` draws it: one it cannot find draws the timeline instead.
        let opened = walk.openedThread.flatMap(session.held)
        session.reload.press(thread: opened, timeline: session.currentTimeline, in: session)
        return true
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
        return walk.walk(to: .person(person), from: selectedItemID)
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
        place == .timeline && DummyCommand.canOpenAuthor(whenOpen: open)
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
        selectedItemID = left.lamp
        return true
    }

    /// The Back on a page read out of a post: one step back out of the walk, which is that page
    /// wherever the Back can be pressed (#169).
    private func leaveLink() {
        guard walk.openedLink != nil else { return }
        _ = leaveWalk()
    }

    /// Back to the stream in one go, for a list that has been replaced. A page read out of a post
    /// that was one of the steps goes with them: nothing is left for it to be drawn in place of,
    /// and a reading left open would be presented as a sheet instead.
    private func clearWalk() {
        if walk.openedLink != nil { linkReader.close() }
        walk.clear()
    }

    /// Hands the link reader the question of where a page opens (#169). On a Mac it is one more
    /// step of the walk wherever one may be taken, and a sheet elsewhere; on iPad and iPhone it is
    /// always the sheet.
    private func placeLinksInPage() {
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

    /// Tab rotates this page's tabs: named queries on the timeline, purposes on Usage and on
    /// Preferences. Elsewhere it is the platform's.
    private func rotatePlaceTab(by step: Int) -> Bool {
        switch place {
        case .timeline: session.rotateTab(by: step)
        case .usage: session.rotateUsageTab(by: step)
        case .preferences: session.rotatePreferencesTab(by: step)
        default: false
        }
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
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(width: ShellSpace.hair)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ShellChrome.page(colorScheme))
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
        ShellNarrow(titles: availability.enabledPlaces.map(\.title)) {
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
    }

    /// Tabs instead of a rail, and only for the places it can enter. Drawn on a Mac as well
    /// since #110, for a window dragged narrower than the rail allows. A tab bar has no disabled
    /// state worth the name: tapping a dead tab selected it, the binding put it back, and the
    /// reader was told nothing at all. A place that is not ready is not a tab yet.
    private var tabbed: some View {
        TabView(selection: $place) {
            ForEach(availability.enabledPlaces) { item in
                placedPage(item)
                    .tabItem { Label(item.title, systemImage: item.symbolName) }
                    .tag(item)
            }
        }
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
        .accessibilityLabel(L10n.t("compose.title"))
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
        case .timeline:
            TimelinePane(
                session: session,
                selectedID: $selectedItemID,
                // What the page under a link stands on: a page read out of a post is drawn over
                // it by `LinkInPlace`, and it stays drawn (#169).
                standing: walk.beneath,
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
                    canSearch: Self.canSearch(place: place, open: openLayers),
                    onSearch: { _ = openSearch() },
                    canReload: Self.canReload(
                        place: place,
                        editing: session.editing != nil,
                        hasSources: !session.sources.isEmpty,
                        open: openLayers
                    ),
                    onReload: { _ = reload() }
                ),
                search: search
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if search.isOpen {
                    SearchBar(
                        search: search,
                        timeline: session.name(of: session.currentTimeline),
                        found: search.isIndexed ? searchItems?.count : nil,
                        onSubmit: { selectedItemID = streamItems.first?.id },
                        onCleared: searchCleared,
                        onClose: closeSearch
                    )
                }
            }
            .modifier(LinkInPlace(reader: linkReader, onBack: leaveLink))
        case .notices: NoticesPane()
        case .account: AccountPane(session: session)
        case .usage: UsagePane()
        case .preferences: PreferencesPane()
        }
    }

    /// One page, told whether it is the one the reader is looking at.
    ///
    /// **Per page rather than once at the root**, because on a compact `TabView` every tab stays
    /// alive and a value set above them all would be true in the tab nobody can see. See
    /// `EnvironmentValues.shellPlaceIsActive`.
    @ViewBuilder
    private func placedPage(_ item: ShellPlace) -> some View {
        pageFor(item)
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

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: asked,
            titleVisibility: .visible,
            presenting: session.withdrawing
        ) { item in
            Button(L10n.t("withdraw.confirm"), role: .destructive) {
                Task { await session.withdraw(item) }
            }
            Button(L10n.t("compose.cancel"), role: .cancel) { session.cancelWithdraw() }
        } message: { item in
            Text(ItemActs.withdrawQuestion(session.withdrawingCopy ?? item).detail)
        }
    }

    /// What goes, named — the copy that goes, on a row two sources carried (#136). Empty only
    /// while nothing is asked, when the dialog is not drawn.
    private var title: String {
        guard let item = session.withdrawingCopy ?? session.withdrawing else { return "" }
        return ItemActs.withdrawQuestion(item).title
    }

    private var asked: Binding<Bool> {
        Binding(
            get: { session.withdrawing != nil },
            set: { shown in if !shown { session.cancelWithdraw() } }
        )
    }
}

/// Remove's question and Clear's (decision 29), each as a modifier of its own — one shape for
/// the two, since they differ only in what they ask about, how heavy the confirm is, what it does
/// and what the detail says.
///
/// **Out of `FediqoRootView`'s chain, and the presenters below with it.** Each built a `Binding`
/// and a `presenting:` presenter with closures inside one very long modifier chain, and Xcode
/// 26.6's Swift gave up type-checking that chain on the runner — while the compiler this is
/// written with solved it in three seconds without a word. A local timing predicts nothing about
/// another compiler's solver, so the chain is kept to one plain `.modifier(…)` per presenter
/// instead, which is a cost no compiler has to solve against the rest of it. See
/// `WithdrawQuestion`.
///
/// **On the root beside the other presenters**, and for the same documented reason: one
/// presenter driven by one piece of session state survives a second call site.
private struct HostQuestion: ViewModifier {
    let session: ShellSession
    /// The host being asked about, where one is; the question is presented from it.
    let asking: ReferenceWritableKeyPath<ShellSession, String?>
    let titleKey: String
    let confirmKey: String
    let role: ButtonRole?
    let act: @MainActor (String) async -> Void
    let detail: @MainActor (String) -> String

    /// **The Remove question.** Remove is asked from a source row today and will be asked from
    /// the source page's own header the day that grows one.
    ///
    /// It is asked at all because Remove takes the board picks the reader made, and
    /// `ShellSession.clear`'s comment is the argument: pictures come back by themselves, a pick
    /// of eight boards out of forty does not.
    static func remove(_ session: ShellSession) -> HostQuestion {
        HostQuestion(
            session: session, asking: \.removing,
            titleKey: "account.remove.title", confirmKey: "account.remove.confirm",
            role: .destructive,
            act: { await session.remove(host: $0) },
            detail: { FediqoRootView.removeDetail(for: $0, in: session.sources) }
        )
    }

    /// **The Clear question, beside Remove's and driven the same way.** One presenter, one piece
    /// of session state, two entrances: a source row and `UsagePane`'s row, which press the same
    /// key for the same call and must therefore ask the same question.
    ///
    /// **It exists because Clear is not reversible, whatever the row looks like.** It drops the
    /// pictures, the emoji names and the first posts, all of which come back — and it calls
    /// `ForumSessions.forget(host:)`, which deletes the saved Keychain password and signs the
    /// reader out of the forum. The Account row says neither of those before the press, so this
    /// is the one place they are said.
    ///
    /// **Plain, where Remove's confirm is `.destructive`, and the difference is deliberate.** The
    /// row's icon says *this takes something away*; the dialog says exactly how much, and the
    /// weight of the confirm matches the weight of the act. A destructive Clear would be the
    /// confirmation repeating the row's overstatement, which is the one thing decision 29 asks
    /// not to happen.
    ///
    /// **The detail is the one seam of this dialog a test cannot reach** (risk 12).
    /// `clearDetailKey` is pure and is driven across all four combinations; what nothing verifies
    /// is that *this* closure asks it with `hasPassword` and `reachedSignIn` for the host being
    /// confirmed, because a `message:` builder only runs inside a presented dialog. Named here
    /// rather than left to be discovered.
    static func clear(_ session: ShellSession) -> HostQuestion {
        HostQuestion(
            session: session, asking: \.clearing,
            titleKey: "account.clear.title", confirmKey: "account.clear.confirm",
            role: nil,
            act: { await session.clear(host: $0) },
            detail: { host in
                L10n.t(SourceRow.clearDetailKey(
                    hasPassword: session.forums.hasPassword(host: host),
                    reachedSignIn: session.isSignedIn(host: host)
                ))
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Text(session[keyPath: asking].map { String(format: L10n.t(titleKey), $0) } ?? ""),
                isPresented: Binding(
                    get: { session[keyPath: asking] != nil },
                    set: { if !$0 { session[keyPath: asking] = nil } }
                ),
                // Explicit, because macOS draws no title at all on `.automatic` — and the title is
                // the only line that names which server this is about.
                titleVisibility: .visible,
                presenting: session[keyPath: asking]
            ) { host in
                Button(L10n.t(confirmKey), role: role) {
                    Task { await act(host) }
                }
                // **Cancel stays the default action.** No `.keyboardShortcut(.defaultAction)` on
                // the confirm: Return dismisses this question, it never answers it.
                Button(L10n.t("board.choose.cancel"), role: .cancel) { session[keyPath: asking] = nil }
            } message: { host in
                Text(detail(host))
            }
    }
}

/// A server ended a sign-in on its own side, said — out of the chain for `HostQuestion`'s reason.
private struct EndedSignInNotice: ViewModifier {
    let session: ShellSession

    func body(content: Content) -> some View {
        content
            // A server ended a sign-in on its own side: the row already reads signed out, and this
            // says why rather than leaving a timeline to go quiet.
            .alert(
                Text(L10n.t("account.mastodon.ended.title")),
                isPresented: Binding(
                    get: { !session.mastodon.ended.isEmpty },
                    set: { if !$0 { session.mastodon.endedSeen() } }
                )
            ) {
                Button(L10n.t("store.newer.ok"), role: .cancel) { session.mastodon.endedSeen() }
            } message: {
                Text(String(
                    format: L10n.t("account.mastodon.ended.detail"),
                    session.mastodon.ended.joined(separator: ", ")
                ))
            }
    }
}
