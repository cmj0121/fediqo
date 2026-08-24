#if os(macOS)
import SwiftUI

/// The menu bar, which on a Mac is the only place a reader looks for a shortcut — and a menu
/// can only show one that carries a modifier. So every single key has a `⌘` form here beside
/// it, and the two ask the app for the same thing rather than each doing it their own way.
///
/// It lives in `FediqoUI` rather than in the app target because `.commands` belongs to the
/// scene, which is outside the view tree: the app target owns the scene, and everything the
/// menu names — the pages, the feeds, the preferences — lives here.
public struct FediqoCommands: Commands {
    private let app: AppState

    public init(app: AppState) {
        self.app = app
    }

    public var body: some Commands {
        // Settings is a page rather than a window, so the item AppKit expects in the app menu
        // goes to that page. ⌘4 does the same thing from the Go menu; ⌘, is where a Mac user
        // looks for it.
        CommandGroup(replacing: .appSettings) {
            Button(t("menu.settings")) { app.railItem = .settings }
                .keyboardShortcut(",")
        }
        // Nothing here makes a document, so the File > New that AppKit assumes is a lie. What
        // this app makes is a post, and that is what the slot is worth.
        CommandGroup(replacing: .newItem) {
            Button(t("menu.newPost")) { app.setComposing(true) }
                .keyboardShortcut("n")
        }
        CommandMenu(t("menu.go")) { pages }
        CommandMenu(t("rail.timeline")) { timelineItems }
    }

    /// The four pages, numbered in the order the rail lists them.
    private var pages: some View {
        ForEach(Array(RailItem.allCases.enumerated()), id: \.element) { index, page in
            Button(t(page.titleKey)) { app.railItem = page }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
        }
    }

    /// What can be done to the feed being read. Every one of these belongs to the public
    /// timeline and is drawn by its header, so on any other page they are shown as what they
    /// are there: unavailable, rather than absent or silently doing nothing.
    private var timelineItems: some View {
        @Bindable var preferences = app.preferences
        let reading = app.feedMode == .timeline
        return Group {
            Button(t("menu.readAgain")) { app.refreshNow() }
                .keyboardShortcut("r")
                .disabled(app.feedMode == nil)
            Button(t("timeline.notifications")) { app.showingNotifications = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!reading)
            Button(t("timeline.addSource")) { app.addingSource = true }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!reading)
            Divider()
            Toggle(t("timeline.filter.boosts"), isOn: $preferences.showBoosts)
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!reading)
            Toggle(t("timeline.filter.mediaOnly"), isOn: $preferences.showMediaOnly)
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!reading)
        }
    }
}
#endif
