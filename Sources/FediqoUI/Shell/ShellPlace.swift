import FediqoCore
import SwiftUI

/// A destination in the shell. Compose is not one: it is an action over the current page.
public enum ShellPlace: String, CaseIterable, Identifiable, Hashable, Sendable {
    case timeline
    /// What is rising on the sources: their trending posts, hashtags and links, a tab each
    /// (decision 1). Only where some source has one of them; see `ShellAvailability.railPlaces`.
    case trends
    case notices
    case account
    case usage
    case preferences

    public var id: String { rawValue }

    /// Where the shell stands before the store has answered, and where a launch holding nothing
    /// stays. A reader holding a source is moved to the timeline once the store has been read;
    /// see `ShellLaunch`.
    public static let launch: ShellPlace = .account

    var title: String { title(language: nil) }

    /// The name in one language, where a caller must not read the shell's: a test asking both
    /// languages side by side with other suites, which may not set the global to do it (#141).
    func title(language: DummyLanguage?) -> String {
        switch self {
        case .timeline: L10n.t("shell.timeline.title", language: language)
        case .trends: L10n.t("shell.trends.title", language: language)
        case .notices: L10n.t("shell.notices.title", language: language)
        case .account: L10n.t("shell.account.title", language: language)
        case .usage: L10n.t("shell.usage.title", language: language)
        case .preferences: L10n.t("shell.preferences.title", language: language)
        }
    }

    /// What the action is for. Shown on the rail when it is expanded; collapsed, it is help.
    var summary: String {
        switch self {
        case .timeline: L10n.t("shell.timeline.summary")
        case .trends: L10n.t("shell.trends.summary")
        case .notices: L10n.t("shell.notices.summary")
        case .account: L10n.t("shell.account.summary")
        case .usage: L10n.t("shell.usage.summary")
        case .preferences: L10n.t("shell.preferences.summary")
        }
    }

    var symbolName: String {
        switch self {
        case .timeline: "list.bullet.rectangle"
        // The glyph the Trends tab of the timeline led with, which the place is now.
        case .trends: "chart.line.uptrend.xyaxis"
        case .notices: "bell"
        // Decision 32. Several things stacked into one, which is the README's own picture —
        // several sources go in and one timeline comes out — and it matches the geometric register
        // of `list.bullet.rectangle` beside it. It also frees `person.crop.circle`, which the
        // designer found meaning three different things with two of them on the Account page at
        // once; with the row's sign-in now a `key`, it has no caller left in FediqoUI.
        case .account: "square.stack.3d.up"
        case .usage: "chart.bar.xaxis"
        case .preferences: "gearshape"
        }
    }

    /// Whether the place draws a stream of posts: the timeline, and Trends on its Posts tab.
    /// **Each keeps its own walk and lamp** (`StreamSides`), and the session follows the one in
    /// front (`ShellSession.stream`).
    var isStream: Bool { self == .timeline || self == .trends }
}

/// Which of the two stream places the session follows (DESIGN-trends, option C): the one the
/// reader last stood on, kept while they are on a place that draws no stream.
enum ShellStream: Hashable, Sendable {
    case timeline, trends

    init?(_ place: ShellPlace) {
        switch place {
        case .timeline: self = .timeline
        case .trends: self = .trends
        case .notices, .account, .usage, .preferences: return nil
        }
    }

    /// The other stream place's.
    var other: ShellStream {
        switch self {
        case .timeline: .trends
        case .trends: .timeline
        }
    }

    /// The place that draws this stream.
    var place: ShellPlace {
        switch self {
        case .timeline: .timeline
        case .trends: .trends
        }
    }
}

/// What one stream place keeps while the reader is on the other (DESIGN-trends, Root): its walk,
/// its lamp, and the row that was at the top of its list.
struct StreamSide: Hashable, Sendable {
    var walk = ShellWalk()
    var lamp: String?
    var top: String?
}

/// Each stream place's own side, so a thread opened on Trends is not under the timeline, and
/// the lamp of one is not the other's. **Held by the root for the run**, as the walk was.
struct StreamSides: Hashable, Sendable {
    private var timeline = StreamSide()
    private var trends = StreamSide()

    subscript(stream: ShellStream) -> StreamSide {
        get {
            switch stream {
            case .timeline: timeline
            case .trends: trends
            }
        }
        set {
            switch stream {
            case .timeline: timeline = newValue
            case .trends: trends = newValue
            }
        }
    }

    /// The session leaving `from` to follow `to`: the row at the top of the list left kept on
    /// its side, and the row at the top of the one arrived at handed back. **A page read out of
    /// a post is left with the side it was opened on** (#169): there is one reader to draw it,
    /// in front of the stream followed, so that step is taken back — its lamp given back — and
    /// whether one was is said, for the root to close the reader. The rest of each walk stays.
    mutating func follow(from: ShellStream, to: ShellStream, top: String?) -> (top: String?, leftLink: Bool) {
        guard from != to else { return (top, false) }
        var leaving = self[from]
        let leftLink = leaving.walk.openedLink != nil
        if leftLink, let back = leaving.walk.back() { leaving.lamp = back.lamp }
        leaving.top = top
        self[from] = leaving
        return (self[to].top, leftLink)
    }

    /// Whether the page of the person `id` names is a step of either side's walk.
    func holdsPerson(_ id: String) -> Bool {
        timeline.walk.holdsPerson(id) || trends.walk.holdsPerson(id)
    }

    /// Whether the page of `tag` is a step of either side's walk.
    func holdsTag(_ tag: PostTag) -> Bool {
        timeline.walk.holdsTag(tag) || trends.walk.holdsTag(tag)
    }
}

/// What this session has, used to enable the rail. Compose is not a place.
struct ShellAvailability: Hashable, Sendable {
    var queryIDs: Set<String> = []
    var signedIn = false
    /// The tabs Trends has, in their order (`TrendsTab.tabs(in:)`): none where no source has
    /// trending posts, hashtags or links, and then there is no Trends.
    var trendsTabs: [TrendsTab] = []

    static let empty = ShellAvailability()

    var canCompose: Bool { signedIn }

    /// **`all` is what a timeline needs, and `trends` is no longer part of the answer.**
    ///
    /// This used to require both, which was true while every joinable source was a microblog.
    /// A Discourse has no trending read at all, so a Discourse-only store is offered All alone — the
    /// timelines are All and Trends, and a forum's boards only choose what is fetched. Asking for
    /// `trends` here would close the Timeline place to a reader whose only source is a forum:
    /// the one place their threads are drawn.
    var timelineEnabled: Bool {
        queryIDs.contains("all")
    }

    /// Where this launch lands (#101): the timeline where there is something in it to read, and
    /// the place a source is added where there is not.
    ///
    /// **`timelineEnabled` and not `sources.isEmpty`**, so the launch cannot land on a place the
    /// rail has turned off. The two say the same thing today — All exists exactly when a source
    /// is held — and if they ever stop agreeing, this one is the answer that leaves the reader
    /// somewhere they can be.
    var launchPlace: ShellPlace {
        timelineEnabled ? .timeline : .account
    }

    var enabledPlaces: [ShellPlace] {
        ShellPlace.allCases.filter(allows)
    }

    /// The places the rail lists: every one, drawn dim where it cannot be entered — **but Trends,
    /// which is absent and never dim** where no source has anything rising (a Discourse-only
    /// store): it is not a place waiting for a sign-in, it is one this store does not have.
    var railPlaces: [ShellPlace] {
        ShellPlace.allCases.filter { $0 != .trends || allows(.trends) }
    }

    /// **Notices is always there** (#323): with nobody signed in the page itself says what
    /// would make it fill, which a place that could not be entered never got to say.
    func allows(_ place: ShellPlace) -> Bool {
        switch place {
        case .timeline: timelineEnabled
        case .trends: !trendsTabs.isEmpty
        case .notices, .account, .usage, .preferences: true
        }
    }

    /// Reject a disabled destination: stay put, or first enabled if the current one is off.
    func placing(_ current: ShellPlace, as proposed: ShellPlace) -> ShellPlace {
        if allows(proposed) { return proposed }
        if allows(current) { return current }
        return enabledPlaces.first ?? .launch
    }

    func rotate(from current: ShellPlace, by step: Int) -> ShellPlace {
        let items = enabledPlaces
        guard !items.isEmpty else { return current }
        if items.contains(current) {
            return DummyCommand.advanced(items, from: current, by: step)
        }
        return items[0]
    }

    func reasonKey(for place: ShellPlace) -> String? {
        guard !allows(place) else { return nil }
        switch place {
        case .timeline: return "shell.timeline.disabled"
        default: return nil
        }
    }

    var composeHintKey: String {
        canCompose ? "compose.summary" : "compose.disabled.summary"
    }
}

/// The one question a launch asks about where to land, and the record that it has been asked
/// (#101).
///
/// **The store answers late, so the question cannot be asked in `init`.** Sources are read off
/// disk by `ShellSession.reloadFromStore`, which is awaited; until it returns, a session that
/// holds five servers is indistinguishable from one that holds none. So the shell starts on
/// `ShellPlace.launch` and this moves it, once, when the store has said what is there.
///
/// **A value with the asking in it, rather than a flag beside the state it guards.** The rule is
/// that the answer is given once and never revised — a first source added an hour later must not
/// pull the reader out of the page they are on, and the last one let go of must not be a second
/// launch. Written as a `mutating` method that stops answering, that rule is a thing a test can
/// hold; written as `if !decided { … }` in a view, it is a thing a test can only hope for.
struct ShellLaunch: Hashable, Sendable {
    private(set) var settled = false

    /// Where the launch should move to, or nothing at all.
    ///
    /// Nothing is the answer to every call after the first, to a launch that is already standing
    /// where it belongs, and to a reader who has walked somewhere else while the store was being
    /// read — that last one is theirs, and a launch does not overrule it.
    mutating func settle(_ availability: ShellAvailability, standingOn place: ShellPlace) -> ShellPlace? {
        guard !settled else { return nil }
        settled = true
        guard place == .launch else { return nil }
        let landing = availability.launchPlace
        return landing == place ? nil : landing
    }
}

/// Whether the subtree being drawn is the place the reader is actually in.
///
/// **Decision 20: a picture is fetched only for the place the reader is in.** The bug is larger
/// than the button that exposed it — on a compact `TabView` every tab stays alive, so a bulk cache
/// invalidation makes an *invisible* timeline refetch its whole working set: on the order of
/// fifteen to twenty-five deck-tier pictures, measured at 23 files and 7.6 MB for one server. A
/// reader sitting in Usage pays that with no button pressed and nothing on screen.
///
/// **Only `fetch` reads it.** `RemoteImage` still reads the cache and still stamps its interest
/// on every pass, gated or not; gating the read as well would break I8, which is what keeps the
/// cache's admission control honest. An inactive row competes for admission like any other and
/// simply stops re-asking for what it cannot see.
///
/// This is the wake's own principle from the other side — work in proportion to what the reader
/// can see — and a refinement of "a source drawing a picture is a source holding it" rather than
/// a retreat from it: a source that is **not being drawn** simply stops re-asking.
///
/// **A flag and not a `ShellPlace`, and that is the load-bearing detail.** A `RemoteImage` does
/// not know which pane it is drawn in, so a value naming the active place gives it nothing to
/// compare against; what a picture needs to know is whether *its own* subtree is the one on
/// screen. `FediqoRootView` sets it per page, so it is true in exactly one subtree and changes on
/// every navigation — on the rail and on the tab bar alike, which is what lets a returning tab
/// re-fire its task.
///
/// **The default is `true`, deliberately.** Until the value is provided — in a preview, in a test,
/// in any host that does not set it — a picture fetches exactly as it does today. A hand-off
/// degrades to today's behaviour and never to a quietly disabled feature, which is the lesson of
/// a missing `.environment` turning a pane into a screen that told the reader a false sentence.
extension EnvironmentValues {
    @Entry var shellPlaceIsActive: Bool = true
}
