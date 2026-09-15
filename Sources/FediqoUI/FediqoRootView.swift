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
        case .liftCover:
            // **Blurs in place and never navigates.** Not "toggle, and also close the viewer if
            // that leaves nothing to show" — a conditional rule inside the layer order is the
            // named risk, and the blur at size is what confirms the press took. Two intents, two
            // keys: `Escape` is still how a reader leaves.
            return onActedItem { item in
                guard item.covered else { return false }
                return decks.toggleCover(item.id)
            }
        case .viewAttachment:
            return openViewer()
        case .playAttachment:
            return playFocused()
        case .back:
            // `q` leaves what is in front of it and reaches past nothing — the same one
            // expression of the order `Escape` reads. It used to intersect a local subset of the
            // layers, which was the order written down a second time.
            switch DummyCommand.outermost(of: openLayers) {
            case .viewer: return closeViewer()
            case .thread: return popThread()
            default: return false
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
                onToggleCover: { _ = apply(.liftCover) },
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

    private var streamItems: [DummyItem] {
        DummyTimeline(id: session.timelineID ?? "").items(from: session.notes)
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
