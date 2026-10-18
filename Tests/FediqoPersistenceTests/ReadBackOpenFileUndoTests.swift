@testable import FediqoCore
import Foundation
import GRDB
import os
import Testing
@testable import FediqoPersistence

/// #360, K8: what may go wrong between a read back's copy into an open file and its undo — a
/// read of the file meanwhile, a lock, an undo refused for good, a launch after — and the room
/// it is asked for first.
@Suite("A read back into an open file, undone")
struct ReadBackOpenFileUndoTests {
    typealias Device = PackagerFixture.PackagerDevice
    typealias Open = ReadBackOpenFileTests
    static let mastodon = PackagerFixture.mastodon
    static let key = PackageKey.password("password")

    static func old(_ n: Int) -> Note { Open.note("old-\(n)", body: "an old post \(n)") }
    static func new(_ n: Int) -> Note { Open.note("new-\(n)", body: "a new post \(n)") }

    /// A device holding six old posts, and a package of three new ones and one of the old.
    static func pair() async throws -> (from: Device, onto: Device, url: URL) {
        let from = try await Device(sources: [mastodon], notes: [old(1)] + (1...3).map(new))
        let onto = try await Device(sources: [mastodon], notes: (1...6).map(old))
        let url = PackagerFixture.package()
        try await from.packager().takeAway(to: url, key: key, pictures: false) { _ in }
        return (from, onto, url)
    }

    static func blockLimits(of device: Device) throws {
        let blocking = device.directory.appendingPathComponent(LimitAccountFile.name, isDirectory: true)
        try FileManager.default.createDirectory(at: blocking, withIntermediateDirectories: true)
        try Data().write(to: blocking.appendingPathComponent("in the way"))
    }

    @Test("Rows read by key between the copy in and the undo are passed through and not held: the file put back keeps every row it had, and gains none of the package's")
    func readsInTheWindow() async throws {
        let (from, onto, url) = try await Self.pair()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        let run = try await Open.run(on: onto)
        let before = try Open.rows(run.file, "note")
        // The package, staged as a read back stages it.
        let (package, _) = try await Open.stage(url, in: onto.root.appendingPathComponent("staging", isDirectory: true))
        try package.dropDerivedObjects()
        package.scrub()
        let aside = onto.root.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try await run.file.snapshot(into: aside)
        let hosts = try run.file.sourceHosts()
        await run.store.mayBePutBack(true)
        try await run.file.copy(from: package.db)
        // Meanwhile: one the package lacks, one it alone holds.
        let read = await run.store.notes([Self.old(3).key, Self.new(1).key])
        #expect(read[Self.new(1).key] != nil, "passed through: the file holds the package now")
        #expect(read[Self.old(3).key] == nil)
        #expect(await run.store.pooled == 0, "nothing laid in")
        #expect(await run.store.lookedCount == 0, "nothing answered for")
        // The undo, then the save after it.
        await run.store.restoring()
        try await run.file.putBack(from: aside)
        await run.store.oweEverything(hosts: hosts)
        try await run.saver.save()
        #expect(try Open.rows(run.file, "note") == before)
    }

    @Test("An undo a lock held: rows read meanwhile are passed through, and once it is done the file is as it was")
    func lockOwed() async throws {
        let (from, onto, url) = try await Self.pair()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        let run = try await Open.run(on: onto)
        let before = try Open.rows(run.file, "note")
        let locked = OSAllocatedUnfairLock(initialState: false)
        let asideFile = OSAllocatedUnfairLock<String?>(initialState: nil)
        let protected = ProtectedData(
            flag: { true }, canary: { locked.withLock { $0 } ? .refused : .reads },
            remade: { .reads }, unlockedForSomebody: { true }, changes: { AsyncStream { $0.finish() } }
        )
        var packager = StorePackager(
            directory: onto.directory, file: run.file, store: run.store, media: onto.media, tokens: onto.tokens,
            credentials: onto.credentials, defaults: onto.defaults, device: "a test", appVersion: "0.7.0",
            saver: run.saver, protected: protected, freeSpace: { _ in .max }, rounds: 1000
        )
        // The device locks once the file is set aside: the aside will not be opened.
        packager.setAside = { aside in
            let path = aside.appendingPathComponent(StoreFile.indexName).path
            asideFile.withLock { $0 = path }
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
            locked.withLock { $0 = true }
        }
        try Self.blockLimits(of: onto)
        await #expect(throws: PackageFault.unwound(steps: ["index"])) {
            try await packager.readBack(url, key: Self.key, replacing: true) { _ in }
        }
        #expect(packager.owesUndo)
        #expect(await run.store.holdsForPutBack)
        let read = await run.store.notes([Self.old(3).key, Self.new(1).key])
        #expect(read[Self.new(1).key] != nil && read[Self.old(3).key] == nil)
        #expect(await run.store.pooled == 0)
        try await run.saver.save()
        // Unlocked: the undo is done, and the store saved again over it.
        locked.withLock { $0 = false }
        if let path = asideFile.withLock({ $0 }) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        #expect(await packager.finishOwed())
        #expect(try Open.rows(run.file, "note") == before)
        let left = try FileManager.default.contentsOfDirectory(atPath: onto.directory.path)
        #expect(!left.contains { $0.hasPrefix(StorePackager.undoAsidePrefix) })
    }

    @Test("An undo of the index refused for good, by no lock, keeps the aside and the step's name, and the next launch puts the store back from it")
    func refusedForGoodThenLaunch() async throws {
        let (from, onto, url) = try await Self.pair()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        let sweep = {
            StorePackager.sweepLeftovers(directory: onto.directory, media: nil, temporary: onto.directory.appendingPathComponent("no-such-tmp"))
        }
        let asideFile = OSAllocatedUnfairLock<String?>(initialState: nil)
        let before: [[DatabaseValue]]
        // The run, ended at the end of this block.
        do {
            let run = try await Open.run(on: onto)
            before = try Open.rows(run.file, "note")
            var packager = run.packager
            packager.setAside = { aside in
                let path = aside.appendingPathComponent(StoreFile.indexName).path
                asideFile.withLock { $0 = path }
                try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
            }
            try Self.blockLimits(of: onto)
            await #expect(throws: PackageFault.unwound(steps: ["index"])) {
                try await packager.readBack(url, key: Self.key, replacing: true) { _ in }
            }
            #expect(!packager.owesUndo)
            let path = try #require(asideFile.withLock { $0 })
            #expect(FileManager.default.fileExists(atPath: path), "the only copy of the store is never deleted")
            #expect(StorePackager.owedNames(in: onto.directory).contains("index"))
            #expect(try run.file.rowCount() == 4, "the premise: the package's store is in place")
            // Another copy of the app launching while this run lives: the commit is held, and
            // nothing of it is settled under this run.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            #expect(StorePackager.Flight.standing(in: onto.directory).live)
            sweep()
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(try run.file.rowCount() == 4)
            try run.file.db.close()
        }
        // This run's next launch.
        #expect(!StorePackager.Flight.standing(in: onto.directory).live, "the premise: the run has ended")
        sweep()
        let reopened = try StoreFile(at: onto.directory)
        #expect(try Open.rows(reopened, "note") == before)
        #expect(!StorePackager.owedNames(in: onto.directory).contains("index"), "put back, and so said no more")
        let left = try FileManager.default.contentsOfDirectory(atPath: onto.directory.path)
        #expect(!left.contains { $0.hasPrefix(StorePackager.undoAsidePrefix) })
        #expect(try Open.files(in: onto.root, holding: "a new post 2").isEmpty)
    }

    @Test("Days let go while a read back may put the file back wait until it no longer may: a post the package and the store put back share is still there after the undo")
    func spanWaitsForTheUndo() async throws {
        // The package holds `old-1` as posted a day later than the store does.
        let later = PackagerFixture.origin.addingTimeInterval(86_400)
        func dated(_ note: Note) -> Note {
            Note(id: note.id, source: note.source, author: note.author, handle: note.handle, body: note.body, postedAt: later, categories: note.categories)
        }
        let from = try await Device(sources: [Self.mastodon], notes: [dated(Self.old(1))] + (1...3).map { dated(Self.new($0)) })
        let onto = try await Device(sources: [Self.mastodon], notes: (1...6).map(Self.old))
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        let run = try await Open.run(on: onto)
        let before = try Open.rows(run.file, "note")
        let (package, _) = try await Open.stage(url, in: onto.root.appendingPathComponent("staging", isDirectory: true))
        try package.dropDerivedObjects()
        package.scrub()
        let aside = onto.root.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try await run.file.snapshot(into: aside)
        let hosts = try run.file.sourceHosts()
        await run.store.mayBePutBack(true)
        try await run.file.copy(from: package.db)
        // The package's day let go: `old-1` is in it there, and not in the store put back.
        let day = later.addingTimeInterval(-60)..<later.addingTimeInterval(60)
        let store = run.store
        let letting = Task { await store.letGo(span: day) }
        while await store.waitingForUndo == 0 { await Task.yield() }
        #expect(await store.lookedCount == 0, "waiting, and nothing answered for")
        // The undo.
        await store.restoring()
        try await run.file.putBack(from: aside)
        await store.oweEverything(hosts: hosts)
        // Then it goes on, of the store put back: none of its posts is of that day.
        #expect(await letting.value == 0)
        try await run.saver.save()
        #expect(try Open.rows(run.file, "note") == before, "the post both hold is still there")
    }

    @Test("A launch leaves the aside of a commit a live run holds, puts back one whose commit ended cut short with its index named, and removes one whose commit said every step held")
    func launchByItsOwnCommit() async throws {
        let device = try await Device(sources: [Self.mastodon], notes: [Self.old(1)])
        defer { device.remove() }
        let file = try #require(device.file)
        let sweep = { StorePackager.sweepLeftovers(directory: device.directory, media: nil, temporary: device.directory.appendingPathComponent("no-such-tmp")) }
        func aside(for id: String) async throws -> URL {
            let folder = device.directory.appendingPathComponent(StorePackager.undoAsidePrefix + id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await file.snapshot(into: folder)
            return folder
        }
        // Held by a run that lives: left.
        let live = try StorePackager.Flight(in: device.directory)
        let held = try await aside(for: live.id)
        sweep()
        #expect(FileManager.default.fileExists(atPath: held.path))
        live.end()
        // Every step held, said: removed, nothing put back.
        let said = try StorePackager.Flight(in: device.directory)
        let saidAside = try await aside(for: said.id)
        said.sayHeld()
        said.end(keepingName: true)
        try await file.save(RowChanges(upserts: [Self.new(1)]))
        sweep()
        #expect(!FileManager.default.fileExists(atPath: saidAside.path))
        #expect(try file.rowCount() == 2)
        // Cut short with the index named: put back.
        let cut = try StorePackager.Flight(in: device.directory)
        let cutAside = try await aside(for: cut.id)
        try Data().write(to: device.directory.appendingPathComponent(StorePackager.owedPrefix + "index"))
        cut.end(keepingName: true)
        try await file.save(RowChanges(upserts: [Self.new(2)]))
        try file.db.close()
        sweep()
        #expect(!FileManager.default.fileExists(atPath: cutAside.path))
        #expect(try StoreFile(at: device.directory).rowCount() == 2, "the store as it was set aside")
        #expect(StorePackager.owedNames(in: device.directory).isEmpty)
    }

    @Test("Room is asked for the staging, the file set aside and its journal: a package that fits twice over is refused over a file larger than it")
    func roomForTheAside() async throws {
        let from = try await Device(sources: [Self.mastodon], notes: [Self.new(1)])
        let onto = try await Device(sources: [Self.mastodon], notes: (1...400).map { Open.note("old-\($0)", body: String(repeating: "a long post ", count: 40)) })
        let url = PackagerFixture.package()
        defer { from.remove(); onto.remove(); try? FileManager.default.removeItem(at: url) }
        try await from.packager().takeAway(to: url, key: Self.key, pictures: false) { _ in }
        let package = try PackageReader(at: url).prelude.bytes
        let held = try #require(onto.file).bytesOnDisk()
        #expect(held > package, "the premise")
        let needed = package + 2 * held
        let free = package * 2 + held
        #expect(free < needed)
        await #expect(throws: PackageFault.noRoom(needed: needed, free: free)) {
            try await onto.packager(free: free).readBack(url, key: Self.key, replacing: true) { _ in }
        }
    }
}
