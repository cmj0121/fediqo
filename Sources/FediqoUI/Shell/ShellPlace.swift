import SwiftUI

/// A destination in the shell. Compose is not one: it is an action over the current page.
public enum ShellPlace: String, CaseIterable, Identifiable, Hashable, Sendable {
    case timeline
    case notices
    case account
    case usage
    case preferences

    public var id: String { rawValue }

    /// Empty launch lands here. Timeline is off until All and Trends exist.
    public static let launch: ShellPlace = .account

    var title: String {
        switch self {
        case .timeline: L10n.t("shell.timeline.title")
        case .notices: L10n.t("shell.notices.title")
        case .account: L10n.t("shell.account.title")
        case .usage: L10n.t("shell.usage.title")
        case .preferences: L10n.t("shell.preferences.title")
        }
    }

    /// What the action is for. Shown on the rail when it is expanded; collapsed, it is help.
    var summary: String {
        switch self {
        case .timeline: L10n.t("shell.timeline.summary")
        case .notices: L10n.t("shell.notices.summary")
        case .account: L10n.t("shell.account.summary")
        case .usage: L10n.t("shell.usage.summary")
        case .preferences: L10n.t("shell.preferences.summary")
        }
    }

    var symbolName: String {
        switch self {
        case .timeline: "list.bullet.rectangle"
        case .notices: "bell"
        case .account: "person.crop.circle"
        case .usage: "chart.bar.xaxis"
        case .preferences: "gearshape"
        }
    }
}

/// What this session has, used to enable the rail. Compose is not a place.
struct ShellAvailability: Hashable, Sendable {
    var queryIDs: Set<String> = []
    var signedIn = false

    static let empty = ShellAvailability()

    var canCompose: Bool { signedIn }

    var timelineEnabled: Bool {
        queryIDs.contains("all") && queryIDs.contains("trends")
    }

    var enabledPlaces: [ShellPlace] {
        ShellPlace.allCases.filter(allows)
    }

    func allows(_ place: ShellPlace) -> Bool {
        switch place {
        case .timeline: timelineEnabled
        case .notices: signedIn
        case .account, .usage, .preferences: true
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
        case .notices: return "shell.notices.disabled"
        default: return nil
        }
    }

    var composeHintKey: String {
        canCompose ? "compose.summary" : "compose.disabled.summary"
    }
}

/// Whether the subtree being drawn is the place the reader is actually in.
///
/// **Decision 20: a picture is fetched only for the place the reader is in.** The bug is larger
/// than the button that exposed it — on a compact `TabView` every tab stays alive, so a bulk cache
/// invalidation makes an *invisible* timeline refetch its whole working set: on the order of
/// fifteen to twenty-five deck-tier pictures, measured at 23 files and 7.6 MB for one server. A
/// reader sitting in Preferences pays that with no button pressed and nothing on screen.
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
