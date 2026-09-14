/// A destination in the shell. Compose is not one: it is an action over the current page.
public enum ShellPlace: String, CaseIterable, Identifiable, Hashable, Sendable {
    case timeline
    case notices
    case account
    case usage
    case preferences

    public var id: String { rawValue }

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
