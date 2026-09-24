import FediqoCore
import Foundation
import SwiftUI

/// Language of the dummy UI. System follows the device.
public enum DummyLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case taiwanese = "zh-TW"

    public var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .system: "system"
        case .english: "english"
        case .taiwanese: "taiwanese"
        }
    }

    var lprojName: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .taiwanese: "zh-TW"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .taiwanese: Locale(identifier: "zh-TW")
        }
    }
}

/// Appearance. System follows the device.
public enum DummyTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Type size. Default is a step above the system large size.
public enum DummyFontSize: String, CaseIterable, Identifiable, Sendable {
    case smallest
    case smaller
    case standard = "default"
    case larger
    case largest

    public var id: String { rawValue }

    /// The whole ladder sits one rung above the system's, so Default is a step
    /// larger than a stock app and every other step keeps its distance from it.
    var dynamicType: DynamicTypeSize {
        switch self {
        case .smallest: .medium
        case .smaller: .large
        case .standard: .xxLarge
        case .larger: .xxxLarge
        case .largest: .accessibility1
        }
    }
}

/// What this dummy keeps about appearance. Stored on this device.
@Observable
final class DummyPrefs {
    var language: DummyLanguage {
        didSet {
            write("language", language.rawValue)
            L10n.language = language
        }
    }

    var theme: DummyTheme {
        didSet { write("theme", theme.rawValue) }
    }

    var fontSize: DummyFontSize {
        didSet { write("fontSize", fontSize.rawValue) }
    }

    /// How many months of posts to keep; nil, the default, keeps them all forever.
    var keepMonths: Int? {
        didSet { write("keepMonths", keepMonths.map(String.init) ?? "") }
    }

    /// How many days a post its source deleted stays, marked, before it is let go (#179); nil, the
    /// default, keeps it until the reader says. The keep-for window above still wins where it is
    /// the shorter (`GoneWait`).
    var goneDays: Int? {
        didSet { write("goneDays", goneDays.map(String.init) ?? "") }
    }

    /// Whether a removed source's posts stay on this device (#250); false, the default, lets
    /// them go with it, as they always did. Removing honours this without asking again, and the
    /// question before it says which will happen.
    var removedPostsStay: Bool {
        didSet { write("removedPostsStay", removedPostsStay ? "1" : "") }
    }

    /// The last day every timeline shows (#22); nil, the default, shows up to now.
    var latestDate: LatestDate? {
        didSet { write("latestDate", latestDate?.text ?? "") }
    }

    /// How many minutes this device waits before asking the sources it holds again (#95). One
    /// wait for every source, and a minute unless a person picks another of `waits`.
    var askMinutes: Int {
        didSet { write("askMinutes", String(askMinutes)) }
    }

    /// The waits a person picks from, in minutes.
    static let waits = [1, 5, 15, 30, 60]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        (keepMonths, goneDays, removedPostsStay, latestDate, askMinutes, language, theme, fontSize) = Self.read(defaults)
        L10n.language = language
    }

    /// Every choice read again off the preferences — after a take-away was read back (#247),
    /// which replaced them under this object.
    func reread() {
        let read = Self.read(defaults)
        if keepMonths != read.keepMonths { keepMonths = read.keepMonths }
        if goneDays != read.goneDays { goneDays = read.goneDays }
        if removedPostsStay != read.removedPostsStay { removedPostsStay = read.removedPostsStay }
        if latestDate != read.latestDate { latestDate = read.latestDate }
        if askMinutes != read.askMinutes { askMinutes = read.askMinutes }
        if language != read.language { language = read.language }
        if theme != read.theme { theme = read.theme }
        if fontSize != read.fontSize { fontSize = read.fontSize }
    }

    private static func read(_ defaults: UserDefaults) -> (
        keepMonths: Int?, goneDays: Int?, removedPostsStay: Bool, latestDate: LatestDate?, askMinutes: Int,
        language: DummyLanguage, theme: DummyTheme, fontSize: DummyFontSize
    ) {
        func read(_ name: String) -> String? { defaults.string(forKey: Self.prefix + name) }
        let keepMonths = Int(read("keepMonths") ?? "").flatMap { $0 > 0 ? $0 : nil }
        let goneDays = Int(read("goneDays") ?? "").flatMap { $0 > 0 ? $0 : nil }
        let removedPostsStay = read("removedPostsStay") == "1"
        let latestDate = LatestDate(read("latestDate") ?? "")
        let askMinutes = Int(read("askMinutes") ?? "").flatMap { Self.waits.contains($0) ? $0 : nil } ?? 1
        let language = DummyLanguage(rawValue: read("language") ?? "") ?? .system
        let theme = DummyTheme(rawValue: read("theme") ?? "") ?? .system
        let fontSize = DummyFontSize(rawValue: read("fontSize") ?? "") ?? .standard
        return (keepMonths, goneDays, removedPostsStay, latestDate, askMinutes, language, theme, fontSize)
    }

    private static let prefix = "fediqo.dummy."

    private func write(_ name: String, _ value: String) {
        defaults.set(value, forKey: Self.prefix + name)
    }
}
