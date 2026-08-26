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
}

/// The tabs of the Statistics page.
///
/// Two, though the page has four groups of numbers, because it answers two questions and the
/// four are those two twice over: what is held here and what it costs, then what was asked of
/// other people and how much of it came back. How the numbers are counted is not a third: it
/// is a note, and a note belongs beside the number it explains rather than on a page of its
/// own that nobody would go to.
enum StatisticsTab: String, CaseIterable, Identifiable, Hashable {
    case storage, network

    var id: String { rawValue }
}

/// The tabs of the Settings page.
///
/// What Fediqo does not do with what it reads is not a fourth. It is read at the moment a
/// reader is looking at the servers they have added, which is what it is about, so it sits
/// under Sources rather than somewhere they would have to be sent.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case appearance, sources, keyboard

    var id: String { rawValue }
}

/// What the refreshing clock is keyed to: the feed being read, on the page it is being read
/// on, and how often. Change any of the three and the old clock is thrown away and a new one
/// started, which is the whole of how the refresh follows the reader and how turning it off
/// stops it. `tab` is `nil` on a page with no feed, so choosing a tab you cannot see — from
/// the Settings page, say — does not disturb a clock that is not running anyway.
struct RefreshKey: Hashable {
    var page: RailItem
    var timeline: String?
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
    /// Which timeline to open on, by id. The three a fresh install ships with are keyed by
    /// their template's name, so `trend` names one without anybody having to look it up.
    var timeline: String?
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
        // `trending` never named a page, and now it does not name a tab either — the tabs are
        // whatever timelines the reader has made. It still names exactly one screen, though,
        // and it is what everything that opens this app at one already asks for, so it keeps
        // working: the Timeline page, on the timeline seeded from the `trend` template.
        if ["trending", BaseSource.trend.rawValue].contains(environment["FEDIQO_RAIL"]) {
            options.railItem = .timeline
            options.timeline = BaseSource.trend.rawValue
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
    /// Which tab of each page is showing. They live here rather than in the screens so that
    /// leaving a page and coming back returns you to where you were on it, the same way
    /// `railItem` remembers the page — and, like the page, they are remembered for as long as
    /// the app is open rather than written down for the next launch.
    ///
    /// One property per page rather than one table keyed by page: a page's tabs are its own
    /// list and nothing else's, and a table would have to be read back out as a string and
    /// hoped into the right type.
    /// Which timeline the Timeline page is showing, by id. A string rather than a case,
    /// because the list is the reader's now: they make them, name them and delete them.
    var currentTimeline: String
    var statisticsTab: StatisticsTab = .storage
    var settingsTab: SettingsTab = .appearance
    /// Whether the composer is open. It belongs here rather than to the bar because the
    /// panel is drawn by the shell, over everything, and the bar only asks for it.
    var composing: Bool
    /// The two sheets the timeline puts up. They live here rather than in the screen for the
    /// same reason `composing` does: a menu item and a key have to be able to ask for them
    /// from outside the screen that draws them. The drawing stays where it was.
    var addingSource = false
    var showingNotifications = false
    /// The post whose whole self is open over the timeline, or nothing. It lives here rather
    /// than in the screen for the reason the sheets do: a key, a click and a menu item all
    /// have to be able to ask for it, and two of the three are outside the view that draws it.
    var expanded: Post?
    /// The conversation being read, where a post is open. It lives here rather than in the
    /// page for the reason the page itself does: the keys are answered outside the view, and
    /// while a post is open they belong to the conversation rather than to the list behind it.
    private(set) var thread: ThreadModel?
    /// How many times the reader has asked the deck on the selected row to turn over.
    private(set) var mediaTurns = 0
    /// The same, for asking it to play. Two counters rather than one command with an argument,
    /// because both are events the row hears rather than state anybody holds.
    private(set) var mediaPlays = 0
    /// What is playing, which is at most one thing anywhere in the app.
    let playback = Playback()
    /// Whether the written-down list of keys is up. It sits over everything the shell draws
    /// rather than in a sheet, so it lives here beside `composing` for the same reason: the
    /// key that opens it is answered outside the view that draws it.
    var showingShortcuts = false
    /// How the app opens a link, handed over by the shell.
    ///
    /// `openURL` is an environment value and this is not a view, but the key that opens a
    /// post is answered here, away from the row that draws it. So the shell lends its own —
    /// the same action the row's context menu uses — rather than this reaching for a way to
    /// open a URL of its own, which would be a second answer to a question the app has
    /// already answered.
    var openLink: ((URL) -> Void)?
    /// Whether a text field somewhere has the keyboard.
    ///
    /// SwiftUI has no such signal to read, so the app keeps one: the editor says when it
    /// takes the keyboard and when it gives it back, and every single-key shortcut asks
    /// here before doing anything. Without it `r` typed into a draft would refresh the
    /// timeline instead of writing a letter.
    private(set) var isTyping = false
    let holdsLanding: Bool

    private(set) var servers: [Server]

    /// The reader's timelines, left to right. Seeded on first run from the templates that
    /// ship, read back from the store on every launch after that, and the reader's own from
    /// the moment they exist — renameable, movable and deletable like anything else here.
    private(set) var timelines: [Timeline]

    /// The feeds outlive the screens that show them. `AppShell` swaps its detail with a
    /// `switch`, which destroys the previous view and everything it held — so a feed owned by
    /// the screen would re-ask every server on every trip to Settings and back.
    ///
    /// Built as they are first read rather than all at once: a reader with a dozen timelines
    /// is looking at one of them, and eleven loaders sitting ready is eleven sets of paging
    /// and backoff state kept for pages nobody has opened.
    private var feeds: [String: FeedModel] = [:]
    /// The chain of writes waiting on the store — see `write(_:)`.
    @ObservationIgnored private var writes: Task<Void, Never>?
    /// What every feed is built with, kept because the feeds are built later than this.
    private let secrets: any SecretStore
    private let tokens: TokenSource?

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
        self.secrets = secrets
        self.tokens = tokens
        // What a fresh install has before the store has answered — and, without a store, what
        // it has for good. The names are words in the reader's language, so they are made here
        // rather than in Core, which has none.
        self.timelines = Self.shipped()
        self.servers = servers.servers
        self.route = launch.route ?? .landing
        self.railItem = launch.railItem ?? .timeline
        self.currentTimeline = launch.timeline ?? BaseSource.public.rawValue
        self.composing = launch.composing
        self.holdsLanding = launch.holdsLanding
        L10n.use(preferences.language)
    }

    /// The timelines a fresh install starts with: the public timeline, and what the servers
    /// say is rising. Their ids are their templates' names, so that they are nameable from
    /// outside — a launch variable, a test — without anybody looking one up.
    ///
    /// **Home is not among them.** A device nobody is signed in on anywhere has no home to
    /// read, and a page that can only ever be empty is not something to hand a reader on
    /// their first launch. It arrives with the first account instead — once, and never again
    /// if they delete it.
    private static func shipped() -> [Timeline] {
        TimelineTemplate.shipped
            .filter { TimelineTemplate.named($0)?.source.needsAccount == false }
            .enumerated()
            .compactMap { position, name in made(from: name, position: position) }
    }

    /// One timeline from a template, carrying no words of its own.
    ///
    /// The name and the line under it are left empty on purpose: a timeline that ships with the
    /// app takes them from its template each time it is drawn, so Public and Trending are said
    /// in the language the reader has chosen rather than in whichever one happened to be on the
    /// day the row was written. The moment somebody types a name, the row keeps theirs.
    private static func made(from name: String, position: Int) -> Timeline? {
        guard let template = TimelineTemplate.named(name) else { return nil }
        return Timeline(id: name, name: "", summary: "", source: template.source,
                        template: name, position: position)
    }

    /// There is an account somewhere, so there is a home to read. If nobody has ever been
    /// offered a home timeline, this is the moment.
    ///
    /// Asked at launch as well as after a sign-in, because "somebody signed in" is a state and
    /// not only an event: a reader who signed in before this feature existed never had the
    /// moment, and would otherwise have to sign out and in again to be given a home.
    ///
    /// Offered once in the life of the app and marked as offered whether or not it is still
    /// there afterwards — a reader who deletes it has decided, and an app that put it back on
    /// the next launch would be arguing with them, once a launch, for ever.
    ///
    /// The rows are what is asked, not `SignInModel`: they are the store's own answer to who
    /// is signed in, they need neither the Keychain nor the network, and at launch they are
    /// there before anything has thought to read them.
    func offerHomeTimeline() async {
        guard !preferences.offeredHomeTimeline, let store else { return }
        let signedIn = (try? await store.signedInByServer())?.isEmpty == false
        guard signedIn, let home = Self.made(from: BaseSource.home.rawValue, position: timelines.count)
        else { return }
        preferences.offeredHomeTimeline = true
        // Where the three that ship sit relative to each other, not the end of the row.
        insert(home, at: TimelineTemplate.shipped.firstIndex(of: home.template) ?? timelines.count,
               opening: false)
    }

    /// The reader's timelines as the store has them, seeded on the first run that finds none.
    ///
    /// Called by the root view rather than `init`, for the reason `onLaunch` is: building an
    /// `AppState` — in a preview, in a test — must not be a round of database work.
    func openTimelines() async {
        guard let store else { return }
        do {
            try await store.seedTimelines(Self.shipped())
            // A store written by an older build has the app's own words in the rows it seeded,
            // in whichever language was on at the time. Cleared once, so those tabs follow the
            // language again; every seeded row afterwards is written with none.
            if !preferences.clearedSeededWording {
                try await store.clearSeededWording()
                preferences.clearedSeededWording = true
            }
            let kept = try await store.timelines()
            guard !kept.isEmpty else { return }
            timelines = kept
            // Before the reader is shown anything: an account that was signed in long before
            // there were timelines to make is still an account with a home behind it.
            await offerHomeTimeline()
            // The page the reader was on, if it is still one of them. A timeline deleted from
            // under the launch variable leaves the reader on the first one rather than on a
            // page that does not exist.
            if !kept.contains(where: { $0.id == currentTimeline }) {
                currentTimeline = kept[0].id
            }
        } catch {
            LocalStore.log.error("reading the timelines failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The other place a rejected token is noticed: every signed-in server is asked once,
    /// at launch, whether its credential still works. No store means no `signIn` at all,
    /// and so no check.
    ///
    /// It is the root view that calls this, not `init`, so that building an `AppState` —
    /// in a preview, in a test — is not itself a round of network requests.
    func onLaunch() async {
        // Who is signed in, first of all: the timelines are drawn from the first frame, and one
        // of them is readable only where there is an account. Rows only — no Keychain, no
        // network — so this costs a statement, and without it the Home tab would sit greyed out
        // on a device that has been signed in for months, until somebody opened Settings.
        await signIn?.refresh()
        // Then the timelines, because they are the tabs of the page about to be looked at.
        await openTimelines()
        guard let signIn else { return }
        await signIn.checkTokens(on: servers)
    }

    /// The feed reading `timeline`, built the first time it is asked for and kept afterwards.
    ///
    /// A timeline the reader has edited hands its new question to the feed that was already
    /// reading it, rather than starting a second one: the model is the page, and the page
    /// is still theirs — it is what it shows that changes.
    func feed(for timeline: Timeline) -> FeedModel {
        if let feed = feeds[timeline.id] {
            feed.timeline = timeline
            return feed
        }
        let feed = FeedModel(timeline: timeline, preferences: preferences,
                             loader: TimelineLoader(store: store, secrets: secrets, tokens: tokens))
        // A rejected token is noticed in two places, and both end in the same set. Reading is
        // the first: a server that turns a read's token down says so alongside the posts it
        // gave a stranger, and the row hears about it. One direction only — nothing here asks
        // the feed anything, and nothing polls.
        if let signIn { feed.onTokenRejected = { signIn.markRejected($0) } }
        feeds[timeline.id] = feed
        return feed
    }

    /// A loader to ask about one post's conversation with.
    ///
    /// The feed the reader is on, where there is one — its loader already knows the store and
    /// who is signed in, and a conversation is one more question for it rather than a reason
    /// to build a second one. A page opened from nowhere in particular gets a fresh loader,
    /// which is what a preview and a test have.
    func conversationLoader() -> TimelineLoader {
        readingFeed?.loader ?? TimelineLoader(store: store, secrets: secrets, tokens: tokens)
    }

    /// One of the reader's timelines by id, or nothing where the id names none.
    func timeline(_ id: String) -> Timeline? {
        timelines.first { $0.id == id }
    }

    // MARK: - The reader's timelines

    /// A timeline the reader made, put at the end of the row and opened.
    func add(_ timeline: Timeline) {
        insert(timeline, at: timelines.count)
    }

    /// A timeline put somewhere in particular, and opened. The row is renumbered so that what
    /// is on the screen and what is in the store are the same order.
    ///
    /// Home arrives through here rather than through `add`, because it is one of the three that
    /// ship and they have an order: the public timeline, then home, then what is rising. Home
    /// appears later than the other two — there is nothing to read until somebody signs in —
    /// and arriving late is no reason to sit at the end of a row it belongs in the middle of.
    /// `opening` is whether the reader is taken to it. They are where somebody asked to make
    /// one; they are not where a home timeline appears at launch because an account exists —
    /// arriving somewhere you did not ask to be is the app moving you, and a tab appearing in
    /// the row is enough of an announcement.
    func insert(_ timeline: Timeline, at index: Int, opening: Bool = true) {
        timelines.insert(timeline, at: min(max(index, 0), timelines.count))
        for position in timelines.indices { timelines[position].position = position }
        if opening { currentTimeline = timeline.id }
        // The renumbered one, not the argument: `position` is part of the row.
        if let made = timelines.first(where: { $0.id == timeline.id }) { persist(made) }
        persistOrder()
    }

    /// A timeline the reader edited. The feed reading it is handed the new question at the
    /// same moment, so a rule taken off changes the page rather than the next launch.
    func update(_ timeline: Timeline) {
        guard let at = timelines.firstIndex(where: { $0.id == timeline.id }) else { return }
        timelines[at] = timeline
        feeds[timeline.id]?.timeline = timeline
        persist(timeline)
    }

    /// A timeline the reader deleted, and the reading that was kept for it. Nothing else goes:
    /// a timeline was never where the posts were.
    func delete(_ id: String) {
        timelines.removeAll { $0.id == id }
        feeds[id] = nil
        if currentTimeline == id { currentTimeline = timelines.first?.id ?? "" }
        write { store in
            do { try await store.deleteTimeline(id) } catch {
                LocalStore.log.error("deleting a timeline failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// This timeline again under another name, and nothing shared with the one it came from:
    /// a copy is a copy, and editing it must not reach back into the original.
    func duplicate(_ timeline: Timeline) -> Timeline {
        // The copy is named after what the original is called on the screen, and keeps that
        // name: it is a timeline the reader made, and their copy of Public does not rename
        // itself when they change the app's language.
        let copy = Timeline(name: t("timeline.copy", timeline.displayName), summary: timeline.displaySummary,
                            source: timeline.source, account: timeline.account,
                            template: timeline.template, filters: timeline.filters)
        add(copy)
        return copy
    }

    /// The order the reader dragged them into.
    func move(_ id: String, to index: Int) {
        guard let from = timelines.firstIndex(where: { $0.id == id }) else { return }
        let moved = timelines.remove(at: from)
        timelines.insert(moved, at: min(max(index, 0), timelines.count))
        for position in timelines.indices { timelines[position].position = position }
        persistOrder()
    }

    /// The row's order, written down in one transaction so a list half reordered never reaches
    /// the next launch.
    private func persistOrder() {
        let order = timelines.map(\.id)
        write { store in
            do { try await store.reorderTimelines(order) } catch {
                LocalStore.log.error("reordering the timelines failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Written down, where there is anywhere to write it. Without a store the reader's
    /// timelines live as long as the app is open, the same way the servers did before #2.
    private func persist(_ timeline: Timeline) {
        write { store in
            do { try await store.save(timeline) } catch {
                LocalStore.log.error("saving a timeline failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// One write after another, in the order the reader made them, off the screen's own time.
    ///
    /// A chain rather than a task each. Making a timeline is two writes — the row, then the
    /// row's place in the order — and two independent tasks can land the second first, which
    /// writes an order for a row that is not there yet. Chaining also gives `startAgain`
    /// something to wait for: a save still in flight when the store is emptied would land in
    /// the fresh database and put a timeline back that the reader had just erased.
    private func write(_ work: @escaping @Sendable (LocalStore) async -> Void) {
        guard let store else { return }
        let queued = writes
        writes = Task { [store] in
            await queued?.value
            await work(store)
        }
    }

    /// Everything queued for the store, done. The reset waits on it; so does a test that means
    /// to read back what the screen has just changed.
    func settled() async {
        await writes?.value
    }

    /// The feed the reader is actually looking at: the visible tab of the visible page, and
    /// nothing at all on a page that has no tabs. Everything that asks "which feed is this"
    /// asks here, so the answer cannot be the page's and the tab's at once.
    ///
    /// Timeline is the one page divided by feed, and the tabs it is divided into are the
    /// feeds themselves. Kept reads the store, Statistics reads the store and the ledger, and
    /// Settings reads nobody: one screen each, and no feed on any of them.
    var readingTimeline: Timeline? {
        railItem == .timeline ? (timeline(currentTimeline) ?? timelines.first) : nil
    }

    /// The feed being read, ready to be asked something. Every key that moves through a
    /// timeline starts here, so "which feed" is answered once rather than four times.
    private var readingFeed: FeedModel? {
        readingTimeline.map { feed(for: $0) }
    }

    /// Whether anybody is signed in anywhere. What makes a home timeline readable, and so what
    /// says whether its tab is a place the reader can go at all.
    var signedInAnywhere: Bool { !(signIn?.accounts.isEmpty ?? true) }

    /// Whether this timeline has anywhere to read from as things stand. A home nobody is signed
    /// in to is not empty, it is unreachable — and a tab that can only ever be blank is worse
    /// than one that says why it is not available.
    func isReadable(_ timeline: Timeline) -> Bool {
        !timeline.source.needsAccount || signedInAnywhere
    }

    var refreshKey: RefreshKey {
        RefreshKey(page: railItem, timeline: readingTimeline?.id, interval: preferences.refreshInterval)
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
              let feed = readingFeed else { return }
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

    // MARK: - Starting again

    /// This device, as it was before Fediqo was ever opened.
    ///
    /// Every account signed out where a server will still take the revoke, every credential and
    /// app registration out of the Keychain, every row of the store gone and its schema built
    /// again, every preference back to its first-launch value, and the reader put back on the
    /// landing screen with the two timelines a fresh install ships with.
    ///
    /// The order is deliberate. Signing out first is the only step that needs the network and
    /// the rows at the same time — after the store is emptied there is nothing left to say who
    /// was signed in where, so a revoke attempted afterwards could not be addressed. Everything
    /// after it is local and cannot fail in a way worth stopping for: a server that will not
    /// take a revoke must not be able to keep somebody from clearing their own device.
    func startAgain() async {
        let leaving = servers
        if let signIn {
            await withTaskGroup(of: Void.self) { group in
                for server in leaving {
                    group.addTask { await signIn.signOut(of: server) }
                }
            }
        }
        for server in leaving {
            try? secrets.removeAppCredentials(for: server.endpoint)
        }
        serverStore.removeAll()
        servers = serverStore.servers
        // Whatever the screen has asked to be written, written — before the tables go. A save
        // still in flight would otherwise land in the fresh database.
        await settled()
        do {
            try await store?.eraseEverything()
        } catch {
            LocalStore.log.error("erasing the store failed: \(String(describing: error), privacy: .public)")
        }
        preferences.resetToDefaults()
        L10n.use(preferences.language)
        // Nothing kept from the reading that was: a feed holds posts, a place in them, and
        // where each server had got to, and none of that survives the store it came from.
        feeds = [:]
        await tokens?.invalidate()
        await signIn?.refresh()
        timelines = Self.shipped()
        currentTimeline = timelines.first?.id ?? ""
        railItem = .timeline
        // Written into the empty store, so the next launch finds them there rather than
        // seeding a second time.
        await openTimelines()
        route = .landing
    }

    func apply(language: AppLanguage) {
        preferences.language = language
        L10n.use(language)
    }

    /// One owner for opening and closing the composer, so the bar, the floating button and
    /// the panel itself cannot disagree about how it moves.
    func setComposing(_ open: Bool) {
        withAnimation(Motion.appearing) { composing = open }
        // The editor goes away with the panel, and it cannot report losing a keyboard it is
        // no longer there to hold. A signal left standing would leave every single key dead.
        if !open { isTyping = false }
    }

    func toggleComposer() {
        setComposing(!composing)
    }

    /// One owner for the list of keys, so the `?` key, the scrim behind it and its own Close
    /// button all move it the same way.
    func setShowingShortcuts(_ open: Bool) {
        withAnimation(Motion.appearing) { showingShortcuts = open }
    }

    /// Told by the one editor in the app, each time it takes or gives back the keyboard.
    func setTyping(_ typing: Bool) {
        isTyping = typing
    }

    // MARK: - Commands

    /// Does what a key or a menu item asked for, and says whether there was anything to do.
    ///
    /// The answer matters most for one key: `Tab` asks for the next tab, and a page with no
    /// tabs has none to give — so this returns `false` and the shell hands the press back to
    /// the focus system, which is what `Tab` is for everywhere else.
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
        case .nextPost: return moveSelection(by: 1)
        case .previousPost: return moveSelection(by: -1)
        case .expandPost: return expandSelectedPost()
        case .openInBrowser: return openSelectedPost()
        case .rotateMedia: return turnTheDeck()
        case .playMedia: return playTheAttachment()
        case .backToTop: return goToTop()
        case .showShortcuts: setShowingShortcuts(true); return true
        }
    }

    /// Moves the ring one post along the feed being read, and says whether it moved. A page
    /// with no feed has no posts to move through, and neither has a feed at the end the
    /// press was pointing at.
    ///
    /// The bottom is the one end that asks for something. `j` on the last post has nowhere to
    /// step to, so the servers are asked for what came before and the ring lands on the first
    /// post that arrives — the feed is what knows it is waiting, this is what has the servers.
    /// The press still answers `false`, because nothing moved: `↓` at the bottom of a list is
    /// still the scroll view's to answer.
    private func moveSelection(by steps: Int) -> Bool {
        // While a post is open, the keys belong to the conversation in front of the reader.
        // Moving the ring in the list behind it would be moving something they cannot see.
        if let thread { return thread.move(by: steps) }
        guard let feed = readingFeed else { return false }
        let moved = feed.moveSelection(by: steps)
        // Held down, `j` repeats twenty times a second against a ring that is still at the
        // end, and the reach already out would turn every one of those into nothing. Asking
        // the feed here rather than a task later is what keeps the repeat free.
        if feed.awaitingOlder, !feed.loadingOlder {
            Task { [servers] in await feed.loadOlder(servers: servers) }
        }
        return moved
    }

    /// Opens the whole of the post the ring is on, over the timeline, and says whether there
    /// was one to open.
    ///
    /// It is a place the reader goes to and comes back from: the timeline underneath keeps its
    /// scroll position and its ring, and `Escape` is the way back. What is opened is the post
    /// itself rather than its key, because the page has something to draw before anything is
    /// read back from the store or asked of anybody's server.
    private func expandSelectedPost() -> Bool {
        guard let post = readingFeed?.selectedPost else { return false }
        open(post)
        return true
    }

    /// One way in, whether a key or a click asked. The conversation is built here so that the
    /// keys have something to move through the moment the page is on screen.
    private func open(_ post: Post) {
        thread = ThreadModel(post: post, loader: conversationLoader())
        withAnimation(Motion.appearing) { expanded = post }
    }

    /// Opens a post the reader clicked, and puts the ring on it: they have said which post
    /// they mean, and coming back to a list whose ring is somewhere else would be the app
    /// disagreeing with them about where they are.
    func expand(_ post: Post) {
        readingFeed?.select(post)
        open(post)
    }

    /// Turns the deck of attachments on the post the ring is on. An event rather than a state:
    /// which attachment is on top belongs to the row that draws it, and pressing `m` twice
    /// means it twice — the same shape `topRequests` has.
    /// Plays what is on top of the deck on the post the ring is on — or stops it, if it is
    /// what is already playing. Says `false` where there is nothing that can be played, which
    /// includes every attachment stored before the file's own address was kept.
    private func playTheAttachment() -> Bool {
        // Anything at all playing is stopped by the key, wherever the ring happens to be:
        // a reader pressing `p` to stop the sound should not have to find the row it is
        // coming from first.
        if playback.playing != nil, postUnderTheRing?.attachments.contains(where: {
            playback.isPlaying($0.url)
        }) != true {
            playback.stop()
            return true
        }
        guard let post = postUnderTheRing, post.attachments.contains(where: \.isPlayable) else {
            return false
        }
        mediaPlays += 1
        return true
    }

    private func turnTheDeck() -> Bool {
        guard let post = postUnderTheRing, post.attachments.count > 1 else { return false }
        mediaTurns += 1
        return true
    }

    /// Hands the post the ring is on to the server it came from, and says whether there was
    /// one to hand over.
    ///
    /// A post whose server gave no web address has nothing to open, and this says nothing
    /// about it: there is no fault to report — the post simply is not a page anywhere — and
    /// a warning for it would be the app complaining about somebody else's server every
    /// time the reader pressed `Return` on the wrong row. The press is handed back instead,
    /// so the answer is at least visible to the focus system rather than swallowed.
    ///
    /// The answer is about the post and nothing else. Whether the shell has lent its way of
    /// opening a link is a different question, and answering both with one `false` would
    /// have `Return` mean "there was nothing there" when what happened was that we could not
    /// open it — so the loan is asked for at the point of opening, where it is used.
    private func openSelectedPost() -> Bool {
        guard let url = postUnderTheRing?.webURL else { return false }
        openLink?(url)
        return true
    }

    /// The post the ring is on, wherever the reader is: the one in the conversation while a
    /// post is open, and the one in the list otherwise. Every key that acts on "this post"
    /// asks here, so none of them can disagree about which post that is.
    private var postUnderTheRing: Post? {
        thread?.selected ?? readingFeed?.selectedPost
    }

    /// Back to the top of the feed being read. The screen does the scrolling; what happens
    /// here is that the ring is let go, so the reader is not told they are in two places.
    private func goToTop() -> Bool {
        guard let feed = readingFeed else { return false }
        feed.goToTop()
        return true
    }

    /// The page `steps` along the rail, wrapping at both ends.
    func rotatePage(by steps: Int) {
        railItem = rotated(RailItem.allCases, from: railItem, by: steps) ?? railItem
    }

    /// The tab `steps` along inside the page being looked at, wrapping at both ends. A page
    /// with no tabs has nothing to rotate and says so — which is what hands `Tab` back to the
    /// focus system on the one page that has none.
    ///
    /// Which page is being looked at is the whole of what decides it. The tabs themselves are
    /// three unrelated lists, so this asks the page rather than a list asking whether it is
    /// the one in front of the reader.
    @discardableResult
    func rotateTab(by steps: Int) -> Bool {
        switch railItem {
        case .timeline: rotateTimeline(by: steps)
        case .statistics: rotate(&statisticsTab, by: steps)
        case .settings: rotate(&settingsTab, by: steps)
        case .kept: false
        }
    }

    /// The timeline `steps` along the row, wrapping at both ends. Not `rotate` below, because
    /// the row is a list the reader built rather than a type's `allCases` — and a row of one
    /// has nowhere to go, which is what says `false` and hands `Tab` back to the focus system.
    private func rotateTimeline(by steps: Int) -> Bool {
        // Only the ones there is something to read in. A tab the row draws as unavailable is
        // not a place `Tab` should be able to land on either.
        let reachable = timelines.filter { isReadable($0) || $0.id == currentTimeline }
        guard reachable.count > 1 else { return false }
        guard let next = rotated(reachable.map(\.id), from: currentTimeline, by: steps) else { return false }
        currentTimeline = next
        return true
    }

    /// One rotation, whichever page's tabs it is over. `rotated` is the app's one rule for
    /// going round a list, and this is only what writing the answer back looks like.
    private func rotate<Tab>(_ tab: inout Tab, by steps: Int) -> Bool
    where Tab: CaseIterable & Equatable {
        guard let next = rotated(Array(Tab.allCases), from: tab, by: steps) else { return false }
        tab = next
        return true
    }

    /// Reads the feed being looked at again, now. The reader asked, so every server is asked
    /// whatever it did last time — that is what `.manual` means, and it is the default.
    /// A page with no feed has nothing to read again.
    private func refreshNow() -> Bool {
        guard let feed = readingFeed else { return false }
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
        // In front of the composer, because it is drawn over it. The two are up together
        // whenever the reader has let go of the field: `?` is a character while the field
        // holds the keyboard, so the list can only have been asked for from a draft nobody
        // is typing into — and the press that closes it must not take that draft with it.
        if showingShortcuts {
            setShowingShortcuts(false)
            return true
        }
        if composing {
            setComposing(false)
            return true
        }
        // Last, because it is the thing furthest back: the composer floats over the opened
        // post as it floats over everything else, and one press closes one thing.
        guard expanded != nil else { return false }
        withAnimation(Motion.appearing) { expanded = nil }
        playback.stop()
        // The conversation goes with the page. What it read is in the store; what it held was
        // one reading of it, and the next opening starts from the store as this one did.
        thread = nil
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
            // No scrollbar, anywhere — see `fediqoWithoutScrollbars`, which is where the two
            // platforms' answers to that are kept.
            //
            // Said here rather than at each `ScrollView`, for the reason this whole modifier
            // exists: the decision has one owner, and one line to change if it is ever
            // revisited. Not one it cannot escape — a new top-level presentation that
            // forgets `fediqoChrome` loses the scrollbar rule exactly as it loses the locale
            // and the text scale, and the answer to that is the same as it is for those two:
            // a presentation applies this, and the environment carries it down from there.
            .fediqoWithoutScrollbars()
    }
}
