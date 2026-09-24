import CryptoKit
import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// #247: a real store, taken away through a temp package and read back the same — posts,
/// sources, the person's timelines and settings, and what signs in — on a clean device, with
/// and without pictures, and through a store larger than one chunk. What is refused, and that
/// the store is untouched, is `ReadBackRefusalTests` (#252).
@Suite("Taking a store away and reading it back")
struct StorePackagerTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let mastodon = PackagerFixture.mastodon
    private static let forum = PackagerFixture.forum

    private static func note(
        _ id: String, source: Source = mastodon, holding: Holding = .arrived, body: String? = nil
    ) -> Note {
        PackagerFixture.note(id, source: source, holding: holding, body: body)
    }

    private static func populated() async throws -> Device { try await PackagerFixture.populated() }
    private func package() -> URL { PackagerFixture.package() }

    private func readAll(_ url: URL, key: PackageKey, onto device: Device, replacing: Bool = false) async throws {
        try await device.packager().readBack(url, key: key, replacing: replacing) { _ in }
    }

    @Test("Taken away with pictures and read back on a clean device, the store is the same, and so is what signs in", arguments: [true, false])
    func roundTrip(pictures: Bool) async throws {
        let from = try await Self.populated()
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }

        let weight = try await from.packager().weigh()
        #expect(weight.holdsStore)
        #expect(weight.withPictures == weight.withoutPictures + 3100)
        #expect(weight.withoutPictures > 0)

        var seen: [PackageProgress] = []
        let progress = Progress()
        try await from.packager().takeAway(to: url, key: .password("open sesame"), pictures: pictures) { progress.add($0) }
        seen = progress.all
        #expect(seen.last?.fraction == 1)
        #expect(seen.count == (pictures ? 6 : 4), "store, settings, secrets, one profile, and the pictures")

        let summary = try await onto.packager().preview(url, key: .password("open sesame"))
        #expect(summary.posts == 3)
        #expect(summary.timelines == 2)
        #expect(summary.sources.map(\.host) == [Self.mastodon.host, Self.forum.host])
        #expect(summary.withPictures == pictures)
        #expect(summary.hasSecrets)
        #expect(summary.device == "a test")
        #expect(summary.entryCount == (pictures ? 6 : 4))

        #expect(try await onto.packager().weigh().holdsStore == false)
        try await readAll(url, key: .password("open sesame"), onto: onto)

        // The store in memory, and the index on disk reopened as a launch would.
        let held = await onto.store.snapshot()
        #expect(held.sources == [Self.mastodon, Self.forum])
        #expect(held.notes.map(\.id).sorted() == ["1", "2", "3"])
        #expect(held.notes.first { $0.id == "3" }?.holding == .aside)
        let reopened = try StoreFile(at: onto.directory).load()
        #expect(reopened.sources == [Self.mastodon, Self.forum])
        #expect(reopened.notes.map(\.id) == ["1", "2", "3"])
        // What each source said about itself, as of when (#188), in memory and on disk.
        let word = PackagerFixture.said.said(at: PackagerFixture.origin)
        #expect(await onto.store.said(host: Self.mastodon.host) == word)
        #expect(reopened.said == [word])
        // The person's settings.
        #expect(onto.defaults.data(forKey: "fediqo.timelines") == from.defaults.data(forKey: "fediqo.timelines"))
        #expect(onto.defaults.string(forKey: "fediqo.dummy.language") == "zh-TW")
        #expect(onto.defaults.string(forKey: "fediqo.dummy.keepMonths") == "6")
        // What signs in.
        #expect(try onto.tokens.token(host: Self.mastodon.host)?.accessToken == "t")
        #expect(try onto.tokens.app(host: Self.mastodon.host)?.clientSecret == "s")
        #expect(try onto.credentials.credential(host: Self.forum.host)?.password == "hunter2")
        // The picture copies, where they were asked for.
        let copy = onto.media.data(host: Self.mastodon.host, url: URL(string: "https://cdn.example/1.jpg")!)
        #expect(copy == (pictures ? Data(repeating: 7, count: 3000) : nil))
        #expect(onto.media.totalBytes() == (pictures ? 3100 : 0))
        #expect(try await onto.packager().weigh().holdsStore)
    }

    @Test("A store larger than one chunk streams through, and the index is opened whole after")
    func largeStore() async throws {
        var notes: [Note] = []
        let filler = String(repeating: "x", count: 4000)
        for i in 0..<600 { notes.append(Self.note("big-\(i)", body: filler)) }
        let from = try await Device(sources: [Self.mastodon], notes: notes)
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        let reader = try PackageReader(at: url)
        #expect(reader.prelude.bytes > PackageFormat.chunkBytes, "the index alone is more than one chunk")
        try await readAll(url, key: .password("password"), onto: onto)
        let reopened = try StoreFile(at: onto.directory).load()
        #expect(reopened.notes.count == 600)
    }

    @Test("Not enough room on the device refuses before staging, with the numbers")
    func noRoom() async throws {
        let from = try await Self.populated()
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: true) { _ in }
        let needed = try PackageReader(at: url).prelude.bytes
        let before = try onto.fingerprint()
        await #expect(throws: PackageFault.noRoom(needed: needed, free: 10)) {
            try await onto.packager(free: 10).readBack(url, key: .password("password"), replacing: false) { _ in }
        }
        #expect(try onto.fingerprint() == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: onto.directory.path).allSatisfy { !$0.hasPrefix("incoming-") })
    }

    @Test("An empty password is refused before a file is made")
    func emptyPassword() async throws {
        let from = try await Self.populated()
        let url = package()
        defer { from.remove(); try? FileManager.default.removeItem(at: url) }
        await #expect(throws: PackageFault.emptyPassword) {
            try await from.packager().takeAway(to: url, key: .password(""), pictures: false) { _ in }
        }
        await #expect(throws: PackageFault.shortPassword) {
            try await from.packager().takeAway(to: url, key: .password("seven77"), pictures: false) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("What a run killed midway left behind is swept at launch, and nothing else is")
    func sweep() async throws {
        let onto = try await Device()
        defer { onto.remove() }
        let manager = FileManager.default
        let tmp = onto.root.appendingPathComponent("tmp", isDirectory: true)
        let stale = [
            tmp.appendingPathComponent("takeaway-old"),
            onto.directory.appendingPathComponent("incoming-old"),
            onto.root.appendingPathComponent("media-aside-old"),
        ]
        let kept = [tmp.appendingPathComponent("other"), onto.directory.appendingPathComponent("index-unreadable-x")]
        for folder in stale + kept {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: folder.appendingPathComponent("index.sqlite"))
        }
        StorePackager.sweepLeftovers(directory: onto.directory, media: onto.media.location, temporary: tmp)
        for folder in stale { #expect(!manager.fileExists(atPath: folder.path), "\(folder.lastPathComponent) stays") }
        for folder in kept { #expect(manager.fileExists(atPath: folder.path), "\(folder.lastPathComponent) went") }
        #expect(manager.fileExists(atPath: onto.directory.appendingPathComponent("index.sqlite").path))
    }

    @Test("A device whose index this run could not open still takes the package's index, by a move")
    func noOpenFile() async throws {
        let from = try await Self.populated()
        let onto = try await Device(noFile: true)
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        try await readAll(url, key: .password("password"), onto: onto)
        #expect(try StoreFile(at: onto.directory).load().notes.count == 3)
    }
}

/// Progress lines as they came, from whatever thread the carrier called on.
private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [PackageProgress] = []

    func add(_ line: PackageProgress) { lock.withLock { lines.append(line) } }
    var all: [PackageProgress] { lock.withLock { lines } }
}
