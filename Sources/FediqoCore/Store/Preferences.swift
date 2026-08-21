import Foundation
import Observation

public enum AppTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
}

/// macOS has no Dynamic Type, so the scale is ours. On iOS it multiplies whatever the
/// system already decided rather than replacing it.
public enum TextScale: String, Codable, Sendable, CaseIterable, Identifiable {
    case small, regular, large, larger

    public var id: String { rawValue }

    public var factor: Double {
        switch self {
        case .small: 0.85
        case .regular: 1.00
        case .large: 1.30
        case .larger: 1.60
        }
    }
}

public enum AppLanguage: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case english = "en"
    case traditionalChinese = "zh-TW"

    public var id: String { rawValue }

    /// Choosing a language has to move the dates and numbers with it. Without this a
    /// zh-TW app still says "31 minutes ago" because formatting follows the system, not
    /// the strings.
    public var locale: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }
}

/// Everything the general preferences screen changes. Backed by `UserDefaults` for now,
/// for the same reason as `ServerStore`: #2 owns the real store, and this must not
/// pre-empt its schema.
@MainActor
@Observable
public final class Preferences {
    private let defaults: UserDefaults

    public var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: Keys.theme) } }
    public var textScale: TextScale { didSet { defaults.set(textScale.rawValue, forKey: Keys.textScale) } }
    public var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: Keys.language) } }
    public var railExpanded: Bool { didSet { defaults.set(railExpanded, forKey: Keys.railExpanded) } }
    public var showBoosts: Bool { didSet { defaults.set(showBoosts, forKey: Keys.showBoosts) } }
    public var showMediaOnly: Bool { didSet { defaults.set(showMediaOnly, forKey: Keys.showMediaOnly) } }

    private enum Keys {
        static let theme = "fediqo.theme"
        static let textScale = "fediqo.textScale"
        static let language = "fediqo.language"
        static let railExpanded = "fediqo.railExpanded"
        static let showBoosts = "fediqo.showBoosts"
        static let showMediaOnly = "fediqo.showMediaOnly"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Defaults are the ones asked for: dark, and the largest of the readable sizes.
        theme = defaults.string(forKey: Keys.theme).flatMap(AppTheme.init(rawValue:)) ?? .dark
        textScale = defaults.string(forKey: Keys.textScale).flatMap(TextScale.init(rawValue:)) ?? .larger
        language = defaults.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        railExpanded = defaults.object(forKey: Keys.railExpanded) as? Bool ?? false
        showBoosts = defaults.object(forKey: Keys.showBoosts) as? Bool ?? true
        showMediaOnly = defaults.object(forKey: Keys.showMediaOnly) as? Bool ?? false
    }
}
