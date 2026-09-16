import FediqoCore
import SwiftUI

/// Places on the left, the current page on the right, compose over it.
public struct FediqoRootView: View {
    @State private var session: ShellSession
    @State private var place: ShellPlace = .launch
    @State private var selectedItemID: String?
    @State private var threadStack: [String] = []
    @State private var jumpToTop = 0
    @State private var composing = false
    @State private var showingShortcuts = false
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
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

    public init(http: any HTTPClient = URLSessionClient()) {
        _session = State(initialValue: ShellSession(http: http))
    }

    private var availability: ShellAvailability { session.availability }

    /// Whether the join sheet is up, derived from the stage rather than stored beside it.
    ///
    /// Written out here rather than inline, because a `Binding` built inside the modifier chain
    /// pushes `body` past what the type-checker will solve in reasonable time.
    private var stagePresented: Binding<Bool> {
        Binding(
            get: { session.stage != nil },
            set: { shown in if !shown { session.dismissStage() } }
        )
    }

    public var body: some View {
        layout
            .onChange(of: place) { old, new in
                let accepted = availability.placing(old, as: new)
                if accepted != new { place = accepted }
                guard accepted != old else { return }
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
            .sheet(isPresented: $composing) {
                ComposerSheet()
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    #endif
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
                        // **The same two lines as the sheet below, and they have to be.** A
                        // sign-in that was reached goes straight back to the join: the reader
                        // typed a host, was turned away, went and signed in, and the errand was
                        // always "add this forum". Without the retry the window closes onto the
                        // refusal it was opened from, which reads as a sign-in that did nothing.
                        //
                        // **`resumeAfterSignIn` and not `add`**, because `add` stops at the
                        // preview — a screen this reader has already read and already answered.
                        // They pressed Subscribe before they were turned away; this finishes that
                        // press rather than asking for it again.
                        //
                        // **And the `if` is not only "was it reached".** A sign-in pressed on a
                        // row of a server already joined is an errand that ends with the sign-in
                        // itself, and `signInFinished` says no to those — see its doc comment for
                        // what the reader sees instead, and for what this branch shipped without
                        // it.
                        //
                        // This branch lost both the retry and the host when the page moved out of
                        // the sheet — the window was given the body the sheet had at the time,
                        // and the sheet grew them afterwards. Whatever is done to one of these
                        // two callbacks belongs in the other on the same day.
                        if session.signInFinished(reached: reached, host: request.host) {
                            Task { await session.resumeAfterSignIn() }
                        }
                    }
                } else {
                    signInWindows.close()
                }
            }
            #else
            .sheet(item: $session.signingIn) { request in
                ForumSignInSheet(request: request, sessions: session.forums) { reached in
                    // **A sign-in that was reached goes straight back to the join.** The reader
                    // typed a host, was turned away, and went and signed in; the errand was
                    // always "add this forum", and landing them at an empty field having lost
                    // what they typed would make them start it again. This second pass goes
                    // through the browser that now holds the session — see `ShellSession.joiner`.
                    //
                    // **`resumeAfterSignIn` and not `add`**: the preview is a question this
                    // reader has already answered, so the retry finishes the press instead of
                    // asking for it a second time.
                    //
                    // **And the `if` is not only "was it reached".** A sign-in pressed on a row
                    // of a server already joined ends with the sign-in itself, and
                    // `signInFinished` says no to those — see its doc comment.
                    if session.signInFinished(reached: reached, host: request.host) {
                        Task { await session.resumeAfterSignIn() }
                    }
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
            // **The Remove question, on the root beside the other three presenters**, and for the
            // same documented reason: one presenter driven by one piece of session state survives
            // a second call site. Remove is asked from a source row today and will be asked from
            // the source page's own header the day that grows one.
            //
            // It is asked at all because Remove takes the board picks the reader made, and
            // `ShellSession.clear`'s comment is the argument: pictures come back by themselves, a
            // pick of eight boards out of forty does not.
            .confirmationDialog(
                Text(session.removing.map { String(format: L10n.t("account.remove.title"), $0) } ?? ""),
                isPresented: Binding(
                    get: { session.removing != nil },
                    set: { if !$0 { session.removing = nil } }
                ),
                // Explicit, because macOS draws no title at all on `.automatic` — and the title is
                // the only line that names which server this is about.
                titleVisibility: .visible,
                presenting: session.removing
            ) { host in
                Button(L10n.t("account.remove.confirm"), role: .destructive) {
                    Task { await session.remove(host: host) }
                }
                // **Cancel stays the default action.** No `.keyboardShortcut(.defaultAction)` on
                // the destructive button: Return dismisses this question, it never answers it.
                Button(L10n.t("board.choose.cancel"), role: .cancel) { session.removing = nil }
            } message: { host in
                Text(Self.removeDetail(for: host, in: session.sources))
            }
            .overlay {
                if showingShortcuts {
                    ShortcutGuide { showingShortcuts = false }
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
                if phase == .active { wakeTheCaches() }
            }
            .dummyShellKeys { character, shift, control in
                performDummyKey(character, shift: shift, control: control)
            }
            .environment(prefs)
            // **The session, for the panes that are handed no binding.** `PreferencesPane` reads
            // it out of the environment, and without this it is nil on every real launch — so the
            // pane draws its empty state and tells a reader who has already joined a server to go
            // and add one. A pane whose whole purpose is not to say a false thing, saying one.
            //
            // A hand-off rather than a local need: this view is the only place that holds the
            // session, so it is the only place that can put it there. See `PLAN.md`, Cross-worktree
            // hand-offs.
            .environment(session)
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

    private func performDummyKey(_ character: Character, shift: Bool, control: Bool) -> Bool {
        guard let command = DummyCommand.from(
            character,
            shift: shift,
            control: control,
            typing: composing,
            fieldFocused: session.searchFocused
        ) else {
            return false
        }
        let did = apply(command)
        return DummyCommand.consumes(character, did: did)
    }

    private func apply(_ command: DummyCommand) -> Bool {
        // Before any rule reads `openLayers`, so no press can act on a viewer that is not there.
        forgetAVanishedViewer()
        switch command {
        case .nextTab:
            return rotateTimelineTab(by: 1)
        case .previousTab:
            return rotateTimelineTab(by: -1)
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
            let inViewer = viewedItem != nil
            return onActedItem { item in
                let turned = decks.turn(item.id, of: item.attachments.count)
                guard turned else { return false }
                // Sound out of a card the reader has just turned away from is a fault, and so is
                // a thumbnail still moving after it has stopped being the thumbnail. Only where
                // something actually turned: a deck of one leaves nothing behind to stop.
                playback.stop()
                // And the viewer stops holding the card it has turned away from. Without this,
                // `v` and three presses of `m` on a post carrying four pictures hold four
                // addresses at viewer tier, which is the contract broken by ordinary use.
                if inViewer { ShellPictures.shared.releaseViewerTier() }
                return true
            }
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
            case .thread: return popThread()
            case .shortcuts, .selection, nil: return false
            }
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
        case .compose:
            guard availability.canCompose else { return false }
            showingShortcuts = false
            composing = true
            return true
        case .dismiss:
            switch DummyCommand.outermost(of: openLayers) {
            case .viewer: return closeViewer()
            case .shortcuts:
                showingShortcuts = false
                return true
            case .thread: return popThread()
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
        case .thread: !threadStack.isEmpty
        case .selection: selectedItemID != nil
        }
    }

    /// Opens what is on top of the focused row's deck, over the whole app.
    ///
    /// A second `v` while it is open does nothing. `Escape` and `q` are how this is left, and one
    /// key that both opens and closes a layer is the conditional rule the order above is kept
    /// free of. The letter is still ours either way — see `DummyCommand.consumes`.
    private func openViewer() -> Bool {
        guard viewedItem == nil,
              DummyCommand.canOpen(.viewer, whenOpen: openLayers) else { return false }
        return onFocusedItem { item in
            guard decks.showing(item.attachments, of: item.id) != nil else { return false }
            // Whatever the row was playing stops. It would go on playing behind an opaque ground
            // where nobody can see it or stop it, which is the "sound from a row that has scrolled
            // off" fault arriving by another route.
            playback.stop()
            viewing = item.id
            return true
        }
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
                onGone: { playback.stop() },
                onClose: { _ = closeViewer() }
            )
        }
    }

    /// What the author wrote on the cover, or what to say where they flagged it and wrote nothing.
    /// The same two cases the row draws, because it is the same line.
    private func coverLine(of item: DummyItem) -> String {
        let spoiler = item.spoiler ?? ""
        return spoiler.isEmpty ? L10n.t("item.covered.title") : spoiler
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
        guard place == .timeline, let ids = currentListIDs else { return false }
        // Entering the selection obeys the entry rule the same as any other layer. Moving an
        // existing one does not — the lamp is already on, and `j` means move rather than enter.
        // With a thread or the viewer open the selection is always already on, so in practice
        // this only ever refuses a first press under the guide.
        if selectedItemID == nil,
           !DummyCommand.canOpen(.selection, whenOpen: openLayers) { return false }
        let next = DummyCommand.stepped(ids, from: selectedItemID, by: step)
        guard let next else { return false }
        selectedItemID = next
        return true
    }

    /// **Resolved out of the session's list, not rebuilt from the id.** A board query knows which
    /// board it is by carrying it; an id alone says only that it is one. Reconstructing here
    /// would give the keys a stream that matched no note, so `j` and `k` would move through
    /// nothing on exactly the tabs this unit added. See `ShellSession.timeline(for:)`.
    private var streamItems: [DummyItem] {
        session.timeline(for: session.timelineID).items(from: session.notes, among: session.sources)
    }

    /// Whichever list is in front: the open conversation, or the stream under it.
    private var currentListItems: [DummyItem] {
        if let opened = threadStack.last, let item = streamItems.first(where: { $0.id == opened }) {
            return item.dummyConversation().inOrder
        }
        return streamItems
    }

    private var currentListIDs: [String]? {
        let ids = currentListItems.map(\.id)
        return ids.isEmpty ? nil : ids
    }

    private func jumpListOrThreadToTop() -> Bool {
        guard place == .timeline else { return false }
        if let opened = threadStack.last, let item = streamItems.first(where: { $0.id == opened }) {
            selectedItemID = item.id
        } else {
            guard let first = streamItems.first else { return false }
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
                Task { await session.posts.fetchReplies(thread) }
                return true
            case .nothing:
                return false
            }
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
    ///    `wantsPressing` is where "asking again could change the answer" already lives.
    ///
    /// **`standing(of:)` stamps interest, and that is fine here.** It is the same read the pane's
    /// body makes on every pass; stamping more often can only make an entry look *less* stale to
    /// the eviction predicate. What I8 forbids is a band that stops reading, not one read twice.
    private func repliesWanted(of item: DummyItem) -> Bool {
        guard place == .timeline, viewedItem == nil, threadStack.last == item.id,
              let thread = ForumThreadRef(item)
        else { return false }
        return session.posts.standing(of: thread).wantsPressing
    }

    private func openThread() -> Bool {
        guard place == .timeline, let selectedItemID,
              DummyCommand.canOpen(.thread, whenOpen: openLayers) else { return false }
        if threadStack.last == selectedItemID { return false }
        threadStack.append(selectedItemID)
        return true
    }

    private func popThread() -> Bool {
        guard !threadStack.isEmpty else { return false }
        threadStack.removeLast()
        return true
    }

    private var openedThread: Binding<String?> {
        Binding(
            get: { threadStack.last },
            set: { newValue in
                if newValue == nil { threadStack = [] }
            }
        )
    }

    /// Tab only rotates named queries on the timeline. Elsewhere it is the platform's.
    private func rotateTimelineTab(by step: Int) -> Bool {
        guard place == .timeline else { return false }
        let ids = session.queries.map(\.id)
        guard !ids.isEmpty else { return false }
        let current = session.timelineID ?? ids[0]
        session.timelineID = DummyCommand.advanced(ids, from: current, by: step)
        return true
    }

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if sizeClass == .compact {
            tabbed
        } else {
            columns
        }
        #else
        columns
        #endif
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
        .frame(minWidth: 520, minHeight: 360)
        .background(ShellChrome.page(colorScheme))
    }

    /// Rejects a disabled destination so compact TabView snaps back.
    private var placeBinding: Binding<ShellPlace> {
        Binding(
            get: { place },
            set: { place = availability.placing(place, as: $0) }
        )
    }

    #if os(iOS)
    private enum Compact {
        static let button: CGFloat = 56
        /// Clear of the tab bar, which the overlay knows nothing about.
        static let clearance: CGFloat = 72
    }

    /// A phone gets tabs instead of a rail, and only for the places it can enter.
    /// A tab bar has no disabled state worth the name: tapping a dead tab selected it,
    /// the binding put it back, and the reader was told nothing at all. A place that
    /// is not ready is not a tab yet.
    private var tabbed: some View {
        TabView(selection: $place) {
            ForEach(availability.enabledPlaces) { item in
                placedPage(item)
                    .tabItem { Label(item.title, systemImage: item.symbolName) }
                    .tag(item)
            }
        }
        .tint(ShellChrome.phosphor(colorScheme))
        .overlay(alignment: .bottomTrailing) {
            if availability.canCompose { composeButton }
        }
    }

    /// Solid ink, not phosphor: the lamp says where the reader is, and a button that
    /// writes a post is not a place. It is here only when it can be pressed.
    private var composeButton: some View {
        Button { composing = true } label: {
            Image(systemName: "square.and.pencil")
                .font(.title3.weight(.semibold))
                .frame(width: Compact.button, height: Compact.button)
                .background(Circle().fill(ShellChrome.ink(colorScheme)))
                .foregroundStyle(ShellChrome.page(colorScheme))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("compose.title"))
        .padding(.trailing, ShellSpace.room)
        .padding(.bottom, Compact.clearance)
    }
    #endif

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
                openedID: openedThread,
                decks: $decks,
                playback: playback,
                onPlayRow: playRow,
                jumpToTop: jumpToTop,
                onPopThread: { _ = threadStack.popLast() }
            )
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
