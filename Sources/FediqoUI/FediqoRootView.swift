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
    @State private var prefs = DummyPrefs()
    @Environment(\.colorScheme) private var colorScheme

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

    private var currentListIDs: [String]? {
        if let opened = threadStack.last, let item = streamItems.first(where: { $0.id == opened }) {
            return item.dummyConversation().inOrder.map(\.id)
        }
        let ids = streamItems.map(\.id)
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
