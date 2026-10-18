import Foundation
import os
import Testing
@testable import FediqoCore

/// A folder that is **not** at the class, to make things in: whatever is made there is at the
/// class because it was asked for, and not because the folder handed it down. And a device
/// turned by hand, which keeps what each file read as the first time it was asked.
struct GuardedGround {
    let folder: URL
    static let lesser = FileProtectionType.completeUntilFirstUserAuthentication

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: Self.lesser]
        )
        try #require(Self.held(folder) == Self.lesser, "the ground itself is not at the class")
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    /// The class `url` is at on disk.
    static func held(_ url: URL) -> FileProtectionType? { Guarded.Device.real.heldNow(url) }

    /// The platform's class: what everything is asked for at.
    static let asked = Guarded.platformClass

    /// Whether the platform's class can be had on this machine right now, by doing it: a
    /// folder made at it, a file written in it, closed, opened again and read. A Mac whose
    /// screen is locked opens no protected file again, and the suites that hold the class
    /// to the disk are then **skipped, and said to be** — never passed.
    static let works: Bool = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("probe")
        do {
            try Guarded.makeFolder(folder, excludedFromBackup: false, on: .real)
            try Guarded.write(Data("probe".utf8), to: file, atomic: false, on: .real)
            return try Data(contentsOf: file) == Data("probe".utf8) && held(file) == asked && held(folder) == asked
        } catch {
            return false
        }
    }()

    /// A plain file at the lesser class, as a build before this one made every file.
    func plain(_ name: String, _ words: String = "kept") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try #require(FileManager.default.createFile(
            atPath: url.path, contents: Data(words.utf8), attributes: [.protectionKey: Self.lesser]
        ))
        return url
    }

    /// What a device saw, and how many times it counted.
    final class Seen: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (first: [String: FileProtectionType?](), counted: 0))
        func note(_ url: URL, _ held: FileProtectionType?) {
            state.withLock { if $0.first[url.lastPathComponent] == nil { $0.first[url.lastPathComponent] = .some(held) } }
        }
        func count() { state.withLock { $0.counted += 1 } }
        /// The class `name` was at the first time anything asked — before it could be brought.
        func first(_ name: String) -> FileProtectionType? { state.withLock { $0.first[name] ?? nil } }
        var counted: Int { state.withLock { $0.counted } }
    }

    /// A device that reads the disk truly, or — `refusing` — reads every file named so as never
    /// having taken the class.
    static func device(
        simulated: Bool = false, phone: Bool = false, canaryTook: Bool = true, seen: Seen = Seen(),
        refusing: @escaping @Sendable (String) -> Bool = { _ in false },
        asking: @escaping @Sendable () throws -> Void = {}
    ) -> Guarded.Device {
        Guarded.Device(
            asks: asked, simulated: simulated, phone: phone,
            held: { url in
                let held = refusing(url.lastPathComponent) ? lesser : Self.held(url)
                seen.note(url, held)
                return held
            },
            canaryTook: { canaryTook }, count: { seen.count() }, asking: asking
        )
    }
}

/// #344: everything this app writes is made with the platform's class, through one place.
///
/// **Held to the disk, with the tests' switch off** (`Device.real`), and so run only where the
/// class can be had: see `GuardedGround.works`.
@Suite("What is made is made at the class", .enabled(if: GuardedGround.works, "the platform's class cannot be had here now: a locked screen"))
struct GuardedTests {
    private struct NoAsking: Error {}

    @Test("A folder is made at the class, parents and all, and one already there is brought to it")
    func folder() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let seen = GuardedGround.Seen()
        let deep = ground.folder.appendingPathComponent("a/b", isDirectory: true)
        try Guarded.makeFolder(deep, excludedFromBackup: false, on: GuardedGround.device(seen: seen))
        #expect(seen.first("b") == GuardedGround.asked, "made with the class, not classed afterwards")
        #expect(GuardedGround.held(ground.folder.appendingPathComponent("a")) == GuardedGround.asked)
        #expect(try deep.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup != true)

        let old = ground.folder.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(
            at: old, withIntermediateDirectories: false, attributes: [.protectionKey: GuardedGround.lesser]
        )
        try Guarded.makeFolder(old, excludedFromBackup: true, on: .real)
        #expect(GuardedGround.held(old) == GuardedGround.asked)
        #expect(try old.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test("A write is at the class from its first byte, whole-or-nothing or not", arguments: [true, false])
    func write(atomic: Bool) throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let seen = GuardedGround.Seen()
        let url = ground.folder.appendingPathComponent("words")
        try Guarded.write(Data("held".utf8), to: url, atomic: atomic, on: GuardedGround.device(seen: seen))
        #expect(seen.first("words") == GuardedGround.asked, "made with the class, not classed afterwards")
        #expect(try Data(contentsOf: url) == Data("held".utf8))
        // Over what an earlier build left at a lesser class: the new words, at the class.
        let old = try ground.plain("old")
        try Guarded.write(Data("new".utf8), to: old, atomic: atomic, on: .real)
        #expect(GuardedGround.held(old) == GuardedGround.asked)
        #expect(try Data(contentsOf: old) == Data("new".utf8))
    }

    @Test("An empty file is made at the class in place of what was there, and opened again keeps what it holds")
    func files() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let seen = GuardedGround.Seen()
        let device = GuardedGround.device(seen: seen)
        let url = ground.folder.appendingPathComponent("package")
        let handle = try Guarded.makeFile(at: url, on: device)
        #expect(seen.first("package") == GuardedGround.asked, "made with the class, not classed afterwards")
        try handle.write(contentsOf: Data("one".utf8))
        try handle.close()

        let again = try Guarded.reopen(url, on: device)
        try again.seekToEnd()
        try again.write(contentsOf: Data("two".utf8))
        try again.close()
        #expect(try Data(contentsOf: url) == Data("onetwo".utf8))

        let emptied = try Guarded.makeFile(at: url, on: device)
        try emptied.close()
        #expect(try Data(contentsOf: url).isEmpty)
        #expect(GuardedGround.held(url) == GuardedGround.asked)

        let old = try ground.plain("old")
        try Guarded.reopen(old, on: .real).close()
        #expect(GuardedGround.held(old) == GuardedGround.asked, "one an earlier build made is brought as it is opened")
        #expect(try Data(contentsOf: old) == Data("kept".utf8))
        #expect(throws: (any Error).self) { try Guarded.reopen(ground.folder.appendingPathComponent("never"), on: .real) }
    }

    @Test("Where the canary took the class, a class not taken is the write's failure — and what the call made is gone")
    func refused() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let seen = GuardedGround.Seen()
        let device = GuardedGround.device(seen: seen, refusing: { _ in true })
        let words = ground.folder.appendingPathComponent("words"), file = ground.folder.appendingPathComponent("file")
        #expect(throws: Guarded.Refused(name: "words")) {
            try Guarded.write(Data("x".utf8), to: words, atomic: true, on: device)
        }
        #expect(throws: Guarded.Refused(name: "file")) { _ = try Guarded.makeFile(at: file, on: device) }
        // Parents and all: the highest folder the call made goes, and what was there stays.
        let deep = ground.folder.appendingPathComponent("made/a/b", isDirectory: true)
        #expect(throws: Guarded.Refused(name: "b")) { try Guarded.makeFolder(deep, excludedFromBackup: false, on: device) }
        for gone in [words, file, ground.folder.appendingPathComponent("made")] {
            #expect(!FileManager.default.fileExists(atPath: gone.path), "\(gone.lastPathComponent) was left at a lesser class")
        }
        #expect(FileManager.default.fileExists(atPath: ground.folder.path))
        #expect(seen.counted == 0, "thrown, not counted")
        // Where it reaches a person it is said as the system says a file it would not write.
        let said = Guarded.Refused(name: "words").localizedDescription
        #expect(said == CocoaError(.fileWriteNoPermission).localizedDescription)
        #expect(!said.contains("Refused") && !said.contains("words"))
    }

    @Test("What was there before is counted and never the call's failure: a folder asked for again, a file opened again")
    func whatWasThere() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let seen = GuardedGround.Seen()
        // The canary took the class; this folder and this file will not come to it.
        let device = GuardedGround.device(seen: seen, refusing: { _ in true })
        let folder = ground.folder.appendingPathComponent("there", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.protectionKey: GuardedGround.lesser])
        try Guarded.makeFolder(folder, excludedFromBackup: true, on: device)
        #expect(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true, "and the rest of the call is done")
        let old = try ground.plain("old")
        try Guarded.reopen(old, on: device).close()
        #expect(try Data(contentsOf: old) == Data("kept".utf8))
        #expect(seen.counted == 2)
        // What the call has just written is the call's: a failure, and what was there is not removed.
        #expect(throws: Guarded.Refused(name: "old")) { try Guarded.write(Data("new".utf8), to: old, atomic: true, on: device) }
        #expect(throws: Guarded.Refused(name: "old")) { _ = try Guarded.makeFile(at: old, on: device) }
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(seen.counted == 2)
    }

    @Test("A refusal takes only what the call made, and never what another writer put in a folder they share")
    func twoWriters() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        // Caches was purged. This call makes `Fediqo/media/b`; as it does, another writer —
        // which found `Fediqo/media` there by then — makes its own folder in it and writes.
        let media = ground.folder.appendingPathComponent("Fediqo/media", isDirectory: true)
        let theirs = media.appendingPathComponent("a/copy")
        let other = OSAllocatedUnfairLock(initialState: false)
        let device = Guarded.Device(
            asks: GuardedGround.asked,
            held: { url in
                guard url.lastPathComponent == "b" else { return GuardedGround.held(url) }
                let first = other.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first {
                    try? Guarded.makeFolder(theirs.deletingLastPathComponent(), excludedFromBackup: false, on: .real)
                    try? Guarded.write(Data("theirs".utf8), to: theirs, atomic: true, on: .real)
                }
                return GuardedGround.lesser
            },
            canaryTook: { true }, count: {}
        )
        #expect(throws: Guarded.Refused(name: "b")) {
            try Guarded.makeFolder(media.appendingPathComponent("b", isDirectory: true), excludedFromBackup: false, on: device)
        }
        #expect(!FileManager.default.fileExists(atPath: media.appendingPathComponent("b").path), "what the call made is gone")
        #expect(try Data(contentsOf: theirs) == Data("theirs".utf8), "and what the other wrote is where it was")
    }

    @Test("Where no canary has taken the class — a volume that takes none — it is counted and the write stands")
    func refusedWithNoCanary() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let seen = GuardedGround.Seen()
        let device = GuardedGround.device(canaryTook: false, seen: seen, refusing: { _ in true })
        let url = ground.folder.appendingPathComponent("words")
        try Guarded.write(Data("x".utf8), to: url, atomic: true, on: device)
        try Guarded.makeFolder(ground.folder.appendingPathComponent("made"), excludedFromBackup: false, on: device)
        try Guarded.makeFile(at: ground.folder.appendingPathComponent("file"), on: device).close()
        #expect(try Data(contentsOf: url) == Data("x".utf8))
        #expect(seen.counted == 3)
    }

    @Test("In the simulator a class not taken is counted and nothing fails, whatever the canary took")
    func refusedInTheSimulator() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let seen = GuardedGround.Seen()
        let device = GuardedGround.device(simulated: true, seen: seen, refusing: { _ in true })
        let url = ground.folder.appendingPathComponent("words")
        try Guarded.write(Data("x".utf8), to: url, atomic: true, on: device)
        try Guarded.makeFolder(ground.folder.appendingPathComponent("made"), excludedFromBackup: false, on: device)
        try Guarded.makeFile(at: ground.folder.appendingPathComponent("file"), on: device).close()
        #expect(try Data(contentsOf: url) == Data("x".utf8))
        #expect(seen.counted == 3)
    }

    @Test("A volume that throws at the asking itself: made without where none is known to take the class, the write's failure where one is",
          arguments: [true, false])
    func theAskingThrows(simulated: Bool) throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        // The simulator, or a volume no canary has taken the class on.
        let lenient = GuardedGround.device(simulated: simulated, canaryTook: simulated, asking: { throw NoAsking() })
        let url = ground.folder.appendingPathComponent("words")
        try Guarded.write(Data("x".utf8), to: url, atomic: true, on: lenient)
        try Guarded.makeFolder(ground.folder.appendingPathComponent("made"), excludedFromBackup: false, on: lenient)
        try Guarded.makeFile(at: ground.folder.appendingPathComponent("file"), on: lenient).close()
        #expect(try Data(contentsOf: url) == Data("x".utf8))
        #expect(FileManager.default.fileExists(atPath: ground.folder.appendingPathComponent("made").path))
        #expect(FileManager.default.fileExists(atPath: ground.folder.appendingPathComponent("file").path))

        // Where the canary took the class — and on a phone whether or not one has: a phone's
        // volume takes the class, and nothing is ever made there with none asked.
        for strict in [
            GuardedGround.device(asking: { throw NoAsking() }),
            GuardedGround.device(phone: true, canaryTook: false, asking: { throw NoAsking() }),
        ] {
            let other = ground.folder.appendingPathComponent("other")
            #expect(throws: NoAsking.self) { try Guarded.write(Data("x".utf8), to: other, atomic: true, on: strict) }
            #expect(throws: NoAsking.self) { try Guarded.makeFolder(other, excludedFromBackup: false, on: strict) }
            #expect(throws: NoAsking.self) { _ = try Guarded.makeFile(at: other, on: strict) }
            #expect(!FileManager.default.fileExists(atPath: other.path), "nothing was made with no class asked")
        }
    }

    @Test("What is already there is brought to the class, every folder and file, and a link is not followed")
    func bring() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let outside = try ground.plain("outside")
        let root = ground.folder.appendingPathComponent("root", isDirectory: true)
        let inner = root.appendingPathComponent("inner", isDirectory: true)
        let lesser: [FileAttributeKey: Any] = [.protectionKey: GuardedGround.lesser]
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true, attributes: lesser)
        let files = [root.appendingPathComponent("index.sqlite"), inner.appendingPathComponent("copy")]
        for file in files { try #require(FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8), attributes: lesser)) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try #require(([root, inner] + files).allSatisfy { GuardedGround.held($0) == GuardedGround.lesser })

        #expect(Guarded.bring(root, on: .real) == 0)
        #expect(([root, inner] + files).allSatisfy { GuardedGround.held($0) == GuardedGround.asked })
        #expect(GuardedGround.held(outside) == GuardedGround.lesser, "what a link points at is not this folder's")
        #expect(Guarded.bring(root, on: .real) == 0, "asked again, nothing to do")
        #expect(Guarded.bring(ground.folder.appendingPathComponent("never"), on: .real) == 0, "nothing there is nothing refused")
    }

    @Test("What will not take the class is counted by name, and the rest is still brought")
    func bringRefused() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let root = ground.folder.appendingPathComponent("root", isDirectory: true)
        let lesser: [FileAttributeKey: Any] = [.protectionKey: GuardedGround.lesser]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: lesser)
        for name in ["index.sqlite", "index.sqlite-journal", "limits.json"] {
            try #require(FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil, attributes: lesser))
        }
        let device = GuardedGround.device(refusing: { $0.hasPrefix("index.sqlite") })
        #expect(Guarded.bring(root, on: device) == 2)
        #expect(GuardedGround.held(root.appendingPathComponent("limits.json")) == GuardedGround.asked)
        #expect(Guarded.bring(root, on: GuardedGround.device(simulated: true, refusing: { _ in true })) == 4, "the folder itself among them")
    }

    @Test("Asked for the top alone, a folder's own files and folders are brought and nothing inside those")
    func bringTheTop() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let root = ground.folder.appendingPathComponent("root", isDirectory: true)
        let inner = root.appendingPathComponent("inner", isDirectory: true)
        let lesser: [FileAttributeKey: Any] = [.protectionKey: GuardedGround.lesser]
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true, attributes: lesser)
        let top = root.appendingPathComponent("index.sqlite"), deep = inner.appendingPathComponent("copy")
        for file in [top, deep] { try #require(FileManager.default.createFile(atPath: file.path, contents: nil, attributes: lesser)) }
        #expect(Guarded.bring(root, below: false, on: .real) == 0)
        #expect([root, top, inner].allSatisfy { GuardedGround.held($0) == GuardedGround.asked })
        #expect(GuardedGround.held(deep) == GuardedGround.lesser)
        #expect(Guarded.bring(root, on: .real) == 0)
        #expect(GuardedGround.held(deep) == GuardedGround.asked)
    }

    @Test("The canary is made at the class with none there yet to say the volume takes it, reads, and is left alone once there")
    func canary() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let seen = GuardedGround.Seen()
        let url = ground.folder.appendingPathComponent(Guarded.canaryName)
        // None has taken the class yet, and it is made — and held to it — all the same.
        try Guarded.makeCanary(in: ground.folder, on: GuardedGround.device(canaryTook: false, seen: seen))
        #expect(seen.first(Guarded.canaryName) == GuardedGround.asked)
        let made = try Data(contentsOf: url)
        #expect(!made.isEmpty, "something to read")
        let written = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try Guarded.makeCanary(in: ground.folder, on: GuardedGround.device())
        #expect(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == written)
        #expect(Guarded.canaryTook(in: ground.folder, on: .real))
        #expect(!Guarded.canaryTook(in: ground.folder.appendingPathComponent("elsewhere"), on: .real), "none there is none taken")
        // A canary a device made by hand made is that device's: the process's own knows of
        // none, and is neither stricter nor laxer for a test running beside this one.
        #expect(!Guarded.Device.real.canaryTook())
    }

    @Test("A canary found at a lesser class is removed and made again")
    func canaryAtALesserClass() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let old = try ground.plain(Guarded.canaryName, "carried over from another device")
        let seen = GuardedGround.Seen()
        try Guarded.makeCanary(in: ground.folder, on: GuardedGround.device(seen: seen))
        #expect(seen.first(Guarded.canaryName) == GuardedGround.lesser, "found as it was")
        #expect(GuardedGround.held(old) == GuardedGround.asked)
        #expect(try Data(contentsOf: old) != Data("carried over from another device".utf8), "made again, not brought")
    }

    @Test("Making the canary throws on a class not taken whatever else is true, and leaves none", arguments: [true, false])
    func canaryRefused(canaryTook: Bool) throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let device = GuardedGround.device(canaryTook: canaryTook, refusing: { _ in true })
        #expect(throws: Guarded.Refused(name: Guarded.canaryName)) { try Guarded.makeCanary(in: ground.folder, on: device) }
        #expect(!FileManager.default.fileExists(atPath: ground.folder.appendingPathComponent(Guarded.canaryName).path))
        #expect(!Guarded.canaryTook(in: ground.folder, on: device))
        // One an earlier build left at a lesser class goes too: it would read while the index is closed.
        _ = try ground.plain(Guarded.canaryName)
        #expect(throws: Guarded.Refused(name: Guarded.canaryName)) { try Guarded.makeCanary(in: ground.folder, on: device) }
        #expect(!FileManager.default.fileExists(atPath: ground.folder.appendingPathComponent(Guarded.canaryName).path))
    }

    @Test("In the simulator a canary that did not take the class is counted and stands, and is not said to have taken it")
    func canaryInTheSimulator() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let seen = GuardedGround.Seen()
        try Guarded.makeCanary(in: ground.folder, on: GuardedGround.device(simulated: true, seen: seen, refusing: { _ in true }))
        #expect(FileManager.default.fileExists(atPath: ground.folder.appendingPathComponent(Guarded.canaryName).path))
        #expect(seen.counted == 1)
        #expect(!Guarded.canaryTook(in: ground.folder, on: GuardedGround.device(simulated: true, refusing: { _ in true })))
    }

    @Test("A finished package is let out of the class, whole, as the system would have made it")
    func handedOut() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let url = ground.folder.appendingPathComponent("Fediqo.fediqo")
        let sealed = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0) })
        let handle = try Guarded.makeFile(at: url, on: .real)
        try handle.write(contentsOf: sealed)
        try handle.close()
        try #require(GuardedGround.held(url) == GuardedGround.asked)
        try Guarded.handOut(url, on: .real)
        #expect(GuardedGround.held(url) == Guarded.handedOutClass)
        #expect(try Data(contentsOf: url) == sealed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: ground.folder.path) == ["Fediqo.fediqo"], "nothing beside it")
        try Guarded.handOut(url, on: .real)
        #expect(GuardedGround.held(url) == Guarded.handedOutClass, "asked again, nothing to do")
        #expect(Guarded.handedOutClass == .completeUntilFirstUserAuthentication, "named, and not whatever a file gets unasked")
        // Where the class cannot be read there is none to let a file out of, and it is left.
        let unread = ground.folder.appendingPathComponent("unread")
        try Guarded.write(sealed, to: unread, atomic: false, on: .real)
        var blind = Guarded.Device.real
        blind.held = { _ in nil }
        try Guarded.handOut(unread, on: blind)
        #expect(GuardedGround.held(unread) == GuardedGround.asked)
    }

    @Test("Where the system will not change a package's class, it is written again at the one it is to have, and takes its place")
    func handedOutTheLongWay() throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let url = ground.folder.appendingPathComponent("Fediqo.fediqo")
        let sealed = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try Guarded.write(sealed, to: url, atomic: false, on: .real)
        // A device on which the class reads as unchanged after it was asked to change.
        let looks = OSAllocatedUnfairLock(initialState: 0)
        var stubborn = Guarded.Device.real
        stubborn.held = { url in
            let look = looks.withLock { looks in
                looks += 1
                return looks
            }
            return look <= 2 ? GuardedGround.asked : GuardedGround.held(url)
        }
        try Guarded.handOut(url, on: stubborn)
        #expect(GuardedGround.held(url) == Guarded.handedOutClass)
        #expect(try Data(contentsOf: url) == sealed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: ground.folder.path) == ["Fediqo.fediqo"], "nothing beside it")
    }

    @Test("A file at any other class comes to the platform's — one an earlier build of this branch left at complete among them",
          arguments: [FileProtectionType.complete, .completeUnlessOpen, .completeUntilFirstUserAuthentication])
    func broughtFrom(other: FileProtectionType) throws {
        let ground = try GuardedGround()
        defer { ground.remove() }
        let url = ground.folder.appendingPathComponent("left")
        // Written at its class as `Guarded` writes one, and not made and then classed: a file
        // made that way is one the system sometimes answers is busy when its class is changed.
        var earlier = Guarded.Device.real
        earlier.asks = other
        try Guarded.write(Data("kept".utf8), to: url, atomic: true, on: earlier)
        try #require(GuardedGround.held(url) == other)
        #expect(Guarded.bring(ground.folder, on: .real) == 0)
        #expect(GuardedGround.held(url) == GuardedGround.asked)
        #expect(try Data(contentsOf: url) == Data("kept".utf8))
    }

    @Test("The class is the platform's: complete unless open on a Mac, complete on a phone")
    func thePlatformsClass() {
        #if os(macOS)
        #expect(Guarded.platformClass == .completeUnlessOpen)
        #else
        #expect(Guarded.platformClass == (ProcessInfo.processInfo.isiOSAppOnMac ? .completeUnlessOpen : .complete))
        #endif
        #expect(Guarded.Device.real.asks == Guarded.platformClass)
    }
}

/// The tests' switch (#344): a process told to ask for no class makes plain files, checks
/// nothing and brings nothing — so no test but the few above depends on whether this machine's
/// screen is locked.
@Suite("A test process asks for no class")
struct GuardedNoClassTests {
    /// A device that would refuse everything, were anything asked of it.
    private func device(_ seen: GuardedGround.Seen) -> Guarded.Device {
        Guarded.Device(asks: nil, held: { seen.note($0, nil); return nil }, canaryTook: { true }, count: { seen.count() }, asking: { throw CocoaError(.featureUnsupported) })
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("This process was told so before any test ran, whichever test is run")
    func theSwitchIsOn() {
        #expect(Guarded.Device.this.asks == nil)
        #expect(Guarded.Device.real.asks == Guarded.platformClass, "and the real device is still to hand")
    }

    @Test("The probe makes the canary and its folder where there are none, and reads it afresh each time it is asked")
    func theProbe() throws {
        let folder = try scratch().appendingPathComponent("Application Support/Fediqo", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let canary = folder.appendingPathComponent(Guarded.canaryName)
        #expect(Guarded.probeCanary(in: folder) == .reads)
        #expect(try !Data(contentsOf: canary).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [Guarded.canaryName], "nothing left beside it")
        // There, and not to be read — which is what a lock gives: refused, and not "none".
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: canary.path)
        #expect(Guarded.probeCanary(in: folder) == .refused)
        #expect(Guarded.probeCanary(in: folder) == .refused, "asked again, the same: nothing was written over it")
        // Written anew — a file of its own, moved over the old one whole — it reads.
        #expect(Guarded.probeCanary(in: folder, anew: true) == .reads)
        #expect(Guarded.probeCanary(in: folder) == .reads)
    }

    @Test("Where no canary can be made for a reason that is no refusal, the probe says none — and never refused")
    func theProbeFindsNone() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // No folder, and none to be had: a file stands where it would be.
        let blocked = root.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: blocked)
        #expect(Guarded.probeCanary(in: blocked.appendingPathComponent("Fediqo", isDirectory: true)) == .none)
        #expect(!Guarded.isRefusal(CocoaError(.fileWriteOutOfSpace)) && !Guarded.isRefusal(CocoaError(.fileNoSuchFile)))
        #expect(Guarded.isRefusal(Guarded.Refused(name: "x")))
        #expect(Guarded.isRefusal(CocoaError(.fileReadNoPermission)) && Guarded.isRefusal(CocoaError(.fileWriteNoPermission)))
        #expect(Guarded.isRefusal(POSIXError(.EPERM)) && Guarded.isRefusal(POSIXError(.EACCES)) && !Guarded.isRefusal(POSIXError(.ENOSPC)))
        // A folder that takes no new file — which is also what a locked phone gives — refuses.
        let closed = root.appendingPathComponent("closed", isDirectory: true)
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: closed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: closed.path) }
        #expect(Guarded.probeCanary(in: closed) == .refused)
    }

    @Test("On a volume that keeps no class the canary stands and reads: nothing there is ever closed by a lock")
    func aVolumeThatKeepsNoClass() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let seen = GuardedGround.Seen()
        // Every write succeeds, and whatever class is asked reads back as none at all. (The
        // class asked here is the one a file has anyway, so nothing turns on this machine's lock.)
        let device = Guarded.Device(
            asks: .completeUntilFirstUserAuthentication, held: { _ in nil }, canaryTook: { false }, count: { seen.count() }
        )
        try Guarded.makeCanary(in: folder, on: device)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(Guarded.canaryName).path))
        #expect(seen.counted == 1, "counted, as a class not taken")
        #expect(Guarded.probeCanary(in: folder, on: device) == .reads)
        #expect(seen.counted == 2, "its folder counted too — and the canary left alone once it is there")
        #expect(Guarded.probeCanary(in: folder, on: device) == .reads)
        #expect(seen.counted == 3, "asked again: the folder again, and the canary still not rewritten")
        #expect(!Guarded.canaryTook(in: folder, on: device), "never said to have taken a class it did not")
        // Another, real class is still a refusal: that canary would read while the index is closed.
        let other = try scratch()
        defer { try? FileManager.default.removeItem(at: other) }
        let lesser = Guarded.Device(asks: .complete, held: { _ in .completeUntilFirstUserAuthentication }, canaryTook: { false }, count: {})
        var asksNothingReal = lesser
        asksNothingReal.asking = { throw CocoaError(.featureUnsupported) }
        #expect(throws: Guarded.Refused(name: Guarded.canaryName)) { try Guarded.makeCanary(in: other, on: asksNothingReal) }
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent(Guarded.canaryName).path))
        #expect(Guarded.probeCanary(in: other, on: asksNothingReal) == .refused)
    }

    @Test("Only what is plainly no lock is 'none'; an error nobody knows is a refusal; written and then not to be read is the lock itself")
    func whatTheProbeMakesOfAFailure() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let device = Guarded.Device(asks: nil, held: { _ in nil }, canaryTook: { false }, count: {})
        func probe(anew: Bool = false, _ error: any Error) -> ProtectedData.Canary {
            Guarded.probeCanary(in: folder, anew: anew, on: device) { _ in throw error }
        }
        #expect(probe(POSIXError(.EPERM)) == .refused)
        #expect(probe(CocoaError(.fileReadNoPermission)) == .refused)
        #expect(probe(POSIXError(.EIO)) == .refused, "not on the list of what is plainly no lock")
        #expect(probe(CocoaError(.fileReadCorruptFile)) == .refused)
        #expect(probe(POSIXError(.ENOSPC)) == .none && probe(POSIXError(.EROFS)) == .none && probe(POSIXError(.EDQUOT)) == .none)
        #expect(probe(CocoaError(.fileWriteOutOfSpace)) == .none && probe(CocoaError(.fileReadNoSuchFile)) == .none)
        // Written anew a moment ago — the write went through — and the read of it is refused.
        #expect(probe(anew: true, POSIXError(.EPERM)) == .closed)
        #expect(probe(anew: true, CocoaError(.fileReadNoPermission)) == .closed)
        #expect(probe(anew: true, POSIXError(.ENOSPC)) == .none, "only a refusal is that signature")
        #expect(Guarded.probeCanary(in: folder, anew: true, on: device) == .reads)
    }

    @Test("On a phone the probe also makes a file beside the canary: a folder that takes none is the lock, though the canary still reads")
    func thePhonesHalfOfTheProbe() throws {
        let folder = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        // The class asked is the one a file has anyway, so nothing here turns on this machine's lock.
        func device(phone: Bool) -> Guarded.Device {
            Guarded.Device(
                asks: .completeUntilFirstUserAuthentication, phone: phone,
                held: { $0.hasDirectoryPath ? .completeUntilFirstUserAuthentication : Guarded.Device.real.heldNow($0) },
                canaryTook: { true }, count: {}
            )
        }
        #expect(Guarded.probeCanary(in: folder, on: device(phone: true)) == .reads)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [Guarded.canaryName], "the scratch file is gone")
        // At complete, under lock, nothing new can be made — and that is a refusal by itself.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        #expect(Guarded.probeCanary(in: folder, on: device(phone: true)) == .refused)
        #expect(Guarded.probeCanary(in: folder, on: device(phone: false)) == .reads, "a Mac is not asked that: at its class a new file says nothing")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(Guarded.probeCanary(in: folder, on: device(phone: true)) == .reads)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [Guarded.canaryName])
    }

    @Test("Everything is made as the system makes it, and nothing is read back, thrown or counted")
    func plain() throws {
        let folder = try scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let seen = GuardedGround.Seen()
        let made = folder.appendingPathComponent("a/b", isDirectory: true)
        try Guarded.makeFolder(made, excludedFromBackup: true, on: device(seen))
        try Guarded.write(Data("x".utf8), to: made.appendingPathComponent("words"), atomic: true, on: device(seen))
        let handle = try Guarded.makeFile(at: made.appendingPathComponent("file"), on: device(seen))
        try handle.write(contentsOf: Data("y".utf8))
        try handle.close()
        try Guarded.reopen(made.appendingPathComponent("file"), on: device(seen)).close()
        try Guarded.makeCanary(in: made, on: device(seen))
        #expect(Guarded.bring(folder, on: device(seen)) == 0)
        // What the system gives a file nobody asked anything for, in the same folder.
        let reference = made.appendingPathComponent("reference")
        try #require(FileManager.default.createFile(atPath: reference.path, contents: nil))
        // Whatever that reads back as — nothing at all, where the volume keeps no class.
        for name in ["words", "file", Guarded.canaryName] {
            #expect(GuardedGround.held(made.appendingPathComponent(name)) == GuardedGround.held(reference), "\(name)")
        }
        try Guarded.handOut(made.appendingPathComponent("words"), on: device(seen))
        #expect(Guarded.canaryTook(in: made, on: device(seen)), "there, and no class to hold it to")
        #expect(try Data(contentsOf: made.appendingPathComponent("words")) == Data("x".utf8))
        #expect(try Data(contentsOf: made.appendingPathComponent("file")) == Data("y".utf8))
        #expect(try made.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(seen.counted == 0)
        #expect(seen.first("words") == nil && seen.first("file") == nil, "never asked what class anything is at")
    }
}

/// #344: nothing in the app makes a folder or a file past `Guarded`, and no connection to an
/// index on disk is made past the one configuration. Held to the source, because a write site
/// added later is one more file at the system's default and no behaviour a Mac's test can see.
@Suite("Nothing is written past the one place")
struct GuardedSourceTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The one file that may spell any of these.
    private static let theOnePlace = "Sources/FediqoCore/Guarded.swift"

    /// What makes a file or a folder without the class — or opens, copies, links or re-classes
    /// one past the one place — by how it is spelled, each with a name to say it by. Matched
    /// against the source with its comments gone and every run of white space, line ends
    /// among them, made one space: a call broken over lines is the same call.
    private static let raw: [(name: String, pattern: String)] = [
        ("createDirectory(", #"createDirectory\("#),
        (".write(to:", #"\.write\( ?to:"#),
        (".write(toFile:", #"\.write\( ?toFile:"#),
        ("createFile(", #"createFile\("#),
        ("FileHandle(forWriting…/forUpdating…", #"FileHandle\( ?for(Writing|Updating)(To|AtPath)?:"#),
        ("copyItem(", #"\bcopyItem\("#),
        ("linkItem(", #"\blinkItem\("#),
        ("replaceItem", #"\breplaceItem"#),
        ("createSymbolicLink(", #"createSymbolicLink\("#),
        ("OutputStream(", #"\bOutputStream\("#),
        ("NSKeyedArchiver", #"\bNSKeyedArchiver\b"#),
        ("DatabasePool(", #"\bDatabasePool\("#),
        ("sqlite3_open", #"\bsqlite3_open"#),
        ("fopen(", #"\bfopen\("#),
        ("mkdir(", #"\bmkdir\w*\("#),
        ("open(… O_CREAT/O_WRONLY/O_RDWR", #"\bO_(CREAT|WRONLY|RDWR)\b"#),
        (".noFileProtection", #"\.noFileProtection\b"#),
        ("a protection key", #"[pP]rotectionKey\b"#),
        ("setAttributes(", #"\bsetAttributes\("#),
        ("FileProtectionType", #"\b(URL)?FileProtection(Type)?\b"#),
        ("SQLite told to forget its temporary folder", #"keepTemporaries\( ?in: ?nil"#),
        // The log's lines of a failed write would then carry what was being written: hosts, post ids.
        ("SQLite's arguments made public in errors", #"publicStatementArguments"#),
        ("a connection past the one configuration", #"\bDatabaseQueue\((?! ?path: [^,()]+, configuration: (StoreFile|Self)\.configuration\()"#),
    ]

    /// `text` with its comments gone and its white space folded.
    static func folded(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func count(_ pattern: String, in folded: String) -> Int {
        // The system's, for the look-arounds Swift's own does not have.
        let expression = try! NSRegularExpression(pattern: pattern)
        return expression.numberOfMatches(in: folded, range: NSRange(folded.startIndex..., in: folded))
    }

    /// The names of what `text` spells that writes past the one place.
    static func bypasses(in text: String) -> [String] {
        let code = folded(text)
        return raw.filter { count($0.pattern, in: code) > 0 }.map(\.name)
    }

    /// Every Swift file of the app, by its path from the repository's root.
    private static func sources() throws -> [(path: String, text: String)] {
        try ["Sources", "Apps"].flatMap { top -> [(String, String)] in
            let walk = try #require(FileManager.default.enumerator(at: root.appendingPathComponent(top), includingPropertiesForKeys: nil))
            return try walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { file in
                (String(file.path.dropFirst(root.path.count + 1)), try String(contentsOf: file, encoding: .utf8))
            }
        }
    }

    @Test("Each spelling of a write past the one place is one the reading of the source catches", arguments: [
        "try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)",
        "try data.write(to: url, options: .atomic)",
        "try? Data().write(to: marker)",
        "try data.write(\n            to: url, options: .atomic\n        )",
        "try text.write(toFile: path, atomically: true, encoding: .utf8)",
        "FileManager.default.createFile(atPath: url.path, contents: nil)",
        "let handle = try FileHandle(forWritingTo: url)",
        "let handle = try FileHandle(\n    forUpdating: url)",
        "let handle = FileHandle(forWritingAtPath: path)",
        "try manager.copyItem(at: from, to: to)",
        "try manager.linkItem(at: from, to: to)",
        "_ = try manager.replaceItemAt(url, withItemAt: copy)",
        "try manager.createSymbolicLink(at: link, withDestinationURL: target)",
        "let stream = OutputStream(url: url, append: false)",
        "let data = try NSKeyedArchiver.archivedData(withRootObject: thing, requiringSecureCoding: true)",
        "let pool = try DatabasePool(path: path)",
        "sqlite3_open(path, &db)",
        "sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)",
        "let file = fopen(path, \"w\")",
        "mkdir(path, 0o700)",
        "let descriptor = open(path, O_CREAT | O_RDWR, 0o600)",
        "let descriptor = open(path, O_WRONLY)",
        "try data.write(to: url, options: .noFileProtection)",
        "try manager.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: path)",
        "try manager.setAttributes(attributes, ofItemAtPath: path)",
        "let attributes: [FileAttributeKey: Any] = [.protectionKey: kind]",
        "let held = try url.resourceValues(forKeys: [.fileProtectionKey]).fileProtection",
        "let kind = FileProtectionType.completeUnlessOpen",
        "StoreFile.keepTemporaries(in: nil)",
        "configuration.publicStatementArguments = true",
        "let queue = try DatabaseQueue(path: path)",
        "let queue = try DatabaseQueue()",
        "let queue = try DatabaseQueue(path: path, configuration: readOnly)",
        "let queue = try DatabaseQueue(path: path, configuration: Configuration())",
        "let queue = try DatabaseQueue(\n    path: path,\n    configuration: readOnly\n)",
    ])
    func caught(line: String) {
        #expect(!Self.bypasses(in: "    \(line)\n").isEmpty)
    }

    @Test("What goes through the one place, a comment, a write to a handle already open, and a method of the app's own called open are not")
    func notCaught() {
        let fine = """
            try Guarded.write(data, to: url)
            // try data.write(to: url, options: .atomic)
            try handle.write(contentsOf: chunk)
            try self.init(database: DatabaseQueue(path: path, configuration: Self.configuration(busyWait: busyWait)))
            let posts = (try? DatabaseQueue(
                path: url.path, configuration: StoreFile.configuration(readOnly: true, busyWait: wait)
            ))
            try manager.moveItem(at: index, to: aside)
            try manager.removeItem(at: aside)
            open(at: directory, now: now) { try StoreFile(at: $0, busyWait: busyWait) }
            if device.held(file) != device.asks { refused += 1 }
            """
        #expect(Self.bypasses(in: fine).isEmpty, "\(Self.bypasses(in: fine))")
    }

    @Test("No file in any of the three targets, or in the apps, writes past the one place")
    func theSource() throws {
        let files = try Self.sources()
        #expect(files.count > 100, "the source was found")
        #expect(files.contains { $0.path == "Apps/Shared/FediqoApp.swift" })
        #expect(files.contains { $0.path == Self.theOnePlace }, "and the one place is where it is taken to be")
        for file in files where file.path != Self.theOnePlace {
            let found = Self.bypasses(in: file.text)
            #expect(found.isEmpty, "\(file.path) writes past Guarded: \(found)")
        }
    }

    /// **A rename keeps the class of what is renamed**, so each is safe only by where its
    /// source was made — which is why each is counted here, by file. A new one fails this
    /// until somebody has looked at what it moves and from where, and written its count down.
    @Test("Every rename is one somebody looked at: by file, and how many")
    func renames() throws {
        var found: [String: Int] = [:]
        for file in try Self.sources() where file.path != Self.theOnePlace {
            let renames = Self.count(#"\bmoveItem\("#, in: Self.folded(file.text))
            if renames > 0 { found[file.path] = renames }
        }
        #expect(found == [
            // One of the person's own lists, made by `Guarded`, moved aside under another name
            // in its own folder while a read back replaces it, and back again.
            "Sources/FediqoCore/ListFile.swift": 3,
            // A cache of pictures swapped with one a read back staged, both made by `Guarded`.
            "Sources/FediqoPersistence/MediaCache.swift": 4,
            // The index and what lies beside it, put aside under another name in its own folder.
            "Sources/FediqoPersistence/StoreFile.swift": 3,
            // A read back's state, moved on from one name to the next in its own aside — and
            // a commit's own name, an empty file `Guarded` made beside the index, moved on to
            // the name that says every step held.
            "Sources/FediqoPersistence/ReadBackState.swift": 2,
            // A read back: the index to and from an aside `Guarded` made, in the store's folder —
            // and a choice between two stores, or a launch finishing one, moving the other aside.
            "Sources/FediqoPersistence/StorePackager.swift": 8,
            // A read back's aside of an open file, made by SQLite in a folder `Guarded` made
            // beside the index, moved back into the index's place where none stands (#360).
            "Sources/FediqoPersistence/StoreReadBack.swift": 1,
        ])
    }

    /// The entries that take what says whether the device can be read, each of which goes by
    /// `.always` — nothing is ever closed — where it is handed none, for the tests' sake.
    private static let asksTheCanary = [
        "StoreFile.open(", "StoreFile.openApplicationSupport(", "StoreSaver(", "StorePackager(", ".sweepLeftovers(",
    ]

    /// The calls in `text` of an entry that takes the canary and is handed none: each by
    /// its spelling. What a call is handed is what stands between its brackets, however
    /// many lines it is broken over.
    static func withoutACanary(in text: String) -> [String] {
        let code = folded(text)
        var found: [String] = []
        for entry in asksTheCanary {
            var from = code.startIndex
            while let call = code.range(of: entry, range: from..<code.endIndex) {
                from = call.upperBound
                // Part of a longer name is another thing's call.
                if let before = code[..<call.lowerBound].last, entry.first != ".", before.isLetter || before.isNumber || before == "_" { continue }
                var depth = 1
                var end = call.upperBound
                while end < code.endIndex, depth > 0 {
                    if code[end] == "(" { depth += 1 } else if code[end] == ")" { depth -= 1 }
                    end = code.index(after: end)
                }
                if !code[call.upperBound..<end].contains("protected:") { found.append(entry) }
            }
        }
        return found
    }

    /// **A call that leaves it out gets `.always`, silently**: damage classed, the sweep and
    /// the expiry run, with no canary asked. The default stays, because some two hundred and
    /// thirty calls in the tests rest on it; what the app itself spells must name it.
    @Test("Every call in the app of an entry that takes the canary hands it one: none goes by the default, under which nothing is ever closed")
    func theCanaryIsHandedIn() throws {
        for file in try Self.sources() {
            let found = Self.withoutACanary(in: file.text)
            #expect(found.isEmpty, "\(file.path) leaves `protected:` to its default: \(found)")
        }
        let app = try #require(try Self.sources().first { $0.path == "Apps/Shared/FediqoApp.swift" }).text
        for entry in ["StoreFile.openApplicationSupport(", "StoreSaver(", "StorePackager(", ".sweepLeftovers("] {
            #expect(Self.folded(app).contains(entry), "the app's launch is where \(entry) is called")
        }
    }

    @Test("A call that leaves the canary out is one the reading of the source catches, however it is broken over lines; one that names it, and another thing's call, are not", arguments: [
        ("return StoreFile.openApplicationSupport(unlocked: unlocked)", 1),
        ("StorePackager.sweepLeftovers(directory: directory, media: media?.location)", 1),
        ("saver = StoreSaver(\n    store: store, file: opened.file,\n    holding: (opened.sources, opened.notes)\n)", 1),
        ("carrier = StorePackager(directory: directory, file: file, store: ItemStore(sources: [], notes: []), saver: saver)", 1),
        ("let opened = StoreFile.open(at: directory, now: Date())", 1),
        ("return StoreFile.openApplicationSupport(protected: protected, unlocked: unlocked)", 0),
        ("saver = StoreSaver(\n    store: store, file: opened.file, protected: protected,\n    holding: nil\n)", 0),
        ("StorePackager.sweepLeftovers(directory: directory, media: nil, protected: protected)", 0),
        ("let other = OtherStoreSaver(store: store)", 0),
        ("/// `StoreSaver(store:file:)` saves into a file", 0),
    ])
    func caughtWithoutACanary(line: String, count: Int) {
        #expect(Self.withoutACanary(in: "    \(line)\n").count == count)
    }

    @Test("The switch that asks for no class is compiled for a debug build alone, and nothing in the app calls it")
    func theSwitch() throws {
        var declared = 0
        for file in try Self.sources() {
            let uses = file.text.components(separatedBy: "askForNoClass").count - 1
            guard file.path == Self.theOnePlace else {
                #expect(uses == 0, "\(file.path) turns the class off")
                continue
            }
            #expect(uses == 1, "its declaration, and no call")
            let declaration = try #require(file.text.range(of: "package static func askForNoClass()"))
            let before = file.text[..<declaration.lowerBound], after = file.text[declaration.upperBound...]
            let opened = try #require(before.range(of: "#if DEBUG", options: .backwards))
            #expect(!before[opened.upperBound...].contains("#endif") && !before[opened.upperBound...].contains("#else"))
            let closed = try #require(after.range(of: "#endif"))
            #expect(!after[..<closed.lowerBound].contains("#if"))
            declared += 1
        }
        #expect(declared == 1)
        // And each test target turns it on, in the one file that does.
        for target in ["FediqoCoreTests", "FediqoPersistenceTests", "FediqoUITests"] {
            let file = Self.root.appendingPathComponent("Tests/\(target)/ScratchIsPlain.swift")
            #expect(try String(contentsOf: file, encoding: .utf8).contains("Guarded.askForNoClass()"), "\(target)")
        }
    }

    @Test("One configuration is made for a connection, in one place")
    func oneConfiguration() throws {
        let made = try Self.sources().filter { Self.count(#"(?<![A-Za-z])Configuration\(\)"#, in: Self.folded($0.text)) > 0 }
        #expect(made.map(\.path) == ["Sources/FediqoPersistence/StoreFile.swift"])
        #expect(Self.count(#"(?<![A-Za-z])Configuration\(\)"#, in: Self.folded(try #require(made.first).text)) == 1)
    }

    @Test("A finished package is let out of the class in one place, just before the person is asked where it goes")
    func theHandOut() throws {
        // The bare word, however it is reached: through the type, a reference to it, or another name.
        let uses = try Self.sources().filter { $0.path != Self.theOnePlace }
            .map { (path: $0.path, count: Self.count(#"\bhandOut\b"#, in: Self.folded($0.text)), code: Self.folded($0.text)) }
            .filter { $0.count > 0 }
        #expect(uses.map(\.path) == ["Sources/FediqoUI/Shell/ShellCarry.swift"])
        #expect(uses.first?.count == 1)
        let carry = try #require(uses.first).code
        #expect(carry.contains("try Guarded.handOut(url) return .moving(url)"))
    }

    /// Once the app asks the system for protection by default (below), a file made with no
    /// class asked is at complete on a phone — so a package handed out must be asked for at
    /// its own class by name, on the path that changes the class and on the one that writes it
    /// again. Held here, where it runs whatever the screen: what the class then reads back as
    /// is the real-class suite's.
    @Test("A package handed out is asked for at its own class by name on both paths, never left to what a file gets when nothing is asked")
    func theHandOutNamesItsClass() throws {
        let place = try String(contentsOf: Self.root.appendingPathComponent(Self.theOnePlace), encoding: .utf8)
        let from = try #require(place.range(of: "package static func handOut(_ url: URL, on device: Device) throws {"))
        let to = try #require(place.range(of: "package static let handedOutClass = ", range: from.upperBound..<place.endIndex))
        let body = String(place[from.upperBound..<to.lowerBound])
        #expect(body.contains("manager.setAttributes([.protectionKey: handedOutClass], ofItemAtPath: url.path)"))
        #expect(body.contains("try Data().write(to: copy, options: option(for: handedOutClass))"))
        // Nothing in it is made any other way: one write, with the class; no file made bare.
        #expect(Self.count(#"\.write\(to:"#, in: body) == 1 && !body.contains("createFile(") && !body.contains("copyItem("))
        #expect(place.contains("package static let handedOutClass = FileProtectionType.completeUntilFirstUserAuthentication\n"))
        #expect(place.contains("case .completeUntilFirstUserAuthentication: .completeFileProtectionUntilFirstUserAuthentication\n"))
        #expect(Guarded.handedOutClass == .completeUntilFirstUserAuthentication)
    }

    /// The second half of D2: what the system writes for the app — its preferences, its web
    /// store, its caches — is asked for at the class by the iOS app's entitlement, since the
    /// app never gets to make those. The Mac asks nothing here: it is held at its own class by
    /// `Guarded`, and must go on writing behind a locked screen.
    @Test("The iOS app asks the system for the complete class by default, in its entitlements and from project.yml; the Mac app's entitlements stay empty")
    func theEntitlement() throws {
        let project = try String(contentsOf: Self.root.appendingPathComponent("project.yml"), encoding: .utf8)
        let phone = try #require(project.range(of: "\n  Fediqo-iOS:\n    type: application"))
        let asked = "    entitlements:\n      path: Apps/iOS/Fediqo.entitlements\n      properties:\n        com.apple.developer.default-data-protection: NSFileProtectionComplete\n"
        let found = try #require(project.range(of: asked))
        #expect(found.lowerBound > phone.lowerBound, "asked of the iOS target")
        #expect(project.components(separatedBy: "default-data-protection").count - 1 == 1, "and of no other")
        #expect(project[phone.upperBound...].contains("        CODE_SIGN_ENTITLEMENTS: Apps/iOS/Fediqo.entitlements\n"))
        // The file XcodeGen writes from that block, as it is kept in the repository.
        func entitlements(_ path: String) throws -> [String: Any] {
            let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
            return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
        let ios = try entitlements("Apps/iOS/Fediqo.entitlements")
        #expect(ios.count == 1 && ios["com.apple.developer.default-data-protection"] as? String == "NSFileProtectionComplete")
        #expect(try entitlements("Apps/macOS/Fediqo.entitlements").isEmpty)
    }

    @Test("The app's launch classes its folders before it opens the index, and walks the rest off the main actor")
    func theLaunch() throws {
        let app = try String(contentsOf: Self.root.appendingPathComponent("Apps/Shared/FediqoApp.swift"), encoding: .utf8)
        let first = try #require(app.range(of: "ProtectedFolders.first()"))
        let rest = try #require(app.range(of: "Task.detached(priority: .utility) { ProtectedFolders.rest() }"))
        let caches = try #require(app.range(of: "MediaCache.caches()"))
        let opened = try #require(app.range(of: "StoreFile.openApplicationSupport(protected: protected, unlocked: unlocked)"))
        #expect(first.lowerBound < caches.lowerBound, "before the first folder of the app's own is made")
        #expect(first.lowerBound < opened.lowerBound)
        #expect(first.lowerBound < rest.lowerBound)
    }
}
