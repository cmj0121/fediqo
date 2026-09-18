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
            Self.write("language", language.rawValue)
            L10n.language = language
        }
    }

    var theme: DummyTheme {
        didSet { Self.write("theme", theme.rawValue) }
    }

    var fontSize: DummyFontSize {
        didSet { Self.write("fontSize", fontSize.rawValue) }
    }

    /// How many months of posts to keep; nil, the default, keeps them all forever.
    var keepMonths: Int? {
        didSet { Self.write("keepMonths", keepMonths.map(String.init) ?? "") }
    }

    init() {
        keepMonths = Int(Self.read("keepMonths") ?? "").flatMap { $0 > 0 ? $0 : nil }
        language = DummyLanguage(rawValue: Self.read("language") ?? "") ?? .system
        theme = DummyTheme(rawValue: Self.read("theme") ?? "") ?? .system
        fontSize = DummyFontSize(rawValue: Self.read("fontSize") ?? "") ?? .standard
        L10n.language = language
    }

    private static let prefix = "fediqo.dummy."

    private static func read(_ name: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + name)
    }

    private static func write(_ name: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: prefix + name)
    }
}
