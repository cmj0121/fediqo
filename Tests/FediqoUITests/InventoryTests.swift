import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FediqoCore
@testable import FediqoPersistence
@testable import FediqoUI

/// #7: what this device holds, and the three ways to drop some of it — by source (Clear), by
/// cache, and by time — each pinned against a relaunch: a new `StoreFile` or `MediaCache` opened
/// on the same folder.
@MainActor
@Suite("What this device holds, and dropping some of it")
struct InventoryTests {
    private let alpha = Source(host: "alpha.test", kind: .mastodon)
    private let beta = Source(host: "beta.test", kind: .mastodon)
    /// The real clock: a keep policy read at launch cuts back from the moment it runs.
    private let now = Date()

    private func address(_ n: Int) -> URL {
        URL(string: "https://example.test/\(n).png")!
    }

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func note(_ id: String, daysAgo: Double, from source: Source) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada", body: "hello",
            postedAt: now.addingTimeInterval(-daysAgo * 86_400), origins: [.publicTimeline],
            avatarURL: address(Int(id) ?? 0)
        )
    }

    /// Two sources, a post from each this week and one from alpha a year ago.
    private func held() -> ItemStore {
        ItemStore(sources: [alpha, beta], notes: [
            note("1", daysAgo: 1, from: alpha),
            note("2", daysAgo: 2, from: beta),
            note("3", daysAgo: 365, from: alpha),
        ])
    }

    /// Counts saves, and writes them where a relaunch will look through a `StoreSaver`, as the
    /// app's `save` does.
    private final class Saves {
        var count = 0
    }

    private func persisting(_ session: ShellSession, to dir: URL, counting saves: Saves) throws {
        let saver = StoreSaver(store: session.store, file: try StoreFile(at: dir))
        session.persist = {
            saves.count += 1
            try? await saver.save()
        }
    }

    private actor Counting: HTTPClient {
        private(set) var requests = 0
        private let png: Data

        init(png: Data) { self.png = png }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            requests += 1
            return (png, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    // MARK: By time

    @Test("Keeping forever, or a count that is not positive, drops nothing and writes nothing", arguments: [nil, 0, -1] as [Int?])
    func keepForeverWritesNothing(months: Int?) async throws {
        let session = ShellSession(http: FixtureHTTP(), store: held())
        let saves = Saves()
        try persisting(session, to: scratch(), counting: saves)
        await session.reloadFromStore()
        #expect(await session.keep(months: months, from: now) == 0)
        #expect(session.notes.count == 3)
        #expect(saves.count == 0)
    }

    @Test("Keeping the latest months holds after a relaunch, and every source stays joined")
    func keepSurvivesRelaunch() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = held()
        let session = ShellSession(http: FixtureHTTP(), store: store)
        let saves = Saves()
        try persisting(session, to: dir, counting: saves)
        await session.reloadFromStore()

        #expect(await session.keep(months: 3, from: now) == 1)
        #expect(session.notes.map(\.id).sorted() == ["1", "2"])
        #expect(session.holdings.posts == 2, "the counts were not rebuilt with the rows")
        #expect(session.sources.map(\.host) == [alpha.host, beta.host])
        #expect(saves.count == 1)
        let opened = StoreFile.open(at: dir)
        #expect(opened.notes.map(\.id).sorted() == ["1", "2"])
        #expect(opened.sources.map(\.host) == [alpha.host, beta.host])

        // Nothing more to drop: not written again. And anything older read later is not kept.
        #expect(await session.keep(months: 3, from: now) == 0)
        #expect(saves.count == 1)
        await store.ingest([note("4", daysAgo: 400, from: beta)])
        #expect(await !store.all().contains { $0.id == "4" })
    }

    @Test("Forever is the default: nothing is dropped by time unless the reader chose it")
    func foreverIsTheDefault() async {
        let store = held()
        #expect(await store.retention == nil)
        let session = ShellSession(http: FixtureHTTP(), store: store)
        await session.reloadFromStore()
        #expect(session.notes.count == 3)
    }

    // MARK: By source

    @Test("Clear keeps the source joined and its rows drawn")
    func clearKeepsRows() async {
        let session = ShellSession(
            http: FixtureHTTP(), store: held(), pictures: ShellPictures(http: FixtureHTTP()), emojis: EmojiCache()
        )
        await session.reloadFromStore()
        await session.clear(host: alpha.host)
        #expect(session.sources.map(\.host) == [alpha.host, beta.host])
        #expect(session.notes.count == 3)
    }

    // MARK: By cache

    @Test("Dropping copies empties memory and disk for every source, holds after a relaunch, and rows still draw")
    func dropCopiesKeepsRowsDrawable() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = try picture()
        let http = Counting(png: png)
        let pictures = ShellPictures(http: http, disk: try MediaCache(directory: dir))
        let session = ShellSession(http: FixtureHTTP(), store: held(), pictures: pictures, emojis: EmojiCache())
        await session.reloadFromStore()
        await pictures.fetch(address(1), scale: 2, tier: .deck, host: alpha.host)
        await pictures.fetch(address(2), scale: 2, tier: .deck, host: beta.host)
        await pictures.diskSettled()
        let before = await pictures.diskBytes(hosts: [alpha.host, beta.host])
        #expect(before[alpha.host, default: 0] > 0)
        #expect(before[beta.host, default: 0] > 0)
        let generation = pictures.generation
        let cleared = session.cleared

        session.dropCopies()
        await pictures.diskSettled()

        #expect(pictures.holding(host: alpha.host).count == 0)
        #expect(pictures.holding(host: beta.host).count == 0)
        #expect(pictures.generation > generation, "rows on screen were not told to ask again")
        #expect(session.cleared == cleared + 1)
        #expect(await pictures.diskBytes(hosts: [alpha.host, beta.host]).values.reduce(0, +) == 0)
        let reopened = try MediaCache(directory: dir)
        #expect(reopened.data(host: alpha.host, url: address(1)) == nil)
        #expect(reopened.data(host: beta.host, url: address(2)) == nil)

        // The index is untouched, and a row still draws: its picture is read from its hyperlink.
        #expect(session.notes.count == 3)
        #expect(session.sources.count == 2)
        let row = try #require(session.notes.first { $0.id == "1" })
        let avatar = try #require(row.avatarURL as URL?)
        let requests = await http.requests
        await pictures.fetch(avatar, scale: 2, tier: .deck, host: row.source.host)
        #expect(await http.requests == requests + 1)
        #expect(pictures.picture(address(1), scale: 2, tier: .deck, host: alpha.host) != nil)
    }

    @Test("With no copies on disk, there is nothing on disk to read")
    func noDiskNoBytes() async {
        #expect(await ShellPictures(http: FixtureHTTP()).diskBytes(hosts: [alpha.host]).isEmpty)
    }

    // MARK: The cap

    /// A `MediaCopies` that only counts: how many times it was walked by a trim, and what it
    /// says it holds. Enough to see the running total decide when a walk happens.
    private final class Walked: MediaCopies, @unchecked Sendable {
        var trims = 0
        var held = 0
        func store(_ data: Data, host: String, url: URL) throws { held += data.count }
        func data(host: String, url: URL) -> Data? { nil }
        func remove(host: String, url: URL) {}
        func forget(host: String) { held = 0 }
        func keepOnly(hosts: some Sequence<String>) {}
        func removeAll() { held = 0 }
        func bytes(host: String) -> Int { held }
        func trim(toBytes cap: Int) -> Int {
            trims += 1
            held = min(held, cap)
            return held
        }
    }

    @Test("The copies are walked only when the running total passes the cap")
    func capWalksOnlyWhenOver() async {
        let walked = Walked()
        let copies = DiskCopies(walked, cap: 25)
        copies.trim()
        await copies.settled()
        #expect(walked.trims == 1, "the launch trim measures once")
        #expect(await copies.total() == 0)

        copies.store(Data(count: 10), host: alpha.host, url: address(1))
        copies.store(Data(count: 10), host: alpha.host, url: address(2))
        #expect(await copies.total() == 20)
        #expect(walked.trims == 1, "a write under the cap walked the copies")

        copies.store(Data(count: 10), host: alpha.host, url: address(3))
        #expect(await copies.total() == 25)
        #expect(walked.trims == 2)

        copies.forget(host: alpha.host)
        #expect(await copies.total() == 0)
        copies.store(Data(count: 1), host: alpha.host, url: address(4))
        copies.removeAll()
        #expect(await copies.total() == 0)
        copies.remove(host: alpha.host, url: address(4))
        #expect(await copies.total() == nil, "a single removal is not measured")
        copies.store(Data(count: 1), host: alpha.host, url: address(5))
        #expect(await copies.total() == 1)
        #expect(walked.trims == 3, "an unknown total is measured by the next write")
        copies.keepOnly(hosts: [])
        #expect(await copies.total() == nil)
    }

    @Test("Past the cap, the oldest copies on disk go first")
    func capTrimsOldest() async throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try MediaCache(directory: dir)
        let copies = DiskCopies(cache, cap: 15)
        copies.trim()
        for n in 0..<3 {
            copies.store(Data(count: 10), host: alpha.host, url: address(n))
            await copies.settled()
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(Double(n) - 100)],
                ofItemAtPath: cache.file(host: alpha.host, url: address(n)).path
            )
        }
        copies.store(Data(count: 1), host: beta.host, url: address(9))
        await copies.settled()
        #expect(cache.data(host: alpha.host, url: address(0)) == nil, "the oldest copy survived the cap")
        #expect(cache.data(host: alpha.host, url: address(2)) != nil)
        #expect(await copies.bytes(hosts: [alpha.host, beta.host]) == [alpha.host: 10, beta.host: 1])
        #expect(await copies.total() == 11)
        #expect(DiskCopies.defaultCap > 0)
    }

    // MARK: The readout

    @Test("Counts read as one or many, in both languages")
    func countsReadInTheRightNumber() {
        #expect(L10n.count("prefs.held.posts", 1, language: .english) == "1 post")
        #expect(L10n.count("prefs.held.posts", 2, language: .english) == "2 posts")
        #expect(L10n.count("prefs.cache.pictures", 1, language: .english) == "1 picture")
        #expect(L10n.count("prefs.held.posts", 1, language: .taiwanese) == "1 則貼文", "no .one key falls back")
        #expect(L10n.count("prefs.cache.posts", 1, language: .english) == "1 first post")
        #expect(L10n.count("prefs.keep.shorten.title", 1, language: .english) == "Keep only the latest 1 month?")
        #expect(L10n.count("prefs.keep.months", 1, language: .english) == "Latest 1 month")
    }

    @Test("Every key the readout and the drops use is in both languages")
    func keysInBothLanguages() {
        let keys = [
            "prefs.held.posts", "prefs.held.posts.none", "prefs.cache.pictures", "prefs.held.total",
            "prefs.held.memory", "prefs.held.disk", "prefs.held.breakdown", "prefs.held.per",
            "prefs.held.per.week", "prefs.held.per.month", "prefs.held.week", "prefs.drop",
            "prefs.keep", "prefs.keep.forever", "prefs.keep.months", "prefs.keep.shorten.title",
            "prefs.keep.shorten.detail", "prefs.drop.copies", "prefs.drop.copies.title",
            "prefs.drop.copies.detail", "prefs.drop.confirm", "prefs.drop.footer",
        ]
        for key in keys {
            for language in [DummyLanguage.english, .taiwanese] {
                #expect(L10n.t(key, language: language) != key, "\(key) is missing in \(language)")
            }
        }
    }

    @Test("The readout's lines say what they count")
    func readoutLines() {
        let saved = L10n.language
        L10n.language = .english
        defer { L10n.language = saved }
        #expect(UsagePane.postsLine(0) == "No posts held")
        #expect(UsagePane.postsLine(1) == "1 post")
        #expect(UsagePane.postsLine(3) == "3 posts")
        #expect(UsagePane.stretchLabel(now, period: .week).hasPrefix("Week of "))
        #expect(UsagePane.stretchLabel(now, period: .month).contains(String(Calendar.current.component(.year, from: now))))
        #expect(UsagePane.monthChoices == [1, 3, 6, 12])
    }

    /// #21. No view inspector here, so the pages are pinned by the keys their files draw: every
    /// figure and every Clear is on Usage, and Preferences draws none of them.
    @Test("The storage this device uses is on Usage, and Preferences no longer shows it")
    func theFiguresLiveOnUsage() throws {
        let usage = try Self.source("UsagePane")
        let preferences = try Self.source("PreferencesPane")
        for key in [
            "prefs.cache", "prefs.cache.footer", "prefs.held.total", "prefs.held.disk",
            "prefs.held.breakdown", "prefs.cache.clear", "prefs.password.forget",
            "prefs.keep", "prefs.drop.copies",
        ] {
            #expect(usage.contains("\"\(key)\""), "Usage does not draw \(key)")
        }
        for stem in ["prefs.cache", "prefs.held", "prefs.drop", "prefs.keep", "prefs.password"] {
            #expect(!preferences.contains("\"\(stem)"), "Preferences still draws \(stem)")
        }
        #expect(usage.contains("session.clearing = source.host"), "a row's Clear no longer asks the same question")

        for language in [DummyLanguage.english, .taiwanese] {
            let usageTitle = L10n.t("shell.usage.title", language: language)
            let preferencesTitle = L10n.t("shell.preferences.title", language: language)
            for key in ["account.sources.held", "forum.signin.save.on"] {
                let line = L10n.t(key, language: language)
                #expect(line.contains(usageTitle), "\(key) does not send the reader to Usage")
                #expect(!line.contains(preferencesTitle), "\(key) still sends the reader to Preferences")
            }
        }
        #expect(!L10n.t("shell.preferences.summary", language: .english).contains("held"))
    }

    private static func source(_ name: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/FediqoUI/Shell/\(name).swift"),
            encoding: .utf8
        )
    }

    @Test("Switching between week and month rebuilds the counts; a redraw does not")
    func holdingsFollowThePeriod() async {
        let session = ShellSession(http: FixtureHTTP(), store: held())
        await session.reloadFromStore()
        #expect(session.holdings == Holdings(notes: session.notes, per: .month))
        session.heldPeriod = .week
        #expect(session.holdings == Holdings(notes: session.notes, per: .week))
        #expect(session.holdings.bySource == [alpha.host: 2, beta.host: 1])
    }

    @Test("A store loaded at launch is visible after reload")
    func reloadFromStoreAdoptsTheIndex() async {
        let first = note("1", daysAgo: 1, from: alpha)
        let session = ShellSession(http: FixtureHTTP(), store: ItemStore(sources: [alpha], notes: [first]))
        #expect(session.sources.isEmpty)
        await session.reloadFromStore()
        #expect(session.sources.map(\.host) == [alpha.host])
        #expect(session.notes.map(\.id) == [first.id])
        #expect(session.queries.map(\.id) == ["all", "trends"])
    }

    // MARK: Helpers

    private func picture() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let written = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            written, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return written as Data
    }
}
