import Observation
import SwiftUI
import os
import FediqoCore

enum Route: Hashable {
    case landing
    case protocolPicker
    case serverPicker(SocialProtocol)
    case shell
}

/// The places the action bar can take you. New Post is not among them: composing is
/// something you do from wherever you already are, so it is the last button on the bar
/// rather than one of its destinations.
enum RailItem: String, CaseIterable, Identifiable, Hashable {
    case timeline, trending, kept, settings

    var id: String { rawValue }

    var titleKey: String { "rail.\(rawValue)" }

    var symbolName: String {
        switch self {
        case .timeline: "list.bullet.rectangle"
        case .trending: "chart.line.uptrend.xyaxis"
        case .kept: "bookmark"
        case .settings: "gearshape"
        }
    }
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
        options.railItem = environment["FEDIQO_RAIL"].flatMap(RailItem.init(rawValue:))
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

    var route: Route
    var railItem: RailItem
    /// Whether the composer is open. It belongs here rather than to the bar because the
    /// panel is drawn by the shell, over everything, and the bar only asks for it.
    var composing: Bool
    let holdsLanding: Bool

    private(set) var servers: [Server]

    /// The feeds outlive the screens that show them. `AppShell` swaps its detail with a
    /// `switch`, which destroys the previous view and everything it held — so a feed owned by
    /// the screen would re-ask every server on every trip to Settings and back.
    private let feeds: [FeedMode: FeedModel]

    public convenience init() {
        self.init(store: Self.openStore(), launch: .fromEnvironment())
    }

    init(preferences: Preferences = Preferences(), serverStore: (any ServerStore)? = nil,
         store: LocalStore? = nil, launch: LaunchOptions = .none) {
        // The chosen servers live in the store when there is one; without it the app falls
        // back to the list it kept before the store existed, and keeps remembering there.
        let servers = serverStore ?? store.map { SQLiteServerStore(store: $0) } ?? UserDefaultsServerStore()
        self.preferences = preferences
        self.serverStore = servers
        self.feeds = [
            .timeline: FeedModel(mode: .timeline, loader: TimelineLoader(store: store)),
            .trending: FeedModel(mode: .trending, loader: TimelineLoader(store: store)),
        ]
        self.servers = servers.servers
        self.route = launch.route ?? .landing
        self.railItem = launch.railItem ?? .timeline
        self.composing = launch.composing
        self.holdsLanding = launch.holdsLanding
        L10n.use(preferences.language)
    }

    /// The database at `<Application Support>/Fediqo/store.sqlite`. The store never blocks the
    /// screen: a file that is not a database is set aside and replaced; anything else means the
    /// app runs without a store and simply remembers nothing.
    private static func openStore() -> LocalStore? {
        var path = "<Application Support>/Fediqo/store.sqlite"
        do {
            let directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Fediqo", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appending(path: "store.sqlite").path(percentEncoded: false)
            return try LocalStore.openRecovering(path: path)
        } catch {
            Logger(subsystem: "fediqo", category: "store")
                .error("could not open \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func feed(for mode: FeedMode) -> FeedModel {
        feeds[mode]!
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
        serverStore.remove(server)
        servers = serverStore.servers
        if servers.isEmpty { route = .protocolPicker }
    }

    func forgetAllServers() {
        serverStore.removeAll()
        servers = serverStore.servers
        route = .protocolPicker
    }

    func apply(language: AppLanguage) {
        preferences.language = language
        L10n.use(language)
    }

    /// One owner for opening and closing the composer, so the bar, the floating button and
    /// the panel itself cannot disagree about how it moves.
    func setComposing(_ open: Bool) {
        withAnimation(.easeOut(duration: 0.15)) { composing = open }
    }

    func toggleComposer() {
        setComposing(!composing)
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
