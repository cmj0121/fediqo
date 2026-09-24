import CryptoKit
import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// #252: a package that is cut, altered, not ours, newer, or opened with the wrong password is
/// refused with its own reason before it touches the store; a device already holding a store
/// is asked first; and a read back that fails midway leaves what signs in as it was. Every
/// refusal test ends on the store byte for byte as it was — each fails without its check.
@Suite("What is read back is proven whole before anything changes")
struct ReadBackRefusalTests {
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

    @Test("A device that already holds a store is not replaced until the person says so")
    func asksBeforeReplacing() async throws {
        let from = try await Self.populated()
        let onto = try await Device(sources: [Source(host: "other.example", kind: .mastodon)], notes: [Self.note("o", source: Source(host: "other.example", kind: .mastodon))])
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        let before = try onto.fingerprint()
        await #expect(throws: PackageFault.alreadyHeld) {
            try await readAll(url, key: .password("password"), onto: onto)
        }
        #expect(try onto.fingerprint() == before)
        try await readAll(url, key: .password("password"), onto: onto, replacing: true)
        #expect(try StoreFile(at: onto.directory).load().sources == [Self.mastodon, Self.forum])
        #expect(await onto.store.sources().map(\.host) == [Self.mastodon.host, Self.forum.host])
    }

    // MARK: - #252

    /// The refusals, each on a real package of a populated device with pictures, and each
    /// leaving a device that already holds a store byte for byte as it was.
    private func refused(
        _ bend: (Data) -> Data, key: PackageKey = .password("open sesame"), expecting refusal: PackageRefusal
    ) async throws {
        let from = try await Self.populated()
        let held = try await Self.populated()
        let url = package()
        defer { from.remove(); held.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: .password("open sesame"), pictures: true) { _ in }
        try bend(try Data(contentsOf: url)).write(to: url)
        let before = try held.fingerprint()
        let beforeStore = await held.store.snapshot()
        await #expect(throws: refusal) {
            try await held.packager().readBack(url, key: key, replacing: true) { _ in }
        }
        #expect(try held.fingerprint() == before)
        let after = await held.store.snapshot()
        #expect(after.sources == beforeStore.sources && after.notes == beforeStore.notes)
        #expect(try held.tokens.token(host: Self.mastodon.host)?.accessToken == "t")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: held.directory.path)
            .filter { $0.hasPrefix("incoming-") }
        #expect(leftovers.isEmpty, "nothing staged is left behind")
    }

    @Test("A wrong password is refused as such, and changes nothing")
    func wrongPassword() async throws {
        try await refused({ $0 }, key: .password("open sesamE"), expecting: .wrongPassword)
        try await refused({ $0 }, key: .direct(SymmetricKey(size: .bits256)), expecting: .wrongPassword)
    }

    @Test("A file cut short is refused as such, and changes nothing")
    func cutShort() async throws {
        try await refused({ $0.prefix($0.count / 2) }, expecting: .cutShort)
        try await refused({ $0.prefix($0.count - 1) }, expecting: .cutShort)
    }

    @Test("A file altered is refused as such, and changes nothing")
    func altered() async throws {
        try await refused({ whole in
            var bent = whole
            bent[whole.count / 2] ^= 0x01
            return bent
        }, expecting: .altered)
        try await refused({ whole in
            var bent = whole
            bent[whole.count - 4] ^= 0x01
            return bent
        }, expecting: .altered)
    }

    @Test("A file that is not ours, or from a newer build, is refused as such, and changes nothing")
    func notOursOrNewer() async throws {
        try await refused({ _ in Data("SQLite format 3\u{0}".utf8) }, expecting: .notOurs)
        try await refused({ whole in
            var bent = whole
            bent[4] = 2
            return bent
        }, expecting: .newer)
    }

    @Test("A package whose store is from a newer build is refused as newer after every tag held, and changes nothing")
    func newerStore() async throws {
        let from = try await Self.populated()
        let held = try await Self.populated()
        let url = package()
        defer { from.remove(); held.remove(); try? FileManager.default.removeItem(at: url) }
        // The index of the package marked as a later build's: a migration this build does not know.
        try await from.file!.db.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v99-from-the-future')")
        }
        let future = try await from.file!.db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM grdb_migrations").count }
        #expect(future > 4)
        // Taken away from a snapshot of memory, the fresh index would be this build's; write the
        // future index by hand into the package instead.
        let index = from.directory.appendingPathComponent("index.sqlite")
        let bytes = try Data(contentsOf: index)
        let summary = PackageSummary(
            sources: [], posts: 0, timelines: 0, takenAt: Date(), withPictures: false, bytes: bytes.count,
            hasSecrets: false, device: "later", appVersion: "9.9", entryCount: 3
        )
        let writer = try PackageWriter(to: url, key: .password("password"), summary: summary, rounds: 1000)
        var offset = 0
        try writer.add(.store, name: "index.sqlite", bytes: bytes.count) { most in
            guard offset < bytes.count else { return nil }
            let end = min(bytes.count, offset + most)
            defer { offset = end }
            return bytes[offset..<end]
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
        var sent = false
        try writer.add(.settings, name: "settings", bytes: plist.count) { _ in
            defer { sent = true }
            return sent ? nil : plist
        }
        try writer.add(.secrets, name: "secrets", bytes: 0) { _ in nil }
        try writer.finish()

        let before = try held.fingerprint()
        await #expect(throws: PackageRefusal.newer) {
            try await held.packager().readBack(url, key: .password("password"), replacing: true) { _ in }
        }
        #expect(try held.fingerprint() == before)
    }

    @Test("A read back that fails midway — the Keychain refusing — leaves what signs in, the index, the copies and the settings as they were")
    func keychainRefusesMidway() async throws {
        let from = try await Self.populated()
        let onto = try await Self.populated()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: true) { _ in }
        try onto.tokens.save(MastodonToken(host: "kept.example", accessToken: "k", clientID: "c", clientSecret: "s"))
        try onto.tokens.forget(host: Self.mastodon.host)
        onto.defaults.set("en", forKey: "fediqo.dummy.language")
        let before = try onto.fingerprint()
        let beforeStore = await onto.store.snapshot()
        let refusing = RefusingTokens(inner: onto.tokens)
        let packager = StorePackager(
            directory: onto.directory, file: onto.file, store: onto.store, media: onto.media, tokens: refusing,
            credentials: onto.credentials, defaults: onto.defaults, device: "a test", appVersion: "0.7.0",
            freeSpace: { _ in .max }, rounds: 1000
        )
        await #expect(throws: ForumCredentialError.keychain(-1)) {
            try await packager.readBack(url, key: .password("password"), replacing: true) { _ in }
        }
        #expect(try onto.tokens.token(host: "kept.example")?.accessToken == "k", "what was there is put back")
        #expect(try onto.tokens.token(host: Self.mastodon.host) == nil)
        #expect(try onto.fingerprint() == before, "index, copies and settings are as they were")
        let after = await onto.store.snapshot()
        #expect(after.sources == beforeStore.sources && after.notes == beforeStore.notes)
        #expect(try StoreFile(at: onto.directory).load().notes.count == beforeStore.notes.count)
    }

    @Test("A disk refusing after the Keychain accepted puts the sign-ins back, and touches nothing else")
    func diskRefusesAfterKeychain() async throws {
        let from = try await Self.populated()
        let onto = try await Device(noFile: true)
        let url = package()
        let manager = FileManager.default
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onto.directory.path)
            from.remove(); onto.remove(); try? manager.removeItem(at: url)
        }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        try onto.tokens.save(MastodonToken(host: "kept.example", accessToken: "k", clientID: "c", clientSecret: "s"))
        onto.defaults.set("en", forKey: "fediqo.dummy.language")
        // Staged first, then the folder refuses every move: the index cannot land.
        let gate = GatedPackager(device: onto)
        await #expect(throws: (any Error).self) {
            try await gate.readBack(url, key: .password("password"))
        }
        #expect(try onto.tokens.token(host: "kept.example")?.accessToken == "k")
        #expect(try onto.tokens.token(host: Self.mastodon.host) == nil, "the package's sign-in was taken out again")
        #expect(onto.defaults.string(forKey: "fediqo.dummy.language") == "en")
        #expect(!manager.fileExists(atPath: onto.directory.appendingPathComponent("index.sqlite").path))
    }

    @Test("A step refusing and an earlier one not going back is said as such, naming what did not")
    func unwoundIsSaid() async throws {
        let from = try await Self.populated()
        let onto = try await Device(noFile: true)
        let url = package()
        let manager = FileManager.default
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: onto.directory.path)
            from.remove(); onto.remove(); try? manager.removeItem(at: url)
        }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        try onto.tokens.save(MastodonToken(host: "kept.example", accessToken: "k", clientID: "c", clientSecret: "s"))
        // The Keychain accepts the package's sign-in, the folder then refuses the index, and
        // the Keychain refuses to put the old sign-in back.
        let path = onto.directory.path
        let tokens = SealingTokens(inner: onto.tokens) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        }
        let packager = StorePackager(
            directory: onto.directory, file: nil, store: onto.store, media: onto.media, tokens: tokens,
            credentials: onto.credentials, defaults: onto.defaults, device: "a test", appVersion: "0.7.0",
            freeSpace: { _ in .max }, rounds: 1000
        )
        await #expect(throws: PackageFault.unwound(steps: ["secrets"])) {
            try await packager.readBack(url, key: .password("password"), replacing: false) { _ in }
        }
    }

    @Test("A commit killed between moving the old index aside and finishing is kept by the sweep, and one that finished is not")
    func halfCommitIsKept() async throws {
        let from = try await Self.populated()
        let onto = try await Device(noFile: true)
        let url = package()
        let manager = FileManager.default
        defer { from.remove(); onto.remove(); try? manager.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        try await readAll(url, key: .password("password"), onto: onto)
        let left = try manager.contentsOfDirectory(atPath: onto.directory.path).filter { $0.hasPrefix("incoming-") }
        #expect(left.isEmpty, "a finished commit leaves nothing aside")
        let half = onto.directory.appendingPathComponent("incoming-aside-half")
        try manager.createDirectory(at: half, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: half.appendingPathComponent("index.sqlite"))
        try Data().write(to: half.appendingPathComponent(StorePackager.committingMarker))
        let done = onto.directory.appendingPathComponent("incoming-aside-done")
        try manager.createDirectory(at: done, withIntermediateDirectories: true)
        StorePackager.sweepLeftovers(directory: onto.directory, media: onto.media.location, temporary: onto.root)
        #expect(manager.fileExists(atPath: half.appendingPathComponent("index.sqlite").path), "the old index is kept")
        #expect(!manager.fileExists(atPath: done.path))
    }

    @Test("An index this run left alone as a newer build's is not written over, and says so")
    func indexIsNewer() async throws {
        let from = try await Self.populated()
        let onto = try await Device(noFile: true)
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: .password("password"), pictures: false) { _ in }
        try FileManager.default.createDirectory(at: onto.directory, withIntermediateDirectories: true)
        try Data("a newer build's index".utf8).write(to: onto.directory.appendingPathComponent("index.sqlite"))
        let before = try onto.fingerprint()
        let packager = StorePackager(
            directory: onto.directory, file: nil, store: onto.store, media: onto.media, tokens: onto.tokens,
            credentials: onto.credentials, defaults: onto.defaults, device: "a test", appVersion: "0.7.0",
            storeIsNewer: true, freeSpace: { _ in .max }, rounds: 1000
        )
        #expect(try await packager.weigh().holdsStore, "an index on disk this run could not open is a store")
        await #expect(throws: PackageFault.indexIsNewer) {
            try await packager.readBack(url, key: .password("password"), replacing: true) { _ in }
        }
        #expect(try onto.fingerprint() == before)
    }

}

/// A device whose folder stops taking files between the staging and the commit: the staging
/// lands, the Keychain accepts, and then the index cannot be moved in.
private struct GatedPackager {
    let device: PackagerFixture.PackagerDevice

    func readBack(_ url: URL, key: PackageKey) async throws {
        let path = device.directory.path
        let watching = WatchingTokens(inner: device.tokens) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        }
        let packager = StorePackager(
            directory: device.directory, file: nil, store: device.store, media: device.media, tokens: watching,
            credentials: device.credentials, defaults: device.defaults, device: "a test", appVersion: "0.7.0",
            freeSpace: { _ in .max }, rounds: 1000
        )
        try await packager.readBack(url, key: key, replacing: false) { _ in }
    }
}

/// A Keychain that runs `onSave` once the package's registration — the last thing filed — is
/// in, and refuses everything after.
private final class SealingTokens: MastodonTokenStore, @unchecked Sendable {
    let inner: MemoryMastodonTokens
    let onSave: @Sendable () -> Void
    private var sealed = false
    init(inner: MemoryMastodonTokens, onSave: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.onSave = onSave
    }
    private func open() throws { if sealed { throw ForumCredentialError.keychain(-1) } }
    func token(host: String) throws -> MastodonToken? { try inner.token(host: host) }
    func save(_ token: MastodonToken) throws { try open(); try inner.save(token) }
    func forget(host: String) throws { try open(); try inner.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try open(); return try inner.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try inner.grants() }
    func app(host: String) throws -> MastodonApp? { try inner.app(host: host) }
    func save(_ app: MastodonApp) throws {
        try open()
        try inner.save(app)
        sealed = true
        onSave()
    }
    func forgetApp(host: String) throws { try open(); try inner.forgetApp(host: host) }
}

/// A Keychain that runs `onSave` the first time the package's token is filed.
private final class WatchingTokens: MastodonTokenStore, @unchecked Sendable {
    let inner: MemoryMastodonTokens
    let onSave: @Sendable () -> Void
    init(inner: MemoryMastodonTokens, onSave: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.onSave = onSave
    }
    func token(host: String) throws -> MastodonToken? { try inner.token(host: host) }
    func save(_ token: MastodonToken) throws {
        try inner.save(token)
        onSave()
    }
    func forget(host: String) throws { try inner.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try inner.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try inner.grants() }
    func app(host: String) throws -> MastodonApp? { try inner.app(host: host) }
    func save(_ app: MastodonApp) throws { try inner.save(app) }
    func forgetApp(host: String) throws { try inner.forgetApp(host: host) }
}

/// A Keychain that refuses to file the package's token, as a locked device's might, and takes
/// back what it held before.
private final class RefusingTokens: MastodonTokenStore, @unchecked Sendable {
    let inner: MemoryMastodonTokens
    init(inner: MemoryMastodonTokens) { self.inner = inner }
    func token(host: String) throws -> MastodonToken? { try inner.token(host: host) }
    func save(_ token: MastodonToken) throws {
        guard token.host == "kept.example" else { throw ForumCredentialError.keychain(-1) }
        try inner.save(token)
    }
    func forget(host: String) throws { try inner.forget(host: host) }
    func forget(_ token: MastodonToken) throws -> Bool { try inner.forget(token) }
    func grants() throws -> [String: MastodonGrant] { try inner.grants() }
    func app(host: String) throws -> MastodonApp? { try inner.app(host: host) }
    func save(_ app: MastodonApp) throws { try inner.save(app) }
    func forgetApp(host: String) throws { try inner.forgetApp(host: host) }
}
