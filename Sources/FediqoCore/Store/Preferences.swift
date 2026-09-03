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

/// How long a post nobody kept stays on this device.
///
/// #7's second promise: *"Unkept posts age out on a policy you can see and change."* A policy
/// nobody can see is a machine deciding what somebody remembers, which is the thing this app is
/// against — so it is a setting, in words, beside the numbers it governs.
///
/// The window is measured from when the post was written and not from when it arrived. A post
/// from last year that reached this device this morning is a year old, and keeping it for a
/// month because it turned up late would be this app disagreeing with the reader about what
/// "the last month" means.
///
/// `forever` is a real answer and it is the one that costs something. It is offered because
/// somebody's own machine is theirs to fill, and the Storage page says what it is filling.
public enum Retention: String, Codable, Sendable, CaseIterable, Identifiable {
    case week, month, season, year, forever

    public var id: String { rawValue }

    /// How far back the window reaches, or nothing where it does not end.
    public var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .season: 90
        case .year: 365
        case .forever: nil
        }
    }

    /// The instant a post has to be newer than to stay. `nil` where nothing ages out.
    public func cutoff(from now: Date = Date()) -> Date? {
        days.map { now.addingTimeInterval(-Double($0) * 24 * 60 * 60) }
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
    /// How long a post nobody kept stays here. The reader's, and visible: see `Retention`.
    public var keepFor: Retention { didSet { defaults.set(keepFor.rawValue, forKey: Keys.keepFor) } }
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
    /// Which of the reader's accounts acts on a post, by `Server.endpoint`, or nothing where
    /// they have not said.
    ///
    /// It is a preference and not a derived answer because the choice is not neutral: nearly
    /// every post here comes from a server the reader has no account on, so acting on one goes
    /// through a server of theirs — and *which* one decides who learns the post exists. An app
    /// that picked quietly would be deciding that on their behalf, once per press.
    ///
    /// Unset is not a fault. With one account there is nothing to choose and this stays nil;
    /// with several, the screen asks once and writes the answer here.
    public var actingServer: String? { didSet { defaults.set(actingServer, forKey: Keys.actingServer) } }
    /// Whether the reader has agreed that acting on a post may have their own server go and
    /// fetch it. Off until they say otherwise, and revocable.
    ///
    /// Without it, an action on a post that server has never seen is refused rather than sent:
    /// the request that would make it work is the request that tells somebody what is being
    /// read, and this app does not send that one without being asked to.
    public var mayFetchToAct: Bool { didSet { defaults.set(mayFetchToAct, forKey: Keys.mayFetchToAct) } }

    /// When this device last managed to ask a server what had happened — whether or not
    /// anything had.
    ///
    /// Kept on disk rather than in the model that sets it, because the reason for saying it at
    /// all is the times nobody is looking. A background wake asks, writes what it found, and the
    /// process is gone a second later; a value living only in memory would have the inbox
    /// reopen saying it had never asked, on a morning when it had asked four times. That is the
    /// exact sentence #9 exists to prevent.
    public var lastHeard: Date? { didSet { defaults.set(lastHeard, forKey: Keys.lastHeard) } }

    private enum Keys {
        static let theme = "fediqo.theme"
        static let textScale = "fediqo.textScale"
        static let language = "fediqo.language"
        static let railExpanded = "fediqo.railExpanded"
        static let showBoosts = "fediqo.showBoosts"
        static let showMediaOnly = "fediqo.showMediaOnly"
        static let showSensitive = "fediqo.showSensitive"
        static let refreshInterval = "fediqo.refreshInterval"
        static let keepFor = "fediqo.keepFor"
        static let offeredHomeTimeline = "fediqo.offeredHomeTimeline"
        static let clearedSeededWording = "fediqo.clearedSeededWording"
        static let actingServer = "fediqo.actingServer"
        static let mayFetchToAct = "fediqo.mayFetchToAct"
        static let lastHeard = "fediqo.lastHeard"

        /// Every key above. Written out rather than derived, so that adding one and forgetting
        /// it here is a compile-time-visible omission in one place rather than a preference
        /// that quietly survives a reset.
        static let all = [theme, textScale, language, railExpanded, showBoosts, showMediaOnly,
                          showSensitive, refreshInterval, keepFor, offeredHomeTimeline, clearedSeededWording,
                          actingServer, mayFetchToAct, lastHeard]
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
        keepFor = fresh.keepFor
        offeredHomeTimeline = fresh.offeredHomeTimeline
        clearedSeededWording = fresh.clearedSeededWording
        actingServer = fresh.actingServer
        mayFetchToAct = fresh.mayFetchToAct
        lastHeard = fresh.lastHeard
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
        actingServer = defaults.string(forKey: Keys.actingServer)
        // Off until asked. The request this permits is the one that tells somebody what is
        // being read, so it is not a default anybody arrives at by not looking.
        mayFetchToAct = defaults.object(forKey: Keys.mayFetchToAct) as? Bool ?? false
        lastHeard = defaults.object(forKey: Keys.lastHeard) as? Date
        refreshInterval = defaults.string(forKey: Keys.refreshInterval).flatMap(RefreshInterval.init(rawValue:)) ?? .seconds30
        // A season, and not `forever`. A default of forever would mean this app quietly filling
        // somebody's disk on the strength of never having been asked — and a default of a week
        // would throw away what they had not got round to keeping. Three months is long enough
        // to go looking for something you half remember, and short enough to have an end.
        keepFor = defaults.string(forKey: Keys.keepFor).flatMap(Retention.init(rawValue:)) ?? .season
        offeredHomeTimeline = defaults.object(forKey: Keys.offeredHomeTimeline) as? Bool ?? false
        clearedSeededWording = defaults.object(forKey: Keys.clearedSeededWording) as? Bool ?? false
    }
}
