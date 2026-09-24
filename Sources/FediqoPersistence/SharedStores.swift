import Foundation

/// What builds before #219 left in the system's shared network stores, dropped once (#219).
///
/// Until then every request went through `URLSession.shared`, whose `URLCache` files each
/// response on disk under its full address with when it came, and whose cookie jar keeps every
/// cookie a source set: both under this app's Library, both naming which source was asked and
/// when. Nothing this app sends goes through either any more (`URLSessionClient.memoryOnly`), so
/// what is in them is only what an older build left, and it is emptied the first time this build
/// launches. A flag in the preferences, naming no source, says it was done.
///
/// **Self-contained on purpose.** It empties the two stores whole and once; whatever else in the
/// app reads or clears the shared cookie jar for one host does not have to know it exists.
public enum SharedStores {
    static let doneKey = "fediqo.sharedStores.forgotten"

    /// Empties the shared cache and the shared cookie jar, where it was not done before.
    public static func forgetOnce(
        defaults: UserDefaults = .standard,
        cache: URLCache = .shared,
        jar: HTTPCookieStorage = .shared
    ) {
        guard !defaults.bool(forKey: doneKey) else { return }
        cache.removeAllCachedResponses()
        jar.removeCookies(since: .distantPast)
        defaults.set(true, forKey: doneKey)
    }
}
