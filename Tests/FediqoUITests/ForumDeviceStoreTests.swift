import Foundation
import Testing
import WebKit

@testable import FediqoCore
@testable import FediqoUI

extension ForumSessions {
    /// What a forum's own page does when a sign-in is reached: sets a member's session cookie.
    /// Then the store is read, as the store's own notification would have it read.
    func plantSession(host: String) async {
        await dataStore.httpCookieStore.setCookie(ForumDeviceStoreTests.cookie("x7Kq_2132_auth", domain: host))
        await readReached()
    }
}

/// The cookie store a sign-in outlives a relaunch in (#5), and "signed in" as a view of it.
///
/// Every test hands `ForumSessions` a non-persistent store of its own and hands the *same* store
/// to a second `ForumSessions` where a relaunch is meant: what persists across a launch is the
/// store, and the object in front of it is rebuilt from nothing — which is exactly what these
/// tests rebuild.
@MainActor
@Suite("Sign-ins kept on this device")
struct ForumDeviceStoreTests {
    static func cookie(_ name: String, domain: String) -> HTTPCookie {
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

    /// Waits, boundedly, for something the store's own notification or a spawned read settles.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func forum(_ host: String) -> Source { Source(host: host, kind: .discuz) }

    @Test("A relaunch counts a forum signed in where its member cookie is held, and only there")
    func launchReadsTheStore() async {
        let store = await store(holding: [
            Self.cookie("x7Kq_2132_auth", domain: ".bbs.example.org"),
            Self.cookie("x7Kq_2132_saltkey", domain: "guest.example"),
            Self.cookie("cf_clearance", domain: "guest.example"),
        ])
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        forums.watch(forums: ["BBS.Example.ORG", "guest.example", "never.example"])
        await forums.readReached()
        // A guest's cookies are what every forum this app has read holds; counting them would
        // offer "Sign out" on a forum nobody signed in to.
        #expect(forums.reachedHosts == ["bbs.example.org"])
    }

    @Test("A Clear pressed while the launch is still reading leaves the forum signed out")
    func clearDuringTheLaunchRead() async {
        let store = await store(holding: [Self.cookie("a_auth", domain: "one.example")])
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        session.sources = [forum("one.example")]
        let launch = Task { await forums.readReached() }
        await session.clear(host: "one.example")
        await launch.value
        #expect(!forums.reachedSignIn(host: "one.example"), "a read from before the Clear landed after it")
        await forums.readReached()
        #expect(forums.reachedHosts.isEmpty)
    }

    @Test("Clear after a relaunch drops that host's cookies with no browser built, and no other host's")
    func clearAfterRelaunchWithoutAnEngine() async {
        let store = await store(holding: [
            Self.cookie("a_auth", domain: "one.example"),
            Self.cookie("b_auth", domain: "two.example"),
        ])
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        session.sources = [forum("one.example"), forum("two.example")]
        await forums.readReached()
        #expect(forums.reachedHosts == ["one.example", "two.example"], "the premise did not hold")

        await session.clear(host: "ONE.example")

        #expect(!forums.hasEngine(host: "one.example"), "clearing stood a browser up to clear it")
        let left = await store.dataRecords(ofTypes: [WKWebsiteDataTypeCookies]).map(\.displayName)
        #expect(left == ["two.example"], "the cookies survived a Clear, or another host's went with them")
        #expect(forums.reachedHosts == ["two.example"])

        // And the next launch agrees with this one: the sign-in does not come back.
        let relaunched = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        relaunched.watch(forums: ["one.example", "two.example"])
        await relaunched.readReached()
        #expect(relaunched.reachedHosts == ["two.example"])
    }

    @Test("Clearing one forum leaves a sibling whose records sit under the same domain signed in")
    func clearLeavesASibling() async {
        let store = await store(holding: [
            Self.cookie("a_auth", domain: "one.example.org"),
            Self.cookie("b_auth", domain: "two.example.org"),
        ])
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        session.sources = [forum("one.example.org"), forum("two.example.org")]
        await forums.readReached()
        #expect(forums.reachedHosts == ["one.example.org", "two.example.org"], "the premise did not hold")

        await session.clear(host: "one.example.org")

        // WebKit files both under example.org, and the Clear used to take both sessions. Only the
        // cleared forum's own cookie goes now; the sibling is still added and still signed in
        // (#221).
        #expect(forums.reachedHosts == ["two.example.org"])
        #expect(await store.httpCookieStore.allCookies().map(\.domain) == ["two.example.org"])
    }

    @Test("A forum added after launch is read off the store as it arrives")
    func aForumAddedLater() async {
        let store = await store(holding: [Self.cookie("a_auth", domain: "later.example")])
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        #expect(forums.reachedHosts.isEmpty)
        session.sources = [forum("later.example")]
        #expect(await eventually { forums.reachedSignIn(host: "later.example") })
    }

    @Test("A sign-in whose cookie is not named *_auth reads signed in until Clear")
    func witnessedSignInCounts() async {
        let store = WKWebsiteDataStore.nonPersistent()
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        session.sources = [forum("odd.example")]
        await store.httpCookieStore.setCookie(Self.cookie("member_token", domain: "odd.example"))
        session.signingIn = ForumSignInRequest(host: "odd.example", stop: .noCredential)
        session.signInFinished(reached: true, host: "odd.example")
        await forums.readReached()
        #expect(forums.reachedSignIn(host: "odd.example"), "a sign-in the page confirmed was dropped by a re-read")

        await session.clear(host: "odd.example")
        #expect(!forums.reachedSignIn(host: "odd.example"))
    }

    @Test("No forum among the sources, no store opened — not even by a Clear")
    func noForumNoStore() async {
        var built = 0
        let make = { () -> WKWebsiteDataStore in
            built += 1
            return .nonPersistent()
        }
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: make())
        let session = ShellSession(http: FixtureHTTP(), forums: forums)
        session.sources = [Source(host: "social.example", kind: .mastodon)]
        await session.clear(host: "social.example")
        await forums.readReached()
        #expect(built == 0, "a reader with no forum opened the WebKit store")

        session.sources.append(forum("bbs.example.org"))
        #expect(await eventually { built == 1 })
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
}
