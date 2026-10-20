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

    private static let hides = Data(#"{"version":1,"hides":[{"host":"m.example","handle":"@ada@m.example","why":"muted"}]}"#.utf8)

    @Test("What the person hides of whom they muted or blocked (#314) rides in a package beside the other lists, from a file or from its key alike, and is laid into its file")
    func theHidesRideToo() async throws {
        let filed = try await Device(sources: [PackagerFixture.mastodon])
        let keyed = try await Device(sources: [PackagerFixture.mastodon])
        let ontoFiled = try await Device()
        let ontoKeyed = try await Device()
        let urls = [package(), package()]
        defer {
            for device in [filed, keyed, ontoFiled, ontoKeyed] { device.remove() }
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
        #expect(filed.lists.hides.write(Self.hides))
        keyed.defaults.set(Self.hides, forKey: "fediqo.hides")
        try await filed.packager().takeAway(to: urls[0], key: Self.key, pictures: false) { _ in }
        try await keyed.packager(protected: ProtectedByHand(.none).protected).takeAway(to: urls[1], key: Self.key, pictures: false) { _ in }
        try await ontoFiled.packager().readBack(urls[0], key: Self.key, replacing: true) { _ in }
        try await ontoKeyed.packager().readBack(urls[1], key: Self.key, replacing: true) { _ in }
        for onto in [ontoFiled, ontoKeyed] {
            #expect(onto.lists.hides.read() == .data(Self.hides))
            #expect(onto.defaults.object(forKey: "fediqo.hides") == nil)
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

    // MARK: - Named before the step, and a commit's own name

    /// A device like any other, that says when a list is about to be written.
    private func saying(_ asked: @escaping @Sendable () -> Void) -> Guarded.Device {
        Guarded.Device(asks: .complete, simulated: true, held: { _ in nil }, canaryTook: { false }, count: {}, asking: asked)
    }

    private func names(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Whether `folder` holds a step's name or a commit's own.
    private func named(_ folder: URL) throws -> Bool {
        try names(folder).contains {
            $0.hasPrefix(StorePackager.owedPrefix) || $0.hasPrefix(StorePackager.Flight.prefix) || $0.hasPrefix(StorePackager.Flight.heldPrefix)
        }
    }

    private func next(on folder: URL, of device: Device) -> StorePackager {
        StorePackager(
            directory: folder, file: nil, store: ItemStore(sources: [], notes: []), media: nil, tokens: device.tokens,
            credentials: device.credentials, defaults: device.defaults, device: "a test", appVersion: "0.7.0",
            protected: .always, freeSpace: { _ in .max }, rounds: 1000
        )
    }

    @Test("On a device that takes no new file once it has locked — a phone — what a lock would not let be put back is still named beside the index: each name was made before its step, and the next run says it")
    func namedBeforeTheLock() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        let folder = onto.directory.path
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
            from.remove(); onto.remove()
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: copy)
        }
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        try blockLimits(of: onto)
        // The device locks as the undo begins: from then the folder takes no file — and
        // goes on taking none, whoever asks the canary.
        let locked = OSAllocatedUnfairLock(initialState: false)
        let defaults = ToldDefaults { key in
            guard key == "fediqo.dummy.language" else { return }
            locked.withLock { $0 = true }
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder)
        }
        let protected = ProtectedData(
            flag: { true }, canary: { locked.withLock { $0 } ? .refused : .reads },
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
        #expect(StorePackager.owedNames(in: onto.directory).contains("settings"), "not named: the name could only have been made before the lock")
        // **The suspended app is ended there.** The next launch, on an unlocked device, finds
        // the folder as it stands with nobody holding the commit's name.
        try FileManager.default.copyItem(at: onto.directory, to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        let after = next(on: copy, of: onto)
        #expect(after.leftOwed().contains("settings"))
        StorePackager.sweepLeftovers(directory: copy, media: nil, temporary: copy)
        let theirs = ListFiles(directory: copy, defaults: onto.defaults, protected: .always)
        #expect(theirs.timelines.read() == .data(Self.timelines) && theirs.allowances.read() == .data(Self.allowances))
        #expect(after.leftOwed().contains("settings"), "kept to be said until the person has been told")
        after.toldLeftOwed()
        #expect(try !named(copy))
        // And where the run lives to see the unlock: the step is done, and every name goes.
        defaults.told = false
        locked.withLock { $0 = false }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder)
        #expect(await packager.finishOwed())
        #expect(lists.timelines.read() == .data(Self.timelines) && lists.allowances.read() == .data(Self.allowances))
        #expect(try !named(onto.directory))
    }

    @Test("An undo of the lists refused halfway — one list back, the other not — is finished later without asking again for the one already back, whose aside is gone")
    func owedHalfway() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        // What stands in the second list's place as the undo reaches it, and will not go.
        let inTheWay = onto.directory.appendingPathComponent(ListFile.timelinesName, isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inTheWay.path)
            from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url)
        }
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        try blockLimits(of: onto)
        let hand = ProtectedByHand(.reads)
        let defaults = ToldDefaults { key in
            guard key == "fediqo.dummy.language" else { return }
            hand.turn(canary: .refused)
            try? FileManager.default.createDirectory(at: inTheWay, withIntermediateDirectories: true)
            try? Data().write(to: inTheWay.appendingPathComponent("held"))
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inTheWay.path)
        }
        let lists = ListFiles(directory: onto.directory, defaults: defaults, protected: .always)
        #expect(lists.timelines.write(Self.timelines) && lists.allowances.write(Self.allowances))
        defaults.set("en", forKey: "fediqo.dummy.language")
        defaults.told = true
        let packager = StorePackager(
            directory: onto.directory, file: onto.file, store: onto.store, media: onto.media, tokens: onto.tokens,
            credentials: onto.credentials, defaults: defaults, device: "a test", appVersion: "0.7.0",
            protected: hand.protected, freeSpace: { _ in .max }, rounds: 1000
        )
        await #expect(throws: PackageFault.unwound(steps: ["settings"])) {
            try await packager.readBack(url, key: Self.key, replacing: true) { _ in }
        }
        defaults.told = false
        #expect(packager.owesUndo && lists.allowances.read() == .data(Self.allowances), "the premise: the first list is back, and the step is owed for the second")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inTheWay.path)
        try FileManager.default.removeItem(at: inTheWay.appendingPathComponent("held"))
        hand.turn(canary: .reads)
        #expect(await packager.finishOwed())
        #expect(lists.timelines.read() == .data(Self.timelines) && lists.allowances.read() == .data(Self.allowances))
        #expect(try !named(onto.directory))
    }

    @Test("A run killed in the middle of a read back, with no lock at all, leaves the steps it had reached named: the next run says them, and puts the person's own lists back over what had landed")
    func killedMidway() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            from.remove(); onto.remove()
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: copy)
        }
        let theirs = Data(#"{"version":3,"timelines":[]}"#.utf8), allowed = Data(#"{"off":[],"own":[]}"#.utf8)
        #expect(from.lists.timelines.write(theirs) && from.lists.allowances.write(allowed))
        #expect(onto.lists.timelines.write(Self.timelines) && onto.lists.allowances.write(Self.allowances))
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        // The folder as a run killed there would leave it: at the second list's write, with
        // the first list's own aside and the package's in its place.
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let directory = onto.directory
        var packager = onto.packager()
        packager.lists = ListFiles(directory: onto.directory, defaults: onto.defaults, protected: .always, device: saying {
            guard asked.withLock({ $0 += 1; return $0 }) == 2 else { return }
            try? FileManager.default.copyItem(at: directory, to: copy)
        })
        try await packager.readBack(url, key: Self.key, replacing: true) { _ in }
        #expect(onto.lists.timelines.read() == .data(theirs) && onto.lists.allowances.read() == .data(allowed))
        #expect(try !named(onto.directory), "a read back that held leaves no name")
        let after = next(on: copy, of: onto)
        #expect(after.leftOwed() == ["index", "pictures", "secrets", "settings"])
        StorePackager.sweepLeftovers(directory: copy, media: nil, temporary: copy)
        let lists = ListFiles(directory: copy, defaults: onto.defaults, protected: .always)
        #expect(lists.timelines.read() == .data(Self.timelines) && lists.allowances.read() == .data(Self.allowances))
        #expect(try !names(copy).contains { $0.contains(ListFile.asideInfix) })
        // The index is put back from what the read back set aside (#360), and is said no more.
        #expect(after.leftOwed() == ["pictures", "secrets", "settings"], "kept to be said until it has been")
        after.toldLeftOwed()
        #expect(try !named(copy))
    }

    @Test("A run that ends once every step has held, before the steps' names went, leaves names the next run does not believe: nothing is said, the package's lists stay, and the names go")
    func endedOnceHeld() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            from.remove(); onto.remove()
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: copy)
        }
        let theirs = Data(#"{"version":3,"timelines":[]}"#.utf8)
        #expect(from.lists.timelines.write(theirs))
        #expect(onto.lists.timelines.write(Self.timelines) && onto.lists.allowances.write(Self.allowances))
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        let directory = onto.directory
        var packager = onto.packager()
        packager.witness = { point in
            guard point == .held else { return }
            try? FileManager.default.copyItem(at: directory, to: copy)
        }
        try await packager.readBack(url, key: Self.key, replacing: true) { _ in }
        #expect(try !named(onto.directory))
        try #require(StorePackager.owedNames(in: copy) == ["index", "limits", "pictures", "secrets", "settings"], "the premise: every step still named")
        let after = next(on: copy, of: onto)
        #expect(after.leftOwed().isEmpty, "a read back that held was said to have left parts not put back")
        StorePackager.sweepLeftovers(directory: copy, media: nil, temporary: copy)
        #expect(try !named(copy))
        let settled = ListFiles(directory: copy, defaults: onto.defaults, protected: .always)
        #expect(settled.timelines.read() == .data(theirs), "settled as though it had failed")
        #expect(settled.allowances.read() == .none, "a list the package did not carry came back after a read back that held")
        #expect(try !names(copy).contains { $0.contains(ListFile.asideInfix) })
        #expect(after.leftOwed().isEmpty)
    }

    @Test("Where the word that every step held cannot be said, the steps' names go before anything put aside does: a run that ends there leaves nothing named, and the package's lists stay")
    func heldAndNotSaid() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            from.remove(); onto.remove()
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: copy)
        }
        let theirs = Data(#"{"version":3,"timelines":[]}"#.utf8)
        #expect(from.lists.timelines.write(theirs))
        #expect(onto.lists.timelines.write(Self.timelines))
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        let directory = onto.directory
        var packager = onto.packager()
        packager.witness = { point in
            let manager = FileManager.default
            switch point {
            case .staged:
                // Something stands where the commit's name is to be moved: the move refuses.
                for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(StorePackager.Flight.prefix) {
                    let inTheWay = StorePackager.Flight.heldPrefix + String(name.dropFirst(StorePackager.Flight.prefix.count))
                    try? Data().write(to: directory.appendingPathComponent(inTheWay))
                }
            case .held:
                try? manager.copyItem(at: directory, to: copy)
            default:
                break
            }
        }
        try await packager.readBack(url, key: Self.key, replacing: true) { _ in }
        let left = try names(copy)
        try #require(left.contains { $0.hasPrefix(StorePackager.Flight.prefix) } && left.contains { $0.contains(ListFile.asideInfix) },
                     "the premise: the word was not said, and nothing put aside had gone")
        #expect(StorePackager.owedNames(in: copy).isEmpty, "still named when what was put aside began to go")
        // Nothing that could be had on disk says this one held: only that nothing failed.
        try FileManager.default.removeItem(at: copy.appendingPathComponent(try #require(left.first { $0.hasPrefix(StorePackager.Flight.heldPrefix) })))
        let after = next(on: copy, of: onto)
        #expect(after.leftOwed().isEmpty)
        StorePackager.sweepLeftovers(directory: copy, media: nil, temporary: copy)
        #expect(ListFiles(directory: copy, defaults: onto.defaults, protected: .always).timelines.read() == .data(theirs))
        #expect(try !named(copy))
        #expect(StorePackager.owedNames(in: onto.directory).isEmpty)
    }

    @Test("An undo of the lists refused by something that is no lock is said at once and not again by that run — and stays named while a list is aside, so the next launch puts the person's own list back and says it once more")
    func refusedByNoLock() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        let inTheWay = onto.directory.appendingPathComponent(ListFile.timelinesName, isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inTheWay.path)
            from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url)
        }
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        try blockLimits(of: onto)
        let defaults = ToldDefaults { key in
            guard key == "fediqo.dummy.language" else { return }
            try? FileManager.default.createDirectory(at: inTheWay, withIntermediateDirectories: true)
            try? Data().write(to: inTheWay.appendingPathComponent("held"))
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inTheWay.path)
        }
        let lists = ListFiles(directory: onto.directory, defaults: defaults, protected: .always)
        #expect(lists.timelines.write(Self.timelines) && lists.allowances.write(Self.allowances))
        defaults.set("en", forKey: "fediqo.dummy.language")
        defaults.told = true
        let packager = StorePackager(
            directory: onto.directory, file: onto.file, store: onto.store, media: onto.media, tokens: onto.tokens,
            credentials: onto.credentials, defaults: defaults, device: "a test", appVersion: "0.7.0",
            protected: .always, freeSpace: { _ in .max }, rounds: 1000
        )
        await #expect(throws: PackageFault.unwound(steps: ["settings"])) {
            try await packager.readBack(url, key: Self.key, replacing: true) { _ in }
        }
        defaults.told = false
        #expect(!packager.owesUndo && packager.leftOwed().isEmpty, "owed, or said twice by the run that said it")
        #expect(StorePackager.owedNames(in: onto.directory) == ["settings"], "nothing left to say that a list of the person's own is aside")
        // **Asked again in the same run**, and refused again — this time with everything of
        // its own put back. The first one's list is still aside, so the settings stay named:
        // taken away, the next launch would find nothing said and delete that list.
        await #expect(throws: (any Error).self) {
            try await packager.readBack(url, key: Self.key, replacing: true) { _ in }
        }
        #expect(StorePackager.owedNames(in: onto.directory) == ["settings"], "the second read back took the first one's name")
        #expect(!packager.owesUndo && packager.leftOwed().isEmpty)
        // The next launch, with what stood in the way gone: what landed in the list's place
        // goes, the person's own list is back, and what was not put back is said once more.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inTheWay.path)
        try FileManager.default.removeItem(at: inTheWay.appendingPathComponent("held"))
        StorePackager.sweepLeftovers(directory: onto.directory, media: nil, temporary: onto.directory.appendingPathComponent("no-such-tmp"))
        #expect(lists.timelines.read() == .data(Self.timelines) && lists.allowances.read() == .data(Self.allowances))
        let after = next(on: onto.directory, of: onto)
        #expect(after.leftOwed() == ["settings"])
        after.toldLeftOwed()
        #expect(try !named(onto.directory))
    }

    @Test("Another copy of the app launching while a read back has a list aside settles nothing of it: the lists are still there to put back when a later step refuses, and the device is as it was")
    func aLaunchMidway() async throws {
        let from = try await Device(sources: [PackagerFixture.mastodon])
        let onto = try await Device()
        let url = package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        #expect(from.lists.timelines.write(Data(#"{"version":3,"timelines":[]}"#.utf8)) && from.lists.allowances.write(Data(#"{"off":[],"own":[]}"#.utf8)))
        #expect(onto.lists.timelines.write(Self.timelines) && onto.lists.allowances.write(Self.allowances))
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        try blockLimits(of: onto)
        // The other copy's launch, at the second list's write: one list of the person's own
        // aside with the package's in its place, the other aside with nothing in its place.
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let directory = onto.directory
        var packager = onto.packager()
        packager.lists = ListFiles(directory: onto.directory, defaults: onto.defaults, protected: .always, device: saying {
            guard asked.withLock({ $0 += 1; return $0 }) == 2 else { return }
            StorePackager.sweepLeftovers(directory: directory, media: nil, temporary: directory.appendingPathComponent("no-such-tmp"))
        })
        do {
            try await packager.readBack(url, key: Self.key, replacing: true) { _ in }
            Issue.record("the read back held")
        } catch PackageFault.unwound(let steps) {
            Issue.record("not put back: \(steps)")
        } catch {}
        #expect(asked.withLock { $0 } >= 2, "the premise: the launch happened midway")
        #expect(!packager.owesUndo)
        #expect(onto.lists.timelines.read() == .data(Self.timelines))
        #expect(onto.lists.allowances.read() == .data(Self.allowances))
        #expect(try !names(onto.directory).contains { $0.contains(ListFile.asideInfix) })
        #expect(try !named(onto.directory))
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
