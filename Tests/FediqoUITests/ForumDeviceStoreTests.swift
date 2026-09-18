import Foundation
import Testing
import WebKit

@testable import FediqoCore
@testable import FediqoUI

/// The cookie store a sign-in outlives a relaunch in (#5).
///
/// Every test hands `ForumSessions` a non-persistent store of its own and hands the *same* store
/// to a second `ForumSessions` where a relaunch is meant: what persists across a launch is the
/// store, and the object in front of it is rebuilt from nothing — which is exactly what these
/// tests rebuild.
@MainActor
@Suite("Sign-ins kept on this device")
struct ForumDeviceStoreTests {
    private func cookie(_ name: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: domain, .path: "/", .name: name, .value: "v",
            .expires: Date().addingTimeInterval(3600),
        ])!
    }

    private func store(holding cookies: [HTTPCookie]) async -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore.nonPersistent()
        for cookie in cookies { await store.httpCookieStore.setCookie(cookie) }
        return store
    }

    @Test("A relaunch counts a forum signed in where its member cookie is held, and only there")
    func restoreReadsTheStore() async {
        let store = await store(holding: [
            cookie("x7Kq_2132_auth", domain: ".bbs.example.org"),
            cookie("x7Kq_2132_saltkey", domain: "guest.example"),
            cookie("cf_clearance", domain: "guest.example"),
        ])
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        #expect(forums.reachedHosts.isEmpty, "nothing is known before the store is read")
        await forums.restoreSignIns(among: ["BBS.Example.ORG", "guest.example", "never.example"])
        // A guest's cookies are what every forum this app has read holds; counting them would
        // offer "Sign out" on a forum nobody signed in to.
        #expect(forums.reachedHosts == ["bbs.example.org"])
    }

    @Test("Clear after a relaunch drops that host's cookies with no browser built, and no other host's")
    func clearAfterRelaunchWithoutAnEngine() async {
        let store = await store(holding: [
            cookie("a_auth", domain: "one.example"),
            cookie("b_auth", domain: "two.example"),
        ])
        let hosts = ["one.example", "two.example"]
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        await forums.restoreSignIns(among: hosts)
        #expect(forums.reachedHosts == Set(hosts), "the premise did not hold")

        await session.clear(host: "ONE.example")

        #expect(!forums.hasEngine(host: "one.example"), "clearing stood a browser up to clear it")
        let left = await store.dataRecords(ofTypes: [WKWebsiteDataTypeCookies]).map(\.displayName)
        #expect(left == ["two.example"], "the cookies survived a Clear, or another host's went with them")
        #expect(forums.reachedHosts == ["two.example"])

        // And the next launch agrees with this one: the sign-in does not come back.
        let relaunched = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        await relaunched.restoreSignIns(among: hosts)
        #expect(relaunched.reachedHosts == ["two.example"])
    }

    @Test("Every engine is built on the store the sessions were handed")
    func enginesShareTheStore() {
        let store = WKWebsiteDataStore.nonPersistent()
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        #expect(forums.engine(host: "one.example").view.configuration.websiteDataStore === store)
        #expect(forums.engine(host: "two.example").view.configuration.websiteDataStore === store)
    }

    @Test("A record or cookie belongs to a host by name or by the domain it sits under", arguments: [
        ("bbs.example.org", "bbs.example.org", true),
        ("example.org", "bbs.example.org", true),
        (".example.org", "bbs.example.org", true),
        ("BBS.Example.ORG", "bbs.example.org", true),
        ("www.bbs.example.org", "bbs.example.org", true),
        ("notexample.org", "example.org", false),
        ("other.org", "bbs.example.org", false),
        ("", "bbs.example.org", false),
        (".", "bbs.example.org", false),
    ])
    func holds(name: String, host: String, belongs: Bool) {
        #expect(ForumWebEngine.holds(name, for: host) == belongs)
    }

    // MARK: - Out of backups

    @Test("The store's directory is where WebKit keeps it, inside a sandbox and outside one")
    func storeDirectory() {
        let library = URL(fileURLWithPath: "/L", isDirectory: true)
        let id = UUID(uuidString: "ABCDEF11-2222-4333-8444-555555555555")!
        let inside = ForumSessions.storeDirectory(library: library, identifier: id, sandboxed: true, bundleID: "b.id")
        #expect(inside.path == "/L/WebKit/WebsiteDataStore/abcdef11-2222-4333-8444-555555555555")
        let outside = ForumSessions.storeDirectory(library: library, identifier: id, sandboxed: false, bundleID: "b.id")
        #expect(outside.path == "/L/WebKit/b.id/WebsiteDataStore/abcdef11-2222-4333-8444-555555555555")
    }

    @Test("The directory is made and marked out of backups, and marking it again is harmless")
    func markedOutOfBackups() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("WebsiteDataStore", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try ForumSessions.excludeFromBackup(dir)
        try ForumSessions.excludeFromBackup(dir)
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }
}
