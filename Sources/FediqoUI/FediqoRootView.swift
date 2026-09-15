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
            .animation(.easeInOut(duration: 0.18), value: showingShortcuts)
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
            return onFocusedItem { decks.turn($0.id, of: $0.attachments.count) }
        case .liftCover:
            return onFocusedItem { item in
                guard item.covered else { return false }
                return decks.toggleCover(item.id)
            }
        // Named so the guide and the key list are honest; unit 7 gives them something to do.
        case .viewAttachment, .playAttachment:
            return false
        case .back:
            return popThread()
        case .showShortcuts:
            showingShortcuts.toggle()
            return true
        case .compose:
            guard availability.canCompose else { return false }
            showingShortcuts = false
            composing = true
            return true
        case .dismiss:
            if showingShortcuts {
                showingShortcuts = false
                return true
            }
            if popThread() { return true }
            if selectedItemID != nil {
                selectedItemID = nil
                return true
            }
            return false
        }
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
            selectedItemID = id
            return true
        case .post(let item):
            return act(item)
        }
    }

    /// j/k and the arrows walk whichever list is in front: the stream, or the open conversation.
    private func moveInList(by step: Int) -> Bool {
        guard place == .timeline, let ids = currentListIDs else { return false }
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
        guard place == .timeline, let selectedItemID else { return false }
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
                pageFor(item)
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
        pageFor(place)
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
                jumpToTop: jumpToTop,
                onPopThread: { _ = threadStack.popLast() }
            )
        case .notices: NoticesPane()
        case .account: AccountPane(session: session)
        case .usage: UsagePane()
        case .preferences: PreferencesPane()
        }
    }
}
