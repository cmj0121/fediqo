import Foundation
import Testing
import WebKit
@testable import FediqoCore
@testable import FediqoPersistence
@testable import FediqoUI

/// A run whose store did not open holds no sources, and nothing is swept by that empty list
/// (#295): the notice says nothing was changed, and the picture copies and the forum browser's
/// sign-ins are part of what must not have been.
///
/// What a test can reach: the three sweeps themselves — the picture copies at launch, the
/// browser's store at launch and at the run's end — against real copies on disk and real cookies,
/// and the app's source handing each of them whether the store was read. What it cannot: the app
/// launched with its store held by another copy.
@Suite("A run that did not read the store sweeps nothing by its sources", .serialized)
@MainActor
struct StoreNotReadSweepsTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-sweeps-\(UUID().uuidString)", isDirectory: true)
    }

    /// Every file under `dir`, by path, with its bytes.
    private func disk(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.subpathsOfDirectory(atPath: dir.path) {
            let url = dir.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            if !isFolder.boolValue { out[name] = try Data(contentsOf: url) }
        }
        return out
    }

    /// Picture copies of two hosts, on disk.
    private func copies(in dir: URL) throws -> MediaCache {
        let cache = try MediaCache(directory: dir)
        for (host, name) in [("one.example", "a"), ("one.example", "b"), ("forum.example", "c")] {
            try cache.store(Data("picture \(name)".utf8), host: host, url: URL(string: "https://\(host)/\(name).png")!)
        }
        return cache
    }

    @Test("With the store not read, a launch leaves every byte of every picture copy; with it read, the copies of hosts no longer sources go")
    func thePictures() async throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try copies(in: dir)
        let before = try disk(dir)
        #expect(before.count == 3, "the premise: three copies on disk")

        // A run with no store: no sources at all.
        let unread = FediqoRootView.keptPictures(in: cache, for: [], read: false)
        await unread.settled()
        #expect(try disk(dir) == before, "a launch with no store took the pictures")
        #expect(await unread.data(host: "one.example", url: URL(string: "https://one.example/a.png")!) == Data("picture a".utf8), "and they are still drawn from")

        // The same list on a run that read its store means those sources are gone.
        let read = FediqoRootView.keptPictures(in: cache, for: ["one.example"], read: true)
        await read.settled()
        #expect(try disk(dir).count == 2, "a normal launch still sweeps")
        let none = FediqoRootView.keptPictures(in: cache, for: [], read: true)
        await none.settled()
        #expect(try disk(dir).isEmpty)
    }

    private func browser() async -> WKWebsiteDataStore {
        let store = WKWebsiteDataStore.nonPersistent()
        for (name, domain) in [("x7Kq_2132_auth", "bbs.example.org"), ("cf_clearance", ".bbs.example.org"), ("_ga", "tracker.example")] {
            await store.httpCookieStore.setCookie(ForumDeviceStoreTests.cookie(name, domain: domain))
        }
        return store
    }

    @Test("With the store not read, neither the launch nor the run's end takes a forum's sign-in from the browser's store; with it read, both sweep as before")
    func theBrowsersStore() async {
        let store = await browser()
        let unread = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        unread.sourcesRead = false
        unread.sweepAtLaunch(keeping: [], onDisk: true, within: .seconds(5))
        #expect(unread.sweeping == nil, "a launch with no store swept the browser's store")
        _ = unread.dataStore
        await unread.leaveNothing(keeping: [], within: .seconds(5))
        #expect(await store.httpCookieStore.allCookies().count == 3, "a quit with no store took every sign-in")

        let read = ForumSessions(credentials: MemoryCredentials(), dataStore: store)
        #expect(read.sourcesRead, "read unless said otherwise")
        _ = read.dataStore
        await read.leaveNothing(keeping: ["bbs.example.org"], within: .seconds(5))
        #expect(Set(await store.httpCookieStore.allCookies().map(\.name)) == ["x7Kq_2132_auth", "cf_clearance"])
        read.sweepAtLaunch(keeping: [], onDisk: true, within: .seconds(5))
        await read.sweeping?.value
        #expect(await store.httpCookieStore.allCookies().isEmpty, "a normal launch still sweeps")
    }

    @Test("The app hands every sweep keyed on its sources whether the store was read — the one answer, worked out once — and a run with no store offers no read back and no take-away of nothing")
    func theAppSays() throws {
        let app = try String(contentsOf: Self.root.appendingPathComponent("Apps/Shared/FediqoApp.swift"), encoding: .utf8)
        #expect(app.contains("storeRead = opened.file != nil && opened.setAside == nil"))
        #expect(app.contains("sessions.sourcesRead = storeRead"))
        #expect(app.contains("FediqoRootView.keepPictures(in: media, for: opened.sources.map(\\.host), read: storeRead)"))
        // Set before the launch's sweep is asked for, and the quit's goes through the same object.
        let said = try #require(app.range(of: "sessions.sourcesRead = storeRead"))
        let swept = try #require(app.range(of: "forums.sweepAtLaunch("))
        #expect(said.lowerBound < swept.lowerBound)
        #expect(app.contains("storeNotOpened: opened.file == nil && !opened.storeIsNewer"))
        #expect(app.contains("storeTrouble: Launch.shared.storeTrouble"))
    }
}
