import FediqoCore
import Foundation
import os
import Testing
@testable import FediqoPersistence

/// #344: a package carries the person's own lists as it always did — under the keys they were
/// once kept by — though on the device each is now a file beside the index. A read back
/// replaces them, and its undo puts them back.
@Suite("The person's own lists ride in a package as they did, and are laid into their files")
struct ListsInAPackageTests {
    private typealias Device = PackagerFixture.PackagerDevice
    private static let timelines = Data(#"{"version":3,"timelines":[{"id":"a","name":"Mine","rules":[]}]}"#.utf8)
    private static let allowances = Data(#"{"off":["directory"],"own":[]}"#.utf8)
    private static let key = PackageKey.password("password")

    private func package() -> URL { PackagerFixture.package() }

    /// Something in the way of the limits' account: the step after the lists refuses.
    private func blockLimits(of device: Device) throws {
        let blocking = device.directory.appendingPathComponent(LimitAccountFile.name, isDirectory: true)
        try FileManager.default.createDirectory(at: blocking, withIntermediateDirectories: true)
        try Data().write(to: blocking.appendingPathComponent("in the way"))
    }

    @Test("Taken away from their files and read back into files: the same lists, and nothing under either key on the way or after")
    func fromFilesToFiles() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        #expect(from.lists.timelines.write(Self.timelines) && from.lists.allowances.write(Self.allowances))
        from.defaults.set("zh-TW", forKey: "fediqo.dummy.language")
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        try await onto.packager().readBack(url, key: Self.key, replacing: true) { _ in }
        #expect(onto.lists.timelines.read() == .data(Self.timelines))
        #expect(onto.lists.allowances.read() == .data(Self.allowances))
        // Plain settings stay in the preferences; the lists' keys are set on neither device.
        #expect(onto.defaults.string(forKey: "fediqo.dummy.language") == "zh-TW")
        for device in [from, onto] {
            #expect(device.defaults.object(forKey: "fediqo.timelines") == nil && device.defaults.object(forKey: "fediqo.allowances") == nil)
        }
    }

    @Test("A package from a device that still kept them under their keys — an earlier build's — reads back the same as one from files")
    func anEarlierBuildsPackage() async throws {
        let keyed = try await Device(sources: [PackagerFixture.mastodon])
        let filed = try await Device(sources: [PackagerFixture.mastodon])
        let ontoKeyed = try await Device()
        let ontoFiled = try await Device()
        let urls = [package(), package()]
        defer {
            for device in [keyed, filed, ontoKeyed, ontoFiled] { device.remove() }
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
        keyed.defaults.set(Self.timelines, forKey: "fediqo.timelines")
        keyed.defaults.set(Self.allowances, forKey: "fediqo.allowances")
        #expect(filed.lists.timelines.write(Self.timelines) && filed.lists.allowances.write(Self.allowances))
        // With no canary nothing is moved: the keys are taken away where they lie, as an
        // earlier build took them.
        let none = ProtectedByHand(.none).protected
        try await keyed.packager(protected: none).takeAway(to: urls[0], key: Self.key, pictures: false) { _ in }
        #expect(keyed.defaults.data(forKey: "fediqo.timelines") == Self.timelines, "the premise: still under its key")
        try await filed.packager().takeAway(to: urls[1], key: Self.key, pictures: false) { _ in }
        try await ontoKeyed.packager().readBack(urls[0], key: Self.key, replacing: true) { _ in }
        try await ontoFiled.packager().readBack(urls[1], key: Self.key, replacing: true) { _ in }
        for onto in [ontoKeyed, ontoFiled] {
            #expect(onto.lists.timelines.read() == .data(Self.timelines))
            #expect(onto.lists.allowances.read() == .data(Self.allowances))
            #expect(onto.defaults.object(forKey: "fediqo.timelines") == nil && onto.defaults.object(forKey: "fediqo.allowances") == nil)
        }
    }

    @Test("A package that carries neither list removes both files — and a key an earlier build left — so nobody's lists outlive a read back")
    func aPackageWithoutThem() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        #expect(onto.lists.timelines.write(Self.timelines))
        onto.defaults.set(Self.allowances, forKey: "fediqo.allowances")
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        try await onto.packager().readBack(url, key: Self.key, replacing: true) { _ in }
        #expect(onto.lists.timelines.read() == .none && onto.lists.allowances.read() == .none)
        let names = try FileManager.default.contentsOfDirectory(atPath: onto.directory.path)
        #expect(!names.contains(ListFile.timelinesName) && !names.contains(ListFile.allowancesName))
        #expect(onto.defaults.object(forKey: "fediqo.allowances") == nil)
    }

    @Test("A read back that a later step refuses puts the lists back as they were: the files written again, and one the package had removed made again",
          arguments: [true, false])
    func undone(carried: Bool) async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        if carried { #expect(from.lists.timelines.write(Data(#"{"version":3,"timelines":[]}"#.utf8))) }
        #expect(onto.lists.timelines.write(Self.timelines) && onto.lists.allowances.write(Self.allowances))
        onto.defaults.set("en", forKey: "fediqo.dummy.language")
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        try blockLimits(of: onto)
        await #expect(throws: (any Error).self) {
            try await onto.packager().readBack(url, key: Self.key, replacing: true) { _ in }
        }
        #expect(onto.lists.timelines.read() == .data(Self.timelines))
        #expect(onto.lists.allowances.read() == .data(Self.allowances))
        #expect(onto.defaults.string(forKey: "fediqo.dummy.language") == "en")
    }

    @Test("A device that locks as the package's list is laid down — no new file is taken, and a rename still is — has the person's own lists put back by renames, with nothing owed and nothing left aside")
    func undoneByARename() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        #expect(from.lists.timelines.write(Data(#"{"version":3,"timelines":[]}"#.utf8)))
        #expect(onto.lists.timelines.write(Self.timelines) && onto.lists.allowances.write(Self.allowances))
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        let hand = ProtectedByHand(.reads)
        let locking = Guarded.Device(
            asks: .complete, held: { _ in nil }, canaryTook: { true }, count: {},
            asking: {
                hand.turn(canary: .refused)
                throw CocoaError(.fileWriteNoPermission)
            }
        )
        var packager = onto.packager(protected: hand.protected)
        packager.lists = ListFiles(directory: onto.directory, defaults: onto.defaults, protected: hand.protected, device: locking)
        await #expect(throws: (any Error).self) {
            try await packager.readBack(url, key: Self.key, replacing: true) { _ in }
        }
        #expect(!packager.owesUndo && StorePackager.owedNames(in: onto.directory).isEmpty)
        #expect(onto.lists.timelines.read() == .data(Self.timelines))
        #expect(onto.lists.allowances.read() == .data(Self.allowances))
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: onto.directory.path)).contains { $0.contains(ListFile.asideInfix) })
    }

    @Test("A read back that holds leaves nothing aside")
    func settled() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        #expect(onto.lists.timelines.write(Self.timelines) && onto.lists.allowances.write(Self.allowances))
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        try await onto.packager().readBack(url, key: Self.key, replacing: true) { _ in }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: onto.directory.path)).contains { $0.contains(ListFile.asideInfix) })
    }

    @Test("A list that will not be read stops a read back before anything is replaced, and a take-away before anything is written: it is not carried, or put back, as none")
    func notReadIsNotNone() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device(sources: [PackagerFixture.mastodon])
        let urls = [package(), package()]
        let closed = onto.directory.appendingPathComponent(ListFile.timelinesName)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: closed.path)
            from.remove(); onto.remove()
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
        try await from.packager().takeAway(to: urls[0], key: Self.key, pictures: false) { _ in }
        #expect(onto.lists.timelines.write(Self.timelines) && onto.lists.allowances.write(Self.allowances))
        onto.defaults.set("en", forKey: "fediqo.dummy.language")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        await #expect(throws: (any Error).self) {
            try await onto.packager().readBack(urls[0], key: Self.key, replacing: true) { _ in }
        }
        await #expect(throws: (any Error).self) {
            try await onto.packager().takeAway(to: urls[1], key: Self.key, pictures: false) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: urls[1].path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: closed.path)
        #expect(onto.lists.timelines.read() == .data(Self.timelines))
        #expect(onto.lists.allowances.read() == .data(Self.allowances))
        #expect(onto.defaults.string(forKey: "fediqo.dummy.language") == "en")
    }

    @Test("An undo of the lists that a lock refuses stays owed, by name beside the index, and is done when the device is unlocked")
    func owedUnderALock() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        let folder = onto.directory.path
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
            from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url)
        }
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        try blockLimits(of: onto)
        // The device locks as the undo begins — the moment the undo sets the first preference
        // back: from then the folder takes no file, and the canary refuses. (Asked, the canary
        // lets the folder be written again, so that what is owed can be named in it.)
        let locked = OSAllocatedUnfairLock(initialState: false)
        let defaults = ToldDefaults { key in
            guard key == "fediqo.dummy.language" else { return }
            locked.withLock { $0 = true }
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        }
        let protected = ProtectedData(
            flag: { true },
            canary: {
                guard locked.withLock({ $0 }) else { return .reads }
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
                return .refused
            },
            remade: { .refused }, unlockedForSomebody: { false }, changes: { AsyncStream { $0.finish() } }
        )
        let lists = ListFiles(directory: onto.directory, defaults: defaults, protected: .always)
        #expect(lists.timelines.write(Self.timelines) && lists.allowances.write(Self.allowances))
        defaults.set("en", forKey: "fediqo.dummy.language")
        defaults.told = true
        let packager = StorePackager(
            directory: onto.directory, file: onto.file, store: onto.store, media: onto.media, tokens: onto.tokens,
            credentials: onto.credentials, defaults: defaults, device: "a test", appVersion: "0.7.0",
            protected: protected, freeSpace: { _ in .max }, rounds: 1000
        )
        do {
            try await packager.readBack(url, key: Self.key, replacing: true) { _ in }
            Issue.record("the read back held")
        } catch PackageFault.unwound(let steps) {
            #expect(steps.contains("settings"))
        }
        #expect(packager.owesUndo)
        #expect(StorePackager.owedNames(in: onto.directory).contains("settings"))
        #expect(lists.timelines.read() == .none && lists.allowances.read() == .none, "the premise: not put back, and the package carried neither")
        // Unlocked: the step is done, and its name goes.
        defaults.told = false
        locked.withLock { $0 = false }
        #expect(await packager.finishOwed())
        #expect(lists.timelines.read() == .data(Self.timelines))
        #expect(lists.allowances.read() == .data(Self.allowances))
        #expect(defaults.string(forKey: "fediqo.dummy.language") == "en")
        #expect(StorePackager.owedNames(in: onto.directory).isEmpty)
    }
}

/// Preferences in memory that say when a key is set, once `told`.
private final class ToldDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let onSet: (String) -> Void
    var told = false

    init(onSet: @escaping (String) -> Void) {
        self.onSet = onSet
        super.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func dictionaryRepresentation() -> [String: Any] { values }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func set(_ value: Any?, forKey key: String) {
        if told { onSet(key) }
        values[key] = value
    }
}
