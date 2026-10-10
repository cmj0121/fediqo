import FediqoCore
import Foundation
import os
import Testing
@testable import FediqoPersistence

/// #344: what may be reached beyond a source, and the timelines a person wrote, are each one
/// file beside the index — moved there once from the preference key earlier builds kept them
/// under, and never read as "none", or written over, where they could not be read.
@Suite("The person's own lists are files beside the store")
struct ListFileTests {
    private static let kept = Data(#"{"version":3,"timelines":[]}"#.utf8)
    private static let other = Data(#"{"off":["pictures"],"own":[]}"#.utf8)

    /// One device's folder and preferences.
    private final class Place {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "fediqo.test.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: directory.appendingPathComponent(ListFile.timelinesName).path)
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }

        func list(_ protected: ProtectedData = .always, device: Guarded.Device = .this) -> ListFile {
            ListFiles(directory: directory, defaults: defaults, protected: protected, device: device).timelines
        }

        var onDisk: Data? { try? Data(contentsOf: directory.appendingPathComponent(ListFile.timelinesName)) }
        var underKey: Data? { defaults.data(forKey: "fediqo.timelines") }
        var names: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() }
    }

    /// A folder that takes no file at the class, on a volume that takes the class.
    private static let refusing = Guarded.Device(
        asks: .complete, held: { _ in nil }, canaryTook: { true }, count: {},
        asking: { throw CocoaError(.fileWriteNoPermission) }
    )

    // MARK: - The move

    @Test("Moved once: the key read, the file written and read back, and only then the key gone")
    func moved() throws {
        let place = try Place()
        place.defaults.set(Self.kept, forKey: "fediqo.timelines")
        let canary = CanaryByHand(.reads)
        #expect(place.list(canary.protected).read() == .data(Self.kept))
        #expect(canary.looks == 2, "the key is read between two looks at the canary")
        #expect(place.onDisk == Self.kept && place.underKey == nil)
        #expect(place.names == [ListFile.timelinesName])
        // And read from the file from then on, with nothing asked of the canary.
        #expect(place.list(canary.protected).read() == .data(Self.kept))
        #expect(canary.looks == 2)
    }

    @Test("Cut short before the file was written, the key stands and is what is read; the next launch moves it")
    func cutShortBeforeTheFile() throws {
        let place = try Place()
        place.defaults.set(Self.kept, forKey: "fediqo.timelines")
        #expect(place.list(device: Self.refusing).read() == .data(Self.kept))
        #expect(place.onDisk == nil && place.underKey == Self.kept)
        #expect(place.list().read() == .data(Self.kept))
        #expect(place.onDisk == Self.kept && place.underKey == nil)
    }

    @Test("A write that returns and does not hold what was written leaves the key: it goes only once the file has been read back as what was written")
    func notReadBackAsWritten() throws {
        let place = try Place()
        place.defaults.set(Self.kept, forKey: "fediqo.timelines")
        var device = Guarded.Device.this
        device.landing = { _ in Data("something else".utf8) }
        #expect(place.list(device: device).read() == .data(Self.kept), "what the key holds is still the list")
        #expect(place.underKey == Self.kept, "the only good copy went")
        // The same of an ordinary write: not said to be written.
        #expect(!place.list(device: device).write(Self.other))
        #expect(place.underKey == Self.kept)
    }

    @Test("Cut short before the key was removed — or a build from before this one having written its key since — the file is the list, and the key is removed and never moved over it")
    func theFileWins() throws {
        let place = try Place()
        try Self.kept.write(to: place.directory.appendingPathComponent(ListFile.timelinesName))
        place.defaults.set(Self.other, forKey: "fediqo.timelines")
        #expect(place.list().read() == .data(Self.kept))
        #expect(place.onDisk == Self.kept && place.underKey == nil)
    }

    @Test("Behind a canary that does not read — refusing, closed, gone between the two looks, or none at all — nothing is moved: a key that is there is read where it is, and one that is not is not taken for none",
          arguments: [[ProtectedData.Canary.refused], [.closed], [.reads, .refused], [.none]])
    func notBehindALock(answers: [ProtectedData.Canary]) throws {
        let place = try Place()
        func canary() -> ProtectedData {
            let looks = OSAllocatedUnfairLock(initialState: 0)
            return ProtectedData(
                flag: { true },
                canary: {
                    looks.withLock { look in
                        defer { look += 1 }
                        return answers[min(look, answers.count - 1)]
                    }
                },
                remade: { .refused }, unlockedForSomebody: { false }, changes: { AsyncStream { $0.finish() } }
            )
        }
        // No key: empty preferences are not an empty list, and no first file is made of one.
        #expect(place.list(canary()).read() == .notKnown)
        #expect(!place.list(canary()).write(Self.other))
        #expect(place.names.isEmpty)
        // A key: what it holds is what is kept, and it stays where it is.
        place.defaults.set(Self.kept, forKey: "fediqo.timelines")
        #expect(place.list(canary()).read() == .data(Self.kept))
        #expect(place.names.isEmpty && place.underKey == Self.kept)
    }

    // MARK: - Nothing kept

    @Test("With no key and no file nothing is kept, and no file is made of nothing: each launch asks the key again, until a first real write")
    func absent() throws {
        let place = try Place()
        #expect(place.list().read() == .none)
        #expect(place.list().read() == .none)
        #expect(place.names.isEmpty, "a file made here would shadow a key that only read empty")
        // A key that appears meanwhile — it had only read empty — is still found, and moved.
        place.defaults.set(Self.kept, forKey: "fediqo.timelines")
        #expect(place.list().read() == .data(Self.kept))
        try FileManager.default.removeItem(at: place.directory.appendingPathComponent(ListFile.timelinesName))
        #expect(place.list().read() == .none)
        // The first real write makes the file.
        #expect(place.list().write(Self.other))
        #expect(place.onDisk == Self.other && place.list().read() == .data(Self.other))
    }

    // MARK: - Not read

    @Test("A file that is there and will not be read is not none, is not written over, and its key is left alone")
    func refusedIsNotNone() throws {
        let place = try Place()
        let url = place.directory.appendingPathComponent(ListFile.timelinesName)
        try Self.kept.write(to: url)
        place.defaults.set(Self.other, forKey: "fediqo.timelines")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(place.list().read() == .unread)
        #expect(!place.list().write(Self.other))
        #expect(place.underKey == Self.other, "nothing is known, so nothing is removed")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(place.onDisk == Self.kept)
    }

    @Test("Something under the key that is not what a build wrote is not none, and is neither moved nor written over")
    func anotherTypeUnderTheKey() throws {
        let place = try Place()
        place.defaults.set("not a list", forKey: "fediqo.timelines")
        #expect(place.list().read() == .unread)
        #expect(place.names.isEmpty && place.defaults.string(forKey: "fediqo.timelines") == "not a list")
    }

    @Test("Where the list's owner always read such a thing as nothing kept, it is none — but only between two canary reads, and the key stands until a first write")
    func anotherTypeWhereItWasAlwaysNone() throws {
        let place = try Place()
        place.defaults.set("not a list", forKey: "fediqo.allowances")
        func allowances(_ protected: ProtectedData = .always) -> ListFile {
            ListFiles(directory: place.directory, defaults: place.defaults, protected: protected).allowances
        }
        #expect(allowances(CanaryByHand(.none).protected).read() == .unread)
        #expect(allowances(CanaryByHand(.reads, .refused).protected).read() == .unread)
        #expect(allowances().read() == .none)
        #expect(place.names.isEmpty && place.defaults.string(forKey: "fediqo.allowances") == "not a list")
        #expect(allowances().write(Self.other))
        #expect(place.defaults.object(forKey: "fediqo.allowances") == nil && allowances().read() == .data(Self.other))
    }

    @Test("A write that the folder refuses says so, and leaves what was kept")
    func aWriteRefused() throws {
        let place = try Place()
        #expect(place.list().write(Self.kept))
        #expect(!place.list(device: Self.refusing).write(Self.other))
        #expect(place.onDisk == Self.kept)
    }

    @Test("Made none — as a read back makes a list its package does not carry — the file goes, and a key left with no file goes too: nothing is there for a launch to move back in")
    func madeNone() throws {
        let place = try Place()
        #expect(place.list().write(Self.kept))
        try place.list().lay(nil)
        #expect(place.names.isEmpty && place.list().read() == .none)
        // A key that was never moved: no canary read while it has been there.
        place.defaults.set(Self.other, forKey: "fediqo.timelines")
        try place.list(CanaryByHand(.none).protected).lay(nil)
        #expect(place.underKey == nil && place.list().read() == .none)
    }

    // MARK: - While a read back replaces it

    @Test("Moved aside and put back by renames alone: on a folder that takes no new file, what was there is there again, whatever was laid in its place")
    func asideAndBack() throws {
        let place = try Place()
        #expect(place.list().write(Self.kept))
        let aside = try #require(try place.list().putAside())
        #expect(place.onDisk == nil && place.list().read() == .none, "what is aside is not read as the list")
        try place.list().lay(Self.other)
        try place.list(device: Self.refusing).putBack(aside, held: Self.kept)
        #expect(place.onDisk == Self.kept && place.names == [ListFile.timelinesName])
        // Done twice it is done once.
        try place.list(device: Self.refusing).putBack(aside, held: Self.kept)
        #expect(place.onDisk == Self.kept)
        // With nothing to move aside there is nothing aside, and putting back lays it down.
        try place.list().lay(nil)
        #expect(try place.list().putAside() == nil)
        try place.list().putBack(nil, held: Self.kept)
        #expect(place.onDisk == Self.kept)
    }

    @Test("A list left aside by a read back that never finished does not outlive a launch: put back where its list has no file, gone where the package's landed — and only where the canary reads")
    func aStrayAside() throws {
        let place = try Place()
        let lists = ListFiles(directory: place.directory, defaults: place.defaults, protected: .always)
        #expect(lists.timelines.write(Self.kept) && lists.allowances.write(Self.other))
        _ = try #require(try lists.timelines.putAside())
        _ = try #require(try lists.allowances.putAside())
        try lists.allowances.lay(Self.kept)
        #expect(place.names.count == 3)
        StorePackager.sweepLeftovers(directory: place.directory, media: nil, temporary: place.directory, protected: CanaryByHand(.refused).protected)
        #expect(place.names.count == 3, "settled behind a lock")
        StorePackager.sweepLeftovers(directory: place.directory, media: nil, temporary: place.directory)
        #expect(place.names == [ListFile.allowancesName, ListFile.timelinesName])
        #expect(lists.timelines.read() == .data(Self.kept), "the person's own, put back")
        #expect(lists.allowances.read() == .data(Self.kept), "the package's, which had landed")
    }

    @Test("Where the read back that left it aside is known to have failed — its undo of the settings owed and never done — the list aside is the person's own and is put back over what landed")
    func aStrayAsideOfAFailedReadBack() throws {
        let place = try Place()
        let lists = ListFiles(directory: place.directory, defaults: place.defaults, protected: .always)
        #expect(lists.allowances.write(Self.other))
        _ = try #require(try lists.allowances.putAside())
        try lists.allowances.lay(Self.kept)
        try Data().write(to: place.directory.appendingPathComponent(StorePackager.owedPrefix + "settings"))
        StorePackager.sweepLeftovers(directory: place.directory, media: nil, temporary: place.directory)
        #expect(lists.allowances.read() == .data(Self.other), "the person's own list went, and the package's stayed")
        #expect(place.names == [StorePackager.owedPrefix + "settings", ListFile.allowancesName].sorted())
    }

    @Test("While a read back's anchor is in the folder — one may be in flight in another copy of the app — a list aside is left alone; with the anchor gone, it is settled")
    func notUnderAReadBackInFlight() throws {
        let place = try Place()
        let lists = ListFiles(directory: place.directory, defaults: place.defaults, protected: .always)
        #expect(lists.timelines.write(Self.kept))
        let aside = try #require(try lists.timelines.putAside())
        let flight = place.directory.appendingPathComponent("incoming-aside-\(UUID().uuidString)", isDirectory: true)
        try StorePackager.begin(flight, as: .landed)
        try Data("an index".utf8).write(to: flight.appendingPathComponent("index.sqlite"))
        try Data("the package's".utf8).write(to: place.directory.appendingPathComponent("index.sqlite"))
        StorePackager.sweepLeftovers(directory: place.directory, media: nil, temporary: place.directory)
        #expect(FileManager.default.fileExists(atPath: aside.path) && place.onDisk == nil)
        try #require(FileManager.default.fileExists(atPath: flight.path), "the premise: the anchor is still there")
        try FileManager.default.removeItem(at: flight)
        StorePackager.sweepLeftovers(directory: place.directory, media: nil, temporary: place.directory)
        #expect(place.onDisk == Self.kept && !FileManager.default.fileExists(atPath: aside.path))
    }

    // MARK: - Beside the store, and no part of it

    @Test("The lists are not put aside with a damaged index, not expired with one, and not swept at a launch")
    func notTheStores() throws {
        let place = try Place()
        let lists = ListFiles(directory: place.directory, defaults: place.defaults, protected: .always)
        #expect(lists.allowances.write(Self.other) && lists.timelines.write(Self.kept))
        try Data(repeating: 0x5A, count: 8192).write(to: place.directory.appendingPathComponent("index.sqlite"))
        let then = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: then], ofItemAtPath: place.directory.appendingPathComponent("index.sqlite").path)
        let opened = StoreFile.open(at: place.directory, now: then)
        #expect(opened.setAside != nil)
        try opened.file?.db.close()
        StorePackager.sweepLeftovers(directory: place.directory, media: nil, temporary: place.directory)
        // And a launch long after, which removes the store put aside.
        try StoreFile.open(at: place.directory, now: then.addingTimeInterval(400 * 86_400)).file?.db.close()
        #expect(!place.names.contains { $0.hasPrefix("index-unreadable-") })
        #expect(lists.allowances.read() == .data(Self.other) && lists.timelines.read() == .data(Self.kept))
        // In a run with no store at all they are read the same: nothing of them is the index's.
        try FileManager.default.removeItem(at: place.directory.appendingPathComponent("index.sqlite"))
        #expect(lists.timelines.read() == .data(Self.kept))
    }
}
