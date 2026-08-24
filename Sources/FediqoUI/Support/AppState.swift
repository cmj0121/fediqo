import Observation
import SwiftUI
import FediqoCore

enum Route: Hashable {
    case landing
    case protocolPicker
    case serverPicker(SocialProtocol)
    case shell
}

/// A page: one of the main categories, and the places the action bar can take you. New Post
/// is not among them: composing is something you do from wherever you already are, so it is
/// the last button on the bar rather than one of its destinations.
///
/// Trending is not here. It was never a category of its own — it is another timeline, so it
/// is a tab inside the Timeline page rather than a fifth thing in the rail.
enum RailItem: String, CaseIterable, Identifiable, Hashable {
    case timeline, kept, statistics, settings

    var id: String { rawValue }

    var titleKey: String { "rail.\(rawValue)" }

    var symbolName: String {
        switch self {
        case .timeline: "list.bullet.rectangle"
        case .kept: "bookmark"
        // The rising line belongs to the Trending tab, and it means "what is happening out
        // there". This page is the other kind of chart: bars of what is already here.
        case .statistics: "chart.bar.xaxis"
        case .settings: "gearshape"
        }
    }

    /// The sub-categories inside this page, in the order the reader meets them. Only the
    /// Timeline page has any, and its two are the two feeds themselves — `FeedMode` already
    /// says which stream is being asked for, so a tab is one of those rather than a second
    /// enum saying the same thing beside it.
    ///
    /// So the type says more than the concept does: a tab is a sub-category, and it is only
    /// because the one page that has tabs divides itself by feed that `[FeedMode]` can stand
    /// for the list. A page whose tabs are not feeds would need a wider type — and there is
    /// no such page, so there is no such type until there is.
    ///
    /// Kept reads the store, Statistics reads the store and the ledger, and Settings reads
    /// nobody: one screen each, and no feed on any of them.
    var tabs: [FeedMode] {
        switch self {
        case .timeline: FeedMode.allCases
        case .kept, .statistics, .settings: []
        }
    }
}

/// What the refreshing clock is keyed to: the feed being read, on the page it is being read
/// on, and how often. Change any of the three and the old clock is thrown away and a new one
/// started, which is the whole of how the refresh follows the reader and how turning it off
/// stops it. `tab` is `nil` on a page with no feed, so choosing a tab you cannot see — from
/// the Settings page, say — does not disturb a clock that is not running anyway.
struct RefreshKey: Hashable {
    var page: RailItem
    var tab: FeedMode?
    var interval: RefreshInterval
}

/// A way to open the app somewhere other than the beginning, so each screen can be looked at
/// without clicking through the ones before it.
///
/// Parsed once, from one place, and passed in — so `AppState` can be built at any screen in a
/// test or a preview without touching the process environment, and so nothing downstream
/// reads a global to decide what to draw.
struct LaunchOptions {
    var route: Route?
    var railItem: RailItem?
    var feedTab: FeedMode?
    var composing = false
    /// Whether the landing screen should sit still instead of handing over on its own.
    var holdsLanding = false

    static let none = LaunchOptions()

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchOptions {
        #if DEBUG
        var options = LaunchOptions()
        switch environment["FEDIQO_ROUTE"] {
        case "landing":
            options.route = .landing
            options.holdsLanding = true
        case "protocol": options.route = .protocolPicker
        case "server": options.route = .serverPicker(.mastodon)
        case "shell": options.route = .shell
        default: break
        }
        // `trending` no longer names a page, but it is what everything that opens this app at
        // a screen — the screenshot workflow above all — already asks for, and it still names
        // exactly one thing to look at. So it keeps working, and means the Timeline page on
        // its Trending tab. There is no second variable: one name, one screen.
        if environment["FEDIQO_RAIL"] == FeedMode.trending.rawValue {
            options.railItem = .timeline
            options.feedTab = .trending
        } else {
            options.railItem = environment["FEDIQO_RAIL"].flatMap(RailItem.init(rawValue:))
        }
        options.composing = environment["FEDIQO_COMPOSE"] == "1"
        return options
        #else
        .none
        #endif
    }
}

/// What the app is showing and what it is reading. One object so the shell, the pickers and
/// the settings screen all agree, and so the store behind it can be swapped for #2's.
@MainActor
@Observable
public final class AppState {
    public let preferences: Preferences
    let serverStore: any ServerStore
    /// The store itself, for the one screen that asks about the store rather than through
    /// it. Nothing else here reads it: posts go in and out via the feeds. `nil` when the
    /// app is running without one, and the screen says so instead of showing zeroes.
    let store: LocalStore?
    /// Signing in needs the store to remember the fact; without one the buttons are absent.
    let signIn: SignInModel?

    var route: Route
    var railItem: RailItem
    /// Which tab of the Timeline page is showing. It lives here rather than in the screen so
    /// that leaving the page and coming back returns you to the feed you were reading, the
    /// same way `railItem` remembers the page — and, like the page, it is remembered for as
    /// long as the app is open rather than written down for the next launch.
    var feedTab: FeedMode
    /// Whether the composer is open. It belongs here rather than to the bar because the
    /// panel is drawn by the shell, over everything, and the bar only asks for it.
    var composing: Bool
    /// The two sheets the timeline puts up. They live here rather than in the screen for the
    /// same reason `composing` does: a menu item and a key have to be able to ask for them
    /// from outside the screen that draws them. The drawing stays where it was.
    var addingSource = false
    var showingNotifications = false
    /// Whether a text field somewhere has the keyboard.
    ///
    /// SwiftUI has no such signal to read, so the app keeps one: the editor says when it
    /// takes the keyboard and when it gives it back, and every single-key shortcut asks
    /// here before doing anything. Without it `r` typed into a draft would refresh the
    /// timeline instead of writing a letter.
    private(set) var isTyping = false
    let holdsLanding: Bool

    private(set) var servers: [Server]

    /// The feeds outlive the screens that show them. `AppShell` swaps its detail with a
    /// `switch`, which destroys the previous view and everything it held — so a feed owned by
    /// the screen would re-ask every server on every trip to Settings and back.
    private let feeds: [FeedMode: FeedModel]

    public convenience init() {
        self.init(store: LocalStore.openDefault(), launch: .fromEnvironment())
    }

    init(preferences: Preferences = Preferences(), serverStore: (any ServerStore)? = nil,
         store: LocalStore? = nil, launch: LaunchOptions = .none) {
        // Counting starts when the app does, so that "since" is a moment the screen can name
        // rather than whichever request happened to be sent first.
        _ = APILedger.shared
        // The chosen servers live in the store when there is one; without it the app falls
        // back to the list it kept before the store existed, and keeps remembering there.
        let servers = serverStore ?? store.map { SQLiteServerStore(store: $0) } ?? UserDefaultsServerStore()
        // One answer to who we are, shared by everything that asks: both feeds and the launch
        // check. One each would mean a sign-in invalidating only its own — the other two would
        // go on reading as a stranger from a cache that says nobody is signed in, until relaunch.
        let secrets = KeychainSecretStore()
        let tokens = store.map { TokenSource(store: $0, secrets: secrets) }
        let signIn = store.map { SignInModel(store: $0, secrets: secrets, tokens: tokens) }
        self.preferences = preferences
        self.serverStore = servers
        self.store = store
        self.signIn = signIn
        self.feeds = [
            .timeline: FeedModel(mode: .timeline, loader: TimelineLoader(store: store, secrets: secrets, tokens: tokens)),
            .trending: FeedModel(mode: .trending, loader: TimelineLoader(store: store, secrets: secrets, tokens: tokens)),
        ]
        self.servers = servers.servers
        self.route = launch.route ?? .landing
        self.railItem = launch.railItem ?? .timeline
        self.feedTab = launch.feedTab ?? .timeline
        self.composing = launch.composing
        self.holdsLanding = launch.holdsLanding
        L10n.use(preferences.language)

        // A rejected token is noticed in two places, and both end in the same set. Reading
        // is the first: a server that turns a read's token down says so alongside the posts
        // it gave a stranger, and the row hears about it. One direction only — nothing here
        // asks the feed anything, and nothing polls.
        if let signIn {
            for feed in self.feeds.values {
                feed.onTokenRejected = { signIn.markRejected($0) }
            }
        }
    }

    /// The other place a rejected token is noticed: every signed-in server is asked once,
    /// at launch, whether its credential still works. No store means no `signIn` at all,
    /// and so no check.
    ///
    /// It is the root view that calls this, not `init`, so that building an `AppState` —
    /// in a preview, in a test — is not itself a round of network requests.
    func onLaunch() async {
        guard let signIn else { return }
        await signIn.checkTokens(on: servers)
    }

    func feed(for mode: FeedMode) -> FeedModel {
        feeds[mode]!
    }

    /// The feed the reader is actually looking at: the visible tab of the visible page, and
    /// nothing at all on a page that has no tabs. Everything that asks "which feed is this"
    /// asks here, so the answer cannot be the page's and the tab's at once.
    var feedMode: FeedMode? {
        railItem.tabs.contains(feedTab) ? feedTab : nil
    }

    var refreshKey: RefreshKey {
        RefreshKey(page: railItem, tab: feedMode, interval: preferences.refreshInterval)
    }

    /// Reads the page you are looking at again, every so often, for as long as it is the
    /// page you are looking at. Fediqo is a guest on other people's machines: a timeline
    /// nobody is watching costs nobody's server anything, so this refreshes one feed and no
    /// other, and stops the moment the reader goes somewhere else.
    ///
    /// The shell holds it in a `.task` keyed to the page, the tab and the interval, so
    /// changing any of them cancels this and starts the next — there is only ever one, and
    /// none at all on a page without a feed or with the clock turned off. It sleeps before it
    /// does anything, so the screen's own first load always goes first.
    func refreshWhileVisible() async {
        guard let interval = preferences.refreshInterval.duration,
              let mode = feedMode else { return }
        let feed = feed(for: mode)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            // A tick that lands while the last load is still out is dropped rather than
            // queued: a server slower than the interval must not collect a queue of readers
            // waiting on it, and the load already running is about to say the same thing.
            // With no sources there is nothing to ask, and a spinner every interval would be
            // the only thing that happened.
            guard !feed.loading, !servers.isEmpty else { continue }
            await feed.load(servers: servers, refresh: .automatic(every: interval))
        }
    }

    /// Where the landing screen hands over to: a fresh install has to choose a source, an
    /// install that already has one goes straight to the timeline.
    func leaveLanding() {
        route = servers.isEmpty ? .protocolPicker : .shell
    }

    func add(_ server: Server) {
        serverStore.add(server)
        servers = serverStore.servers
    }

    func remove(_ server: Server) {
        signOutInBackground([server])
        serverStore.remove(server)
        servers = serverStore.servers
        if servers.isEmpty { route = .protocolPicker }
    }

    func forgetAllServers() {
        signOutInBackground(servers)
        serverStore.removeAll()
        servers = serverStore.servers
        route = .protocolPicker
    }

    /// Leaving a server signs its accounts out first (decision 8); the revoke is
    /// best-effort (decision 6), so the list itself never waits on a server answering —
    /// and each server's revoke is independent of the others, so they run concurrently.
    private func signOutInBackground(_ leaving: [Server]) {
        guard let signIn else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for server in leaving {
                    group.addTask { await signIn.signOut(of: server) }
                }
            }
        }
    }

    func apply(language: AppLanguage) {
        preferences.language = language
        L10n.use(language)
    }

    /// One owner for opening and closing the composer, so the bar, the floating button and
    /// the panel itself cannot disagree about how it moves.
    func setComposing(_ open: Bool) {
        withAnimation(.easeOut(duration: 0.15)) { composing = open }
        // The editor goes away with the panel, and it cannot report losing a keyboard it is
        // no longer there to hold. A signal left standing would leave every single key dead.
        if !open { isTyping = false }
    }

    func toggleComposer() {
        setComposing(!composing)
    }

    /// Told by the one editor in the app, each time it takes or gives back the keyboard.
    func setTyping(_ typing: Bool) {
        isTyping = typing
    }

    // MARK: - Commands

    /// Does what a press asked for, and says whether the press was ours to keep.
    ///
    /// A key we understand is ours whether or not it had anything to do. Handing one back
    /// because it changed nothing is worse than swallowing it: `⌃Tab` on a page with no tabs
    /// went on to AppKit, which spends it on window tabs this app does not have, and the
    /// window it was pressed in was folded into a set and lost.
    ///
    /// `Escape` is the exception, and the reason the distinction is worth keeping. With
    /// nothing in front of you it was never ours — the platform may still have a use for it,
    /// and a press that dismissed nothing must not be reported as a dismissal.
    func consumes(_ command: KeyCommand) -> Bool {
        let did = perform(command)
        return command == .dismiss ? did : true
    }

    /// Does what a key or a menu item asked for, and says whether there was anything to do.
    ///
    /// The answer matters for one key: ⌃Tab asks for the next tab, and a page with no
    /// tabs has none to give — so this returns `false` and the shell lets the press through
    /// rather than swallowing a key that did nothing.
    @discardableResult
    func perform(_ command: KeyCommand) -> Bool {
        switch command {
        case .refreshNow: return refreshNow()
        case .cycleRefreshInterval: cycleRefreshInterval(); return true
        case .compose: setComposing(true); return true
        case .dismiss: return dismissFront()
        case .nextTab: return rotateTab(by: 1)
        case .previousTab: return rotateTab(by: -1)
        case .nextPage: rotatePage(by: 1); return true
        case .previousPage: rotatePage(by: -1); return true
        }
    }

    /// The page `steps` along the rail, wrapping at both ends.
    func rotatePage(by steps: Int) {
        railItem = rotated(RailItem.allCases, from: railItem, by: steps) ?? railItem
    }

    /// The tab `steps` along inside the page being looked at, wrapping at both ends. A page
    /// with no tabs has nothing to rotate and says so.
    @discardableResult
    func rotateTab(by steps: Int) -> Bool {
        let tabs = railItem.tabs
        guard let next = rotated(tabs, from: feedTab, by: steps) else { return false }
        feedTab = next
        return true
    }

    /// Reads the feed being looked at again, now. The reader asked, so every server is asked
    /// whatever it did last time — that is what `.manual` means, and it is the default.
    /// A page with no feed has nothing to read again.
    @discardableResult
    func refreshNow() -> Bool {
        guard let mode = feedMode else { return false }
        let feed = feed(for: mode)
        Task { await feed.load(servers: servers) }
        return true
    }

    /// Off → 15s → 30s → 60s → 5min → Off, which is the order the cases are written in and
    /// the order the preferences screen shows them in.
    func cycleRefreshInterval() {
        preferences.refreshInterval =
            rotated(RefreshInterval.allCases, from: preferences.refreshInterval, by: 1) ?? .off
    }

    /// What `Escape` does: the thing in front of you goes away, and nothing else happens —
    /// it never takes you somewhere else.
    ///
    /// The sheets are not listed here on purpose. They are the platform's own presentations
    /// and it closes them on `Escape` itself; closing them here as well would be one press
    /// dismissing two things.
    @discardableResult
    func dismissFront() -> Bool {
        guard composing else { return false }
        setComposing(false)
        return true
    }
}

/// Everything a presented view needs that the environment does not carry across a sheet or
/// an overlay. Written once, so a new one cannot quietly be missing half of it.
extension View {
    @MainActor
    func fediqoChrome(_ app: AppState) -> some View {
        environment(app)
            .environment(\.fediqoTextScale, app.preferences.textScale.factor)
            .environment(\.locale, app.preferences.language.locale ?? .autoupdatingCurrent)
    }
}
