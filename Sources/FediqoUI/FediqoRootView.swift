import SwiftUI

/// The dummy shell: places on the left, the current page on the right, compose over it.
public struct FediqoRootView: View {
    @State private var place: ShellPlace = .timeline
    @State private var timelineID = DummyTimeline.shipped[0].id
    @State private var selectedItemID: String?
    @State private var openedItemID: String?
    @State private var jumpToTop = 0
    @State private var composing = false
    @State private var showingShortcuts = false
    @State private var railExpanded = false
    @State private var prefs = DummyPrefs()
    @Environment(\.colorScheme) private var colorScheme

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    public init() {}

    public var body: some View {
        layout
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
            character, shift: shift, control: control, typing: composing
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
            place = DummyCommand.advanced(ShellPlace.allCases, from: place, by: 1)
            return true
        case .previousPage:
            place = DummyCommand.advanced(ShellPlace.allCases, from: place, by: -1)
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
            guard openedItemID != nil else { return false }
            openedItemID = nil
            return true
        case .showShortcuts:
            showingShortcuts.toggle()
            return true
        case .compose:
            showingShortcuts = false
            composing = true
            return true
        case .dismiss:
            if showingShortcuts {
                showingShortcuts = false
                return true
            }
            if openedItemID != nil {
                openedItemID = nil
                return true
            }
            if selectedItemID != nil {
                selectedItemID = nil
                return true
            }
            return false
        }
    }

    private func moveInList(by step: Int) -> Bool {
        guard place == .timeline, openedItemID == nil else { return false }
        let ids = DummyTimeline(id: timelineID).items.map(\.id)
        let next = DummyCommand.stepped(ids, from: selectedItemID, by: step)
        guard let next else { return false }
        selectedItemID = next
        return true
    }

    private func jumpListOrThreadToTop() -> Bool {
        guard place == .timeline else { return false }
        if openedItemID == nil {
            guard let first = DummyTimeline(id: timelineID).items.first else { return false }
            selectedItemID = first.id
        }
        jumpToTop += 1
        return true
    }

    private func openThread() -> Bool {
        guard place == .timeline, openedItemID == nil, let selectedItemID else { return false }
        openedItemID = selectedItemID
        return true
    }

    /// Tab only rotates named queries on the timeline. Elsewhere it is the platform's.
    private func rotateTimelineTab(by step: Int) -> Bool {
        guard place == .timeline else { return false }
        timelineID = DummyCommand.advanced(
            DummyTimeline.shipped.map(\.id), from: timelineID, by: step
        )
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
                place: $place,
                expanded: $railExpanded,
                currentSource: .signedIn,
                onCompose: { composing = true }
            )
            Rectangle()
                .fill(ShellChrome.hairline(colorScheme))
                .frame(width: 1)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ShellChrome.page(colorScheme))
        }
        .frame(minWidth: 520, minHeight: 360)
        .background(ShellChrome.page(colorScheme))
    }

    #if os(iOS)
    private var tabbed: some View {
        TabView(selection: $place) {
            ForEach(ShellPlace.allCases) { item in
                pageFor(item)
                    .tabItem { Label(item.title, systemImage: item.symbolName) }
                    .tag(item)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button { composing = true } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3.weight(.semibold))
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(ShellChrome.phosphor(colorScheme)))
                    .foregroundStyle(ShellChrome.page(colorScheme))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 20)
            .padding(.bottom, 72)
            .accessibilityLabel(L10n.t("compose.title"))
        }
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
                timelineID: $timelineID,
                selectedID: $selectedItemID,
                openedID: $openedItemID,
                jumpToTop: jumpToTop
            )
        case .notices: NoticesPane()
        case .account: AccountPane(source: .signedIn)
        case .usage: UsagePane()
        case .preferences: PreferencesPane()
        }
    }
}
