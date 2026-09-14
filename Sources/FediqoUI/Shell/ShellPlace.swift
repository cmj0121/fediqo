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
