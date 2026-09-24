import Foundation
import WebKit

/// The WebKit store forum sign-ins are kept in: on this device between launches, and out of its
/// backups.
///
/// **Out of backups because the issue says the secret stays on this device** (#5). A forum
/// session cookie is a bearer credential; restored onto another device it signs that device in
/// as the reader, which is the one thing the password beside it is kept from by
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. WebKit offers no switch for this, so the
/// directories are marked by hand before WebKit opens them — see `directories` for where they
/// are and why that is an observed path rather than a documented one.
public enum ForumWebsiteData {
    /// Stable id for this app's cookie store on this device.
    static let identifier = UUID(uuidString: "66656469-7171-4000-8000-000000000005")!

    /// The store, with its directories marked first. A failure to mark them is not a reason to
    /// refuse the store: the reader would be signed out every launch instead, which is worse, and
    /// the mark is retried every launch.
    @MainActor
    public static func onDevice() -> WKWebsiteDataStore {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        try? markOutOfBackups(library: library, sandboxed: isSandboxed, bundleID: bundleID)
        return WKWebsiteDataStore(forIdentifier: identifier)
    }

    /// Whether the store is on this device — made by some earlier run — without opening it: a
    /// launch sweeps it only then (#219), and a reader who never had a forum opens no WebKit.
    public static func isOnDisk() -> Bool {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let store = directories(library: library, sandboxed: isSandboxed, bundleID: bundleID).store
        return FileManager.default.fileExists(atPath: store.path)
    }

    /// Makes and marks both directories. The app's own WebKit root is marked as well as the
    /// store: everything WebKit keeps there is a cache or a session, and all of it comes back
    /// from the web rather than from a restore.
    static func markOutOfBackups(library: URL, sandboxed: Bool, bundleID: String) throws {
        let found = directories(library: library, sandboxed: sandboxed, bundleID: bundleID)
        try makeExcludedFromBackup(found.root)
        try makeExcludedFromBackup(found.store)
    }

    /// Where `WKWebsiteDataStore(forIdentifier:)` keeps its files, and the app's WebKit root
    /// above it.
    ///
    /// **Observed, not documented.** Apple names no path for this store. What WebKit does, and
    /// what was checked on macOS 26 against this app's container and a bare command-line
    /// process: inside a sandbox — every iOS app and the sandboxed Mac app — it is
    /// `Library/WebKit/WebsiteDataStore/<id>`; outside one, WebKit adds the bundle identifier (or
    /// the process name) after `WebKit`, because `~/Library/WebKit` is then shared with every
    /// other unsandboxed app and is not this app's to mark. WebKit takes a directory made and
    /// marked beforehand as its own and the mark survives it writing cookies there. If a later
    /// WebKit moves the store, this marks an empty directory and the store goes back to being
    /// backed up — which is why the test pins the path and not only the mark.
    static func directories(library: URL, sandboxed: Bool, bundleID: String) -> (root: URL, store: URL) {
        var root = library.appendingPathComponent("WebKit", isDirectory: true)
        if !sandboxed { root.appendPathComponent(bundleID, isDirectory: true) }
        let store = root
            .appendingPathComponent("WebsiteDataStore", isDirectory: true)
            // WebKit spells the id in lower case; `uuidString` is upper case, and on a
            // case-sensitive volume the mark would land on a directory WebKit never opens.
            .appendingPathComponent(identifier.uuidString.lowercased(), isDirectory: true)
        return (root, store)
    }

    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    }

    private static var isSandboxed: Bool {
        #if os(macOS)
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        #else
        true
        #endif
    }
}
