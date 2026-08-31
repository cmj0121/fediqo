import Observation
import SwiftUI
import FediqoCore
#if os(macOS)
import AppKit
#endif

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
        case .kept: "archivebox"
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
    /// Read an invented world instead of the network — see `Fixture`. What a screenshot is
    /// taken of, and the only launch option that changes where the posts come from rather
    /// than which screen is showing.
    var fixture = false

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
        options.fixture = environment["FEDIQO_FIXTURE"] == "1"
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
    /// The conversations being read, oldest first, empty while the reader is in the list.
    ///
    /// A stack rather than one, because a conversation is a place a reader walks *into*.
    /// `Space` on a reply opens that reply's own thread over this one, and `Escape` comes back
    /// out a step at a time — so the way down and the way back up are the same path, and a
    /// reader four replies deep can retrace it rather than being dropped at the timeline.
    ///
    /// It lives here rather than in the page for the reason the page itself does: the keys are
    /// answered outside the view, and while a post is open they belong to the conversation
    /// rather than to the list behind it.
    private(set) var threads: [ThreadModel] = []

    /// The conversation in front of the reader — the top of the stack — or nothing.
    var thread: ThreadModel? { threads.last }

    /// The post whose whole self is open over the timeline, or nothing.
    ///
    /// Read by the screen that draws the page and by nobody who sets it: which post is open is
    /// whichever one the top of the stack is a conversation around, and two places holding
    /// that answer would be two places to get it wrong.
    var expanded: Post? { threads.last?.root }
    /// How many times the reader has asked the deck on the selected row to turn over.
    private(set) var mediaTurns = 0
    /// The same, for asking it to play. Two counters rather than one command with an argument,
    /// because both are events the row hears rather than state anybody holds.
    private(set) var mediaPlays = 0
    /// And the same again, for asking the row to lift what its author covered or put it back.
    ///
    /// A third counter rather than a piece of state here, for the reason the other two are
    /// counters: which posts a reader chose to look behind is a reading record, and this app
    /// keeps none. The answer lives in the row for as long as the row does and is written
    /// down nowhere — so the key is an event the row hears, not a fact the app holds.
    private(set) var mediaCovers = 0
    /// What each visible post is marked with, for whichever account acts. Held here rather
    /// than in the rows because a page is read from the store in one go, and because an action
    /// on the opened post has to move the row in the list behind it.
    var postMarks: [String: PostMarks] = [:]
    /// What a post's numbers are now, where a write's own answer has said something newer than
    /// the post arrived with.
    ///
    /// Keyed like `postMarks` and for the same reason: a star pressed on the opened post has to
    /// move the number on the row in the list behind it, and the two are different values of
    /// the same post. Never added up here — the server's answer carries the new number, and
    /// adding one to what the post arrived with would count a reader who had already favourited
    /// it somewhere else twice.
    var postCounts: [String: Counts] = [:]
    /// Which of the three marks a write is still out for, per post.
    ///
    /// Two things read it. Between the press and the server answering, this app believes
    /// something the store has not been told yet, and a page read landing in that gap would
    /// otherwise put the star back — see `loadMarks`. And the row draws it: a mark that goes to
    /// somebody else's machine takes as long as that machine takes, and the control says so
    /// while it waits.
    ///
    /// By action rather than by post, so the one that was pressed is the one that shows it. A
    /// reader who boosts a post and then stars it while the boost is still out should see two
    /// controls working, not one control speaking for both.
    var actingOn: [String: Set<PostAction>] = [:]
    /// Which visible posts this device is holding on to. A set and not a mark, because keeping
    /// is not an account's answer — it is this machine's.
    var keptPosts: Set<String> = []
    /// The reader's standing mutes, both kinds and both places.
    var mutes: [Mute] = []
    /// Posts already reported this run, so a control can stop offering.
    var reported: Set<String> = []
    /// What went wrong with the last thing the reader asked for, for the screen to say.
    var actionFailure: SourceFailure?
    /// The server that was last asked to go and fetch a post so an action could be sent.
    ///
    /// Kept so it can be said out loud. It is the one thing this app does that tells somebody
    /// else what is being read, and a reader who has allowed it should still see it happen
    /// rather than find out from a changelog.
    var lastReachedOut: String?
    /// The steps between a press and the store, which are Core's and not a screen's. Built
    /// once beside the loaders and from the same two things, so an action and a read cannot
    /// come to disagree about which client speaks which protocol.
    @ObservationIgnored private(set) lazy var postActions =
        PostActions(registry: registry, store: store)
    /// What is playing, which is at most one thing anywhere in the app.
    let playback = Playback()
    /// The attachment the reader has opened over the app, or nothing. It lives here rather
    /// than in the row for the reason `expanded` does: a key, a press and the shell that draws
    /// it are three places, and only one of them is the row.
    var viewing: MediaViewing?
    /// Whether **this app** put the window into full screen for the opened picture. Kept so
    /// that leaving the picture leaves the screen it took — and so that a reader who was
    /// already in full screen before any of this is left exactly where they were.
    private(set) var tookTheScreen = false
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
    /// Whether this run is reading the invented world rather than the reader's own.
    ///
    /// Nothing about a screen depends on it — the fixture is a `SourceClient` like any other,
    /// and everything above it does its actual work. What reads it is the window: a run that
    /// exists to be photographed, or driven by a test, wants to open the same size in the same
    /// place every time, and a reader's window wants to open where they left it.
    let isFixture: Bool

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
    // `internal`: the acting layer lives in Timeline/PostActing.swift and needs to resolve a
    // credential for the account that is about to act.
    let tokens: TokenSource?
    /// Who reads each protocol. The standard set in every build anybody ships; the fixture's
    /// invented world when a screenshot is being taken. It is carried here rather than
    /// defaulted at each feed so that one answer covers the timelines and the conversations.
    private let registry: SourceRegistry

    public convenience init() {
        let launch = LaunchOptions.fromEnvironment()
        #if DEBUG
        if launch.fixture, let store = try? LocalStore.inMemory() {
            // A store nobody's disk holds, preferences nobody's machine has set, and servers
            // that are not the reader's: a screenshot must say the same thing on a laptop
            // that has been signed in to three servers for a year as on a fresh runner.
            let defaults = UserDefaults(suiteName: "fediqo.fixture")
            defaults?.removePersistentDomain(forName: "fediqo.fixture")
            self.init(preferences: Preferences(defaults: defaults ?? .standard),
                      serverStore: FixtureServerStore(), store: store, launch: launch,
                      registry: SourceRegistry(clients: [.mastodon: FixtureSource()]))
            return
        }
        #endif
        self.init(store: LocalStore.openDefault(), launch: launch)
    }

    init(preferences: Preferences = Preferences(), serverStore: (any ServerStore)? = nil,
         store: LocalStore? = nil, launch: LaunchOptions = .none,
         registry: SourceRegistry = .standard(), secrets: (any SecretStore)? = nil) {
        // Counting starts when the app does, so that "since" is a moment the screen can name
        // rather than whichever request happened to be sent first.
        _ = APILedger.shared
        // The chosen servers live in the store when there is one; without it the app falls
        // back to the list it kept before the store existed, and keeps remembering there.
        let servers = serverStore ?? store.map { SQLiteServerStore(store: $0) } ?? UserDefaultsServerStore()
        // One answer to who we are, shared by everything that asks: both feeds and the launch
        // check. One each would mean a sign-in invalidating only its own — the other two would
        // go on reading as a stranger from a cache that says nobody is signed in, until relaunch.
        // The Keychain unless somebody hands over something else. A test that acts as an
        // account needs a credential to act with, and the one thing it must not do is reach
        // for the reader's own — so this is the seam, and nothing but a test uses it.
        let secrets = secrets ?? KeychainSecretStore()
        let tokens = store.map { TokenSource(store: $0, secrets: secrets) }
        let signIn = store.map { SignInModel(store: $0, secrets: secrets, tokens: tokens) }
        self.preferences = preferences
        self.serverStore = servers
        self.store = store
        self.signIn = signIn
        self.secrets = secrets
        self.tokens = tokens
        self.registry = registry
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
        self.isFixture = launch.fixture
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
        let feed = FeedModel(timeline: timeline, preferences: preferences, loader: loader())
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
        readingFeed?.loader ?? loader()
    }

    /// One loader, built the one way. Every caller went through the same four arguments
    /// before the registry became a fifth, and a fifth spelled out twice is a fifth that
    /// eventually differs in one of the two places.
    private func loader() -> TimelineLoader {
        TimelineLoader(registry: registry, store: store, secrets: secrets, tokens: tokens)
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
        case .openMedia: return openTheMedia()
        case .fullScreen: return takeTheScreen()
        case .rotateMedia: return turnTheDeck()
        case .playMedia: return playTheAttachment()
        case .toggleCover: return turnTheCover()
        case .favouritePost: return mark(.favourite)
        case .boostPost: return mark(.reblog)
        case .bookmarkPost: return mark(.bookmark)
        case .keepPost: return keepThePost()
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

    /// Favourites, boosts or bookmarks the post the ring is on, and says whether there was one
    /// to do it to.
    ///
    /// The press answers the moment there is a post, not when the server does. It has to: a
    /// key is answered in the same instant a click on the same mark is, and the acting itself
    /// is a round trip to somebody else's machine. What comes back of it is the row's — the
    /// mark moves and moves back on its own — and what comes back of a refusal is
    /// `ActionNotice`'s, which is the whole reason a key that fails is no longer silent.
    ///
    /// `postUnderTheRing` and not the feed's own selection, so that the four keys work inside
    /// an opened conversation as well: the ring there is the conversation's, and a reader
    /// reading a reply should be able to keep it without going back to the list first.
    private func mark(_ action: PostAction) -> Bool {
        guard let post = postUnderTheRing else { return false }
        Task { await act(action, on: post) }
        return true
    }

    /// Keeps the post the ring is on, or lets it go. No server is told and none can refuse,
    /// so unlike the three above this one only ever fails on our own database.
    private func keepThePost() -> Bool {
        guard let post = postUnderTheRing else { return false }
        Task { await keep(post) }
        return true
    }

    /// Opens the whole of the post the ring is on, over the timeline, and says whether there
    /// was one to open.
    ///
    /// It is a place the reader goes to and comes back from: the timeline underneath keeps its
    /// scroll position and its ring, and `Escape` is the way back. What is opened is the post
    /// itself rather than its key, because the page has something to draw before anything is
    /// read back from the store or asked of anybody's server.
    /// `postUnderTheRing` and not the feed's own selection, so that the key means the same
    /// thing wherever the reader is: open the conversation around the post the ring is on.
    /// Inside an opened thread that is the reply `j`/`k` walked to, and opening it puts its
    /// conversation over this one.
    ///
    /// The post the open thread is already built around is the one press this refuses. There
    /// is nothing to open — the reader is looking at that conversation — and a level that
    /// repeated the one under it would be a step back you have to take twice.
    private func expandSelectedPost() -> Bool {
        guard let post = postUnderTheRing, post.mergeKey != thread?.root.mergeKey else {
            return false
        }
        open(post)
        return true
    }

    /// One way in, whether a key or a click asked. The conversation is built here so that the
    /// keys have something to move through the moment the page is on screen.
    private func open(_ post: Post) {
        withAnimation(Motion.appearing) {
            threads.append(ThreadModel(post: post, loader: conversationLoader()))
        }
    }

    /// Opens a post the reader clicked, and puts the ring on it: they have said which post
    /// they mean, and coming back to a list whose ring is somewhere else would be the app
    /// disagreeing with them about where they are.
    ///
    /// A click comes from the list, which is only ever behind the whole stack, so it starts a
    /// new one rather than adding to whatever was left standing.
    func expand(_ post: Post) {
        readingFeed?.select(post)
        threads = []
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

    /// Lifts what the post under the ring covered, or puts it back.
    ///
    /// A post whose author covered nothing has nothing to lift, and the press does nothing
    /// rather than pretending: `false` here is the same "there was nothing to do" that
    /// turning a deck of one attachment gives. It is still the reader's key either way — a
    /// letter is ours whatever it did — so nothing beeps.
    ///
    /// It says nothing about which way the row will go. That belongs to the row: the row is
    /// what holds this reader's answer about this post, and asking it here would mean two
    /// places holding one decision.
    private func turnTheCover() -> Bool {
        guard postUnderTheRing?.hidesSomething == true else { return false }
        mediaCovers += 1
        return true
    }

    /// Opens what is attached to the post the ring is on, or closes what is open.
    ///
    /// It opens at the front of the deck rather than at whatever the row happens to be
    /// showing: which card is on top belongs to the row, and asking it here would mean two
    /// places holding one answer. `m` turns it once it is open, which is the same key it was
    /// before, doing the same thing to the same deck.
    private func openTheMedia() -> Bool {
        if viewing != nil { return closeTheMedia() }
        guard let post = postUnderTheRing, !post.attachments.isEmpty else { return false }
        show(post.attachments, at: 0, covered: post.sensitive == true)
        return true
    }

    /// Opens a picture the reader pressed, at the one they were looking at.
    func show(_ attachments: [Attachment], at index: Int, covered: Bool) {
        guard !attachments.isEmpty else { return }
        withAnimation(Motion.appearing) {
            viewing = MediaViewing(attachments: attachments, index: index, covered: covered)
        }
    }

    /// Gives the opened picture the whole screen, or hands it back. Nothing at all where
    /// there is no picture open, and nothing on a platform whose windows have no such state:
    /// on a phone the app already has the screen.
    private func takeTheScreen() -> Bool {
        guard viewing != nil else { return false }
        #if os(macOS)
        guard let window = NSApplication.shared.keyWindow else { return false }
        window.toggleFullScreen(nil)
        tookTheScreen.toggle()
        return true
        #else
        return false
        #endif
    }

    /// Closes the opened picture, and gives back the screen if this app took it.
    @discardableResult
    func closeTheMedia() -> Bool {
        guard viewing != nil else { return false }
        #if os(macOS)
        if tookTheScreen, let window = NSApplication.shared.keyWindow {
            window.toggleFullScreen(nil)
        }
        #endif
        tookTheScreen = false
        withAnimation(Motion.appearing) { viewing = nil }
        // What was playing in it was playing in front of the reader; it does not go on
        // playing behind them.
        playback.stop()
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
        // In front of the composer as well: the picture is drawn over the whole app, so it
        // is what a press of Escape is aimed at while it is up.
        if viewing != nil { return closeTheMedia() }
        if composing {
            setComposing(false)
            return true
        }
        // Last, because it is the thing furthest back: the composer floats over the opened
        // post as it floats over everything else, and one press closes one thing.
        //
        // One level, not the stack. A reader who opened a reply's thread from inside another
        // one asked for two steps and gets to take them back one at a time; the last of them
        // is the one that returns them to the list, which still has its scroll position and
        // its ring.
        guard !threads.isEmpty else { return false }
        withAnimation(Motion.appearing) { threads.removeLast() }
        playback.stop()
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
