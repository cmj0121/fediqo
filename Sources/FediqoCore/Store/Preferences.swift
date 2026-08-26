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

/// How often the page you are looking at asks its servers again. Off is a real answer: a
/// timeline nobody is watching costs nobody's server anything, and neither does one whose
/// reader would rather ask themselves.
public enum RefreshInterval: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case seconds15
    case seconds30
    case seconds60
    case seconds300

    public var id: String { rawValue }

    /// How long between two refreshes, or nothing at all where the reader turned it off.
    public var duration: Duration? {
        switch self {
        case .off: nil
        case .seconds15: .seconds(15)
        case .seconds30: .seconds(30)
        case .seconds60: .seconds(60)
        case .seconds300: .seconds(300)
        }
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
    /// Whether what a post covered arrives uncovered.
    ///
    /// One switch for two things, because to a reader they are one act: a post's media arrives
    /// blurred when its source said `sensitive`, and its words sit behind the line the author
    /// wrote as `spoiler_text`. Off by default — a warning somebody wrote is a warning until
    /// the reader says otherwise, and this app is not the one to overrule it.
    ///
    /// A post opened by hand is opened for this run of the app only and is never written down.
    /// Which posts somebody chose to look behind is a reading record, and the store keeps only
    /// what a network handed over plus the choices a reader made about it.
    public var showSensitive: Bool { didSet { defaults.set(showSensitive, forKey: Keys.showSensitive) } }
    public var refreshInterval: RefreshInterval { didSet { defaults.set(refreshInterval.rawValue, forKey: Keys.refreshInterval) } }
    /// Whether the one-time repair of `LocalStore.clearSeededWording` has run.
    ///
    /// It is a fact about this install rather than about any row, which is the whole reason it
    /// is here: the rows cannot say whether the words in them are the app's or the reader's,
    /// so what is remembered is that the question has been settled once.
    public var clearedSeededWording: Bool { didSet { defaults.set(clearedSeededWording, forKey: Keys.clearedSeededWording) } }
    /// Whether a home timeline has been offered — once, on the first sign-in ever.
    ///
    /// A home timeline is not among the ones a fresh install ships with: a device nobody is
    /// signed in on anywhere has no home to read, and a page that can only ever be empty is
    /// not something to hand somebody on their first launch. So it appears the first time
    /// somebody signs in — and this is what stops it appearing again, because a reader who
    /// deleted it deleted it, and offering it back on the next sign-in would be an app
    /// disagreeing with them.
    public var offeredHomeTimeline: Bool { didSet { defaults.set(offeredHomeTimeline, forKey: Keys.offeredHomeTimeline) } }

    private enum Keys {
        static let theme = "fediqo.theme"
        static let textScale = "fediqo.textScale"
        static let language = "fediqo.language"
        static let railExpanded = "fediqo.railExpanded"
        static let showBoosts = "fediqo.showBoosts"
        static let showMediaOnly = "fediqo.showMediaOnly"
        static let showSensitive = "fediqo.showSensitive"
        static let refreshInterval = "fediqo.refreshInterval"
        static let offeredHomeTimeline = "fediqo.offeredHomeTimeline"
        static let clearedSeededWording = "fediqo.clearedSeededWording"

        /// Every key above. Written out rather than derived, so that adding one and forgetting
        /// it here is a compile-time-visible omission in one place rather than a preference
        /// that quietly survives a reset.
        static let all = [theme, textScale, language, railExpanded, showBoosts, showMediaOnly,
                          showSensitive, refreshInterval, offeredHomeTimeline, clearedSeededWording]
    }

    /// Every preference back to the value a first launch would have given it, and the stored
    /// keys with them. Part of "make this device look like a fresh install": the store being
    /// emptied leaves the reader's theme, language and standing filters behind, and a fresh
    /// install has none of those either.
    public func resetToDefaults() {
        for key in Keys.all { defaults.removeObject(forKey: key) }
        let fresh = Preferences(defaults: defaults)
        theme = fresh.theme
        textScale = fresh.textScale
        language = fresh.language
        railExpanded = fresh.railExpanded
        showBoosts = fresh.showBoosts
        showMediaOnly = fresh.showMediaOnly
        showSensitive = fresh.showSensitive
        refreshInterval = fresh.refreshInterval
        offeredHomeTimeline = fresh.offeredHomeTimeline
        clearedSeededWording = fresh.clearedSeededWording
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
        showSensitive = defaults.object(forKey: Keys.showSensitive) as? Bool ?? false
        refreshInterval = defaults.string(forKey: Keys.refreshInterval).flatMap(RefreshInterval.init(rawValue:)) ?? .seconds30
        offeredHomeTimeline = defaults.object(forKey: Keys.offeredHomeTimeline) as? Bool ?? false
        clearedSeededWording = defaults.object(forKey: Keys.clearedSeededWording) as? Bool ?? false
    }
}
