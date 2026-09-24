import Foundation
import Testing
import WebKit

@testable import FediqoCore
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
                "UserDefaults", "AppStorage", "SceneStorage", "FileManager", "write(to", "Logger",
                "NetLog", "ItemStore", "NSUbiquitousKeyValueStore", "print(",
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
        for (path, text) in try Self.sources() {
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
            ("_ga", "tracker.example"), ("sid", "removed.example"),
        ] {
            await store.httpCookieStore.setCookie(ForumDeviceStoreTests.cookie(name, domain: domain))
        }
        let forums = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        _ = forums.dataStore
        await forums.leaveNothing(keeping: ["BBS.example.org", "m.example"])
        let left = await store.httpCookieStore.allCookies()
        #expect(Set(left.map(\.name)) == ["x7Kq_2132_auth", "cf_clearance"])
        for cookie in left { #expect(ForumWebEngine.holds(cookie.domain, for: "bbs.example.org")) }
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
        #expect(code.contains("await forums.leaveNothing(keeping:"))
        // Both ends of a run go through the one door that saves and sweeps.
        #expect(code.components(separatedBy: "await Launch.shared.end()").count - 1 == 2)
        #expect(!code.contains("Launch.shared.saver.flush()"))
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
