import Foundation
import os
import Testing
import WebKit

@testable import FediqoCore
@testable import FediqoPersistence
@testable import FediqoUI

/// Quitting leaves nothing of where you went (#219).
///
/// What this device keeps between runs is the store — posts and their pictures — and the
/// reader's own settings and sign-ins. Everything else a run could leave behind that names a
/// source asked, or when, is pinned here: the run's record, the network stack's cache and cookie
/// jar, the forum browser's store, the preferences, and the system's log.
@MainActor
@Suite("Nothing of where a run went is left behind")
struct LeftBehindTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every Swift file under `Sources` and `Apps`, as text, by path.
    private static func sources() throws -> [(path: String, text: String)] {
        var found: [(String, String)] = []
        for top in ["Sources", "Apps"] {
            let base = root.appendingPathComponent(top)
            let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                found.append((
                    url.path.replacingOccurrences(of: root.path + "/", with: ""),
                    try String(contentsOf: url, encoding: .utf8)
                ))
            }
        }
        #expect(found.count > 20, "the walk found the sources")
        return found
    }

    /// The code of a file without its comments, so a comment naming what is refused is not read
    /// as a use of it.
    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - The run's record

    @Test("A relaunch starts with an empty record, however many sources the last run asked")
    func aRelaunchRecordsNothing() {
        let run = SourceWork()
        for host in ["one.example", "two.example", "three.example"] {
            run.end(run.begin(host: host, for: .timeline))
        }
        run.note(host: "page.example", for: .page, source: "one.example")
        #expect(run.record.count == 4)
        // What a relaunch builds: a new object, with nothing handed to it from the last.
        let next = SourceWork()
        #expect(next.record.isEmpty)
        #expect(next.log.sources.isEmpty)
    }

    @Test("Writing to the record writes nothing to the preferences")
    func theRecordIsNotAPreference() {
        let host = "left-behind-\(UUID().uuidString.lowercased()).example"
        let run = SourceWork()
        run.end(run.begin(host: host, for: .timeline, name: .home))
        run.note(host: host, for: .page)
        #expect(run.record.map(\.source) == [host, host])
        let after = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in after {
            #expect(!key.contains(host))
            #expect(!"\(value)".contains(host), "\(key) names the source asked")
        }
    }

    @Test("The record and its page keep nothing anywhere: no file, no default, no store")
    func theRecordHasNowhereToGo() throws {
        let shell = Self.root.appendingPathComponent("Sources/FediqoUI/Shell")
        for name in ["SourceWork.swift", "ActivityPanel.swift"] {
            let text = Self.code(try String(contentsOf: shell.appendingPathComponent(name), encoding: .utf8))
            for keeper in [
                // `NetLog` is allowed: a refusal is a failure, and what it writes is pinned by
                // `theLogNamesOnlyFailures` below.
                "UserDefaults", "AppStorage", "SceneStorage", "FileManager", "write(to", "Logger(",
                "ItemStore", "NSUbiquitousKeyValueStore", "print(",
            ] {
                #expect(!text.contains(keeper), "\(name) reaches for \(keeper)")
            }
        }
    }

    // MARK: - The network stack

    /// `URLSession.shared` files every response in an on-disk `URLCache` under its address and
    /// keeps an on-disk cookie jar: both a record of going, under the app's Library.
    @Test("Every live client's session keeps no cache, cookie or credential on disk")
    func theSessionsForget() throws {
        let clients: [(String, any HTTPClient)] = [
            ("default", URLSessionClient()),
            ("signed in", URLSessionClient.signedIn()),
            ("pictures", ShellPictures.live),
            ("forum posts", ForumPosts.live),
        ]
        for (name, client) in clients {
            let session = try #require((client as? URLSessionClient)?.session, "\(name)")
            #expect(session !== URLSession.shared, "\(name) is the shared session")
            let configuration = session.configuration
            #expect(configuration.urlCache == nil, "\(name) caches responses")
            #expect(configuration.urlCredentialStorage == nil, "\(name) keeps credentials")
            #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared, "\(name) shares the disk jar")
        }
    }

    @Test("Nothing in the app reaches for a session, cache or browser store that is kept on disk")
    func noSharedStores() throws {
        for (path, text) in try Self.sources() where path != "Sources/FediqoPersistence/SharedStores.swift" {
            let code = Self.code(text)
            for kept in [
                "URLSession.shared", "URLSession = .shared", "session: .shared", "URLCache.shared", "HTTPCookieStorage.shared",
                "URLSessionConfiguration.default", "URLCredentialStorage.shared",
                "WKWebsiteDataStore.default()", "websiteDataStore = .default()",
            ] {
                #expect(!code.contains(kept), "\(path) uses \(kept)")
            }
            // A configuration left to its default store is `.default()`, which WebKit keeps.
            let made = code.components(separatedBy: "WKWebViewConfiguration()").count - 1
            let stored = code.components(separatedBy: "configuration.websiteDataStore =").count - 1
            #expect(made <= stored, "\(path) builds a web view on WebKit's default store")
        }
    }

    // MARK: - The forum browser's store

    @Test("A run's end leaves a source's sign-in in the browser's store and every other site's cookie out")
    func theBrowserKeepsSignInsOnly() async {
        let store = WKWebsiteDataStore.nonPersistent()
        for (name, domain) in [
            ("x7Kq_2132_auth", "bbs.example.org"), ("cf_clearance", ".bbs.example.org"),
            ("_ga", "tracker.example"), ("sid", "removed.example"), ("ad", "ads.bbs.example.org"),
            ("member_auth", "www.example.com"),
        ] {
            await store.httpCookieStore.setCookie(ForumDeviceStoreTests.cookie(name, domain: domain))
        }
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        _ = forums.dataStore
        await forums.dropCache(within: .seconds(5))
        #expect(await store.httpCookieStore.allCookies().count == 6, "going to the background keeps every cookie")
        await forums.leaveNothing(keeping: ["BBS.example.org", "m.example", "example.com"], within: .seconds(5))
        let left = await store.httpCookieStore.allCookies()
        #expect(Set(left.map(\.name)) == ["x7Kq_2132_auth", "cf_clearance", "member_auth"],
                "a forum added bare keeps its sign-in filed under www.")
    }

    @Test("A launch sweeps a store an earlier run left, and a relaunched sign-in waits for it")
    func theLaunchSweeps() async {
        let store = WKWebsiteDataStore.nonPersistent()
        for (name, domain) in [("x7Kq_2132_auth", "bbs.example.org"), ("_ga", "tracker.example")] {
            await store.httpCookieStore.setCookie(ForumDeviceStoreTests.cookie(name, domain: domain))
        }
        let untouched = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        untouched.sweepAtLaunch(keeping: ["bbs.example.org"], onDisk: false, within: .seconds(5))
        #expect(untouched.sweeping == nil, "no store on disk, none opened")
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        forums.sweepAtLaunch(keeping: ["bbs.example.org"], onDisk: true, within: .seconds(5))
        #expect(forums.engine(host: "bbs.example.org").sweeping != nil, "a page waits for the sweep too")
        await forums.sweeping?.value
        #expect(Set(await store.httpCookieStore.allCookies().map(\.name)) == ["x7Kq_2132_auth"])
    }

    @Test("A sweep that does not answer is left behind at its limit", .timeLimit(.minutes(1)))
    func theSweepIsBounded() async {
        let finished = OSAllocatedUnfairLock(initialState: false)
        await ForumSessions.bounded(.milliseconds(50)) {
            try? await Task.sleep(for: .seconds(30))
            finished.withLock { $0 = true }
        }
        #expect(!finished.withLock { $0 }, "the quit waited for a store that never answered")
    }

    @Test("Signing out forgets a guest cookie from the jar the live session actually uses")
    func theLiveJarForgets() throws {
        let live = try #require(URLSessionClient.memoryOnly.configuration.httpCookieStorage)
        #expect(live !== HTTPCookieStorage.shared)
        #expect(SystemJar().cookies === live, "the jar a sign-out clears is the one requests fill")
        #expect(SystemJar().credentials == nil)
        let cookie = ForumDeviceStoreTests.cookie("guest", domain: "jar-forgets.example")
        live.setCookie(cookie)
        defer { live.deleteCookie(cookie) }
        SystemJar().forget(host: "jar-forgets.example", keeping: [])
        #expect(!(live.cookies ?? []).contains { $0.domain.contains("jar-forgets.example") })
    }

    @Test("What an older build left in the shared cache and cookie jar is emptied, once")
    func theSharedStoresAreEmptiedOnce() throws {
        let suite = "fediqo.leftBehind.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 1 << 20, directory: folder)
        let url = URL(string: "https://one.example/api/v1/timelines/home")!
        let request = URLRequest(url: url)
        cache.storeCachedResponse(
            CachedURLResponse(
                response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data: Data("[]".utf8)
            ),
            for: request
        )
        #expect(cache.cachedResponse(for: request) != nil)
        let jar = HTTPCookieStorage.shared
        let cookie = ForumDeviceStoreTests.cookie("left", domain: "left-behind.example")
        jar.setCookie(cookie)
        defer { jar.deleteCookie(cookie) }
        SharedStores.forgetOnce(defaults: defaults, cache: cache, jar: jar)
        #expect(cache.cachedResponse(for: request) == nil)
        #expect(!(jar.cookies ?? []).contains { $0.domain.contains("left-behind.example") })
        // Once: a second launch asks nothing of either.
        jar.setCookie(cookie)
        SharedStores.forgetOnce(defaults: defaults, cache: cache, jar: jar)
        #expect((jar.cookies ?? []).contains { $0.domain.contains("left-behind.example") })
    }

    @Test("What is dropped for a source's own site is everything WebKit keeps but its cookies")
    func theBrowserDropsItsCache() {
        let dropped = ForumWebEngine.leftBehind
        #expect(!dropped.contains(WKWebsiteDataTypeCookies))
        for kept in [
            WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases,
            WKWebsiteDataTypeServiceWorkerRegistrations, WKWebsiteDataTypeFetchCache,
        ] {
            #expect(dropped.contains(kept), "\(kept) outlives the run")
        }
        #expect(dropped.count == WKWebsiteDataStore.allWebsiteDataTypes().count - 1)
    }

    @Test("The app sweeps the browser's store as a run ends, on a Mac's quit and a phone's backgrounding")
    func theAppSweeps() throws {
        let app = try String(
            contentsOf: Self.root.appendingPathComponent("Apps/Shared/FediqoApp.swift"), encoding: .utf8
        )
        let code = Self.code(app)
        #expect(code.contains("await forums.leaveNothing(keeping: hosts, within: StoreSaver.deadline)"))
        #expect(code.contains("await forums.dropCache(within: StoreSaver.deadline)"))
        // A quit sweeps; a backgrounding drops only the cache, so a sign-in stepped away from
        // survives it; a launch sweeps what an earlier run left, before a sign-in reads it.
        // A Mac's quit, an iPhone's end where the system says so, and its last scene let go.
        #expect(code.components(separatedBy: "await Launch.shared.end()").count - 1 == 2)
        #expect(code.components(separatedBy: "self.endOnce()").count - 1 == 1, "a last scene let go")
        #expect(code.contains("guard ending == nil else { return }"), "the end runs once")
        #expect(code.contains("func applicationWillTerminate(_ application: UIApplication)"))
        #expect(code.contains("UIScene.didDisconnectNotification"))
        #expect(code.components(separatedBy: "await Launch.shared.pause()").count - 1 == 1)
        #expect(!code.contains("Launch.shared.saver.flush()"))
        let sweep = try #require(code.range(of: "forums.sweepAtLaunch("))
        let signIn = try #require(code.range(of: "forums.signInAgain("))
        #expect(sweep.lowerBound < signIn.lowerBound)
        #expect(code.contains("onDisk: ForumWebsiteData.isOnDisk(),\n            within: StoreSaver.deadline"))
        #expect(code.contains("SharedStores.forgetOnce()"))
    }

    // MARK: - The system's log

    /// The log is the system's and outlives the run; what reaches it is a host and a failure's
    /// kind, built by `NetLog.line`, and only on a failure.
    @Test("Only a host and a failure's kind reach the system's log")
    func theLogNamesOnlyFailures() throws {
        let call = try Regex(#"NetLog\.(?:network|auth)\.\w+\("#)
        let lined = try Regex(#"NetLog\.(?:network|auth)\.\w+\(\s*"\\\(NetLog\.line\("#)
        var seen = 0
        for (path, text) in try Self.sources() {
            let code = Self.code(text)
            seen += code.matches(of: lined).count
            #expect(
                code.matches(of: call).count == code.matches(of: lined).count,
                "\(path) logs something not built by NetLog.line"
            )
            for loose in ["print(", "NSLog(", "os_log(", "debugPrint(", "dump("] {
                #expect(!code.contains(loose), "\(path) writes with \(loose)")
            }
            if code.contains("Logger(subsystem") {
                #expect(
                    ["Sources/FediqoCore/NetLog.swift", "Sources/FediqoPersistence/StoreSaver.swift"]
                        .contains(path),
                    "\(path) keeps a log of its own"
                )
            }
        }
        #expect(seen >= 5, "the log's calls were found at all")
    }
}
