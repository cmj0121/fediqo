import CryptoKit
import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// A package says how many of the posts it carries are kept (#294), before anything is read
/// back: in its header — and a read back holds it to that, against the store it carries.
@Suite("How many kept posts a package brings")
struct KeptPackageTests {
    typealias Device = PackagerFixture.PackagerDevice
    private static let mastodon = PackagerFixture.mastodon

    private static func posts(_ count: Int, kept: Int) -> [Note] {
        (1...count).map { id in
            Note(
                id: "https://\(mastodon.host)/\(id)", source: mastodon, author: "Ada", handle: "@ada", body: "post \(id)",
                postedAt: PackagerFixture.origin.addingTimeInterval(Double(id)), categories: [.public],
                statusID: "\(id)", kept: id <= kept
            )
        }
    }

    private func package() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fediqo")
    }

    @Test("A package taken away says in its header how many of its posts are kept, none included; one of sign-ins alone says nothing of posts")
    func theHeaderSays() async throws {
        for kept in [3, 0] {
            let from = try await Device(sources: [Self.mastodon], notes: Self.posts(5, kept: kept))
            let url = package()
            defer { from.remove(); try? FileManager.default.removeItem(at: url) }
            try await from.packager().takeAway(to: url, key: .password("password"), pictures: false) { _ in }
            let summary = try await from.packager().preview(url, key: .password("password"))
            #expect(summary.posts == 5 && summary.kept == kept)
        }
        let from = try await Device(sources: [Self.mastodon], notes: Self.posts(5, kept: 2))
        let url = package()
        defer { from.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(
            to: url, key: .password("password"), pictures: false, contents: .signInsOnly
        ) { _ in }
        #expect(try await from.packager().preview(url, key: .password("password")).kept == nil)
    }

    /// A whole package made by hand, as whoever holds a key can make one: the store, the settings
    /// and the secrets it must carry, under a header saying `kept` of what is kept — true or not.
    private func handMade(_ notes: [Note], saying kept: Int?, key: PackageKey, at url: URL) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let file = try StoreFile(at: scratch)
            try await file.save(sources: [Self.mastodon], notes: notes)
            try file.db.close()
        }
        let index = try Data(contentsOf: scratch.appendingPathComponent("index.sqlite"))
        let settings = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        let summary = PackageSummary(
            sources: [.init(host: Self.mastodon.host, kind: .mastodon)], posts: notes.count, timelines: 0,
            takenAt: PackagerFixture.origin, withPictures: false, bytes: index.count + settings.count,
            hasSecrets: false, device: "somebody's", appVersion: "0.1.0", entryCount: 3, kept: kept
        )
        let writer = try PackageWriter(to: url, key: key, summary: summary, rounds: 1000)
        for (kind, name, data) in [
            (PackageFormat.Entry.Kind.store, "index.sqlite", index), (.settings, "settings", settings), (.secrets, "secrets", Data()),
        ] {
            var offset = 0
            try writer.add(kind, name: name, bytes: data.count) { most in
                guard offset < data.count else { return nil }
                let end = min(data.count, offset + most)
                defer { offset = end }
                return data[offset..<end]
            }
        }
        try writer.finish()
    }

    /// A package locked the way a file is, and the way a move from a device nearby is.
    enum Locked: String, CaseIterable, Sendable {
        case byPassword, byAKeyHandedOver

        var key: PackageKey {
            switch self {
            case .byPassword: .password("password")
            case .byAKeyHandedOver: .direct(SymmetricKey(data: Data(repeating: 7, count: 32)))
            }
        }
    }

    @Test(
        "A package whose header says fewer kept posts than its store holds, or more, is refused as not as written before anything here changes — from a file and from a device nearby alike",
        arguments: Locked.allCases, [(held: 4, said: 0), (held: 4, said: 3), (held: 0, said: 2), (held: 2, said: 5)]
    )
    func aHeaderThatLies(locked: Locked, case lie: (held: Int, said: Int)) async throws {
        let onto = try await Device(sources: [Self.mastodon], notes: Self.posts(2, kept: 1))
        let url = package()
        defer { onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await handMade(Self.posts(5, kept: lie.held), saying: lie.said, key: locked.key, at: url)
        #expect(try await onto.packager().preview(url, key: locked.key).kept == lie.said, "the premise: the question would say so")
        let before = try onto.fingerprint()

        await #expect(throws: PackageRefusal.altered) {
            try await onto.packager().readBack(url, key: locked.key, replacing: true) { _ in }
        }
        #expect(try onto.fingerprint() == before, "a refused package changed what this device holds")
        #expect(await onto.store.all().count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: onto.directory.path) == ["index.sqlite"], "its staging was left")
    }

    @Test(
        "A package made the same way whose header tells the truth is read back, and its kept posts arrive kept; one whose header says nothing is read back too",
        arguments: Locked.allCases, [Int?.some(3), .some(0), nil]
    )
    func aHeaderThatDoesNotLie(locked: Locked, said: Int?) async throws {
        let onto = try await Device(sources: [Self.mastodon], notes: Self.posts(2, kept: 1))
        let url = package()
        defer { onto.remove(); try? FileManager.default.removeItem(at: url) }
        let kept = said ?? 3
        try await handMade(Self.posts(5, kept: kept), saying: said, key: locked.key, at: url)
        #expect(try await onto.packager().preview(url, key: locked.key).kept == said)

        try await onto.packager().readBack(url, key: locked.key, replacing: true) { _ in }
        let now = await onto.store.all()
        #expect(now.count == 5 && now.filter(\.kept).count == kept)
    }

    @Test("What a take-away writes is what its store holds: a package of this build's own reads back, kept posts and all")
    func ourOwnReadsBack() async throws {
        let from = try await Device(sources: [Self.mastodon], notes: Self.posts(6, kept: 5))
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        try await onto.packager().readBack(url, key: .password("password"), replacing: false) { _ in }
        #expect(await onto.store.all().filter(\.kept).count == 5)
    }
}
