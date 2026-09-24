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

    /// How much room this device gives the store and the picture copies together (#249), in
    /// bytes; nil, the default, sets no limit. Past it the copies go first, then the oldest posts.
    var roomBytes: Int? {
        didSet { write("roomBytes", roomBytes.map(String.init) ?? "") }
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
        func read(_ name: String) -> String? { defaults.string(forKey: Self.prefix + name) }
        keepMonths = Int(read("keepMonths") ?? "").flatMap { $0 > 0 ? $0 : nil }
        goneDays = Int(read("goneDays") ?? "").flatMap { $0 > 0 ? $0 : nil }
        roomBytes = Int(read("roomBytes") ?? "").flatMap { $0 > 0 ? $0 : nil }
        removedPostsStay = read("removedPostsStay") == "1"
        latestDate = LatestDate(read("latestDate") ?? "")
        askMinutes = Int(read("askMinutes") ?? "").flatMap { Self.waits.contains($0) ? $0 : nil } ?? 1
        language = DummyLanguage(rawValue: read("language") ?? "") ?? .system
        theme = DummyTheme(rawValue: read("theme") ?? "") ?? .system
        fontSize = DummyFontSize(rawValue: read("fontSize") ?? "") ?? .standard
        L10n.language = language
    }

    private static let prefix = "fediqo.dummy."

    private func write(_ name: String, _ value: String) {
        defaults.set(value, forKey: Self.prefix + name)
    }
}
