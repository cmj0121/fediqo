import FediqoCore
import Foundation
import GRDB
import Testing
@testable import FediqoPersistence

/// What a build before this one makes of a read back's aside, **as that build wrote it**:
/// the reading of `settleHalfCommits` and of a save's `dropWhatWasReplaced` at 322fc34b, kept
/// here word for word in what it decides, so that the layout this build writes can be held to
/// it. Going back a version is expected, and such a build must never delete the old store.
enum EarlierBuild {
    static let marker = ".committing"
    static let index = "index.sqlite"
    static let sidecars = ["-journal", "-wal", "-shm"]

    private static func word(_ aside: URL) -> Data? { try? Data(contentsOf: aside.appendingPathComponent(marker)) }
    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Its launch: every aside settled as it settled them. How many it put back, and how many
    /// it left for the person to choose between.
    static func settle(in directory: URL) throws -> (putBack: Int, unsettled: Int) {
        let manager = FileManager.default
        var putBack = 0, unsettled = 0
        let target = directory.appendingPathComponent(index)
        for name in try manager.contentsOfDirectory(atPath: directory.path).sorted() where name.hasPrefix("incoming-aside-") {
            let aside = directory.appendingPathComponent(name)
            guard exists(aside.appendingPathComponent(marker)) else { continue }
            if word(aside) == Data("replaced".utf8), exists(target) {
                try? manager.removeItem(at: aside)
                continue
            }
            if word(aside) == Data("displaced".utf8) {
                if !exists(aside.appendingPathComponent(index)) {
                    for suffix in sidecars {
                        let taken = aside.appendingPathComponent(index + suffix), home = directory.appendingPathComponent(index + suffix)
                        if exists(taken), !exists(home) { try? manager.moveItem(at: taken, to: home) }
                    }
                    try? manager.removeItem(at: aside)
                }
                continue
            }
            guard exists(aside.appendingPathComponent(index)) else {
                try? manager.removeItem(at: aside)
                continue
            }
            let thePackages = word(aside) == Data("replacing".utf8) || word(aside) == Data("undoing".utf8)
            if exists(target), !thePackages, StoreFile.holdsNothing(indexAt: target.path) != true {
                unsettled += 1
                continue
            }
            do {
                if exists(target) {
                    for suffix in [""] + sidecars {
                        let stands = directory.appendingPathComponent(index + suffix)
                        if exists(stands) { try manager.removeItem(at: stands) }
                    }
                }
                for suffix in sidecars + [""] {
                    let kept = aside.appendingPathComponent(index + suffix)
                    guard exists(kept) else { continue }
                    try manager.moveItem(at: kept, to: directory.appendingPathComponent(index + suffix))
                }
                try manager.removeItem(at: aside)
                putBack += 1
            } catch {
                unsettled += 1
            }
        }
        // Its sweep: a staging with no marker goes.
        for name in try manager.contentsOfDirectory(atPath: directory.path) where name.hasPrefix("incoming-") {
            let folder = directory.appendingPathComponent(name)
            if !exists(folder.appendingPathComponent(marker)) { try? manager.removeItem(at: folder) }
        }
        return (putBack, unsettled)
    }

    /// What a save of its deletes: an aside it reads as replaced, or as chosen against.
    static func saved(in directory: URL) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasPrefix("incoming-aside-") {
            let aside = directory.appendingPathComponent(name)
            let replaced = word(aside) == Data("replaced".utf8) && exists(directory.appendingPathComponent(index))
            if replaced || word(aside) == Data("displaced".utf8) { try? FileManager.default.removeItem(at: aside) }
        }
    }
}

/// #344: how far a read back got is a name beside an anchor, not words inside a file — read
/// by a listing, moved on by a rename, and understood by a build from before it as "moved
/// aside", which never costs the old store.
@Suite("A read back's state is a name")
struct ReadBackStateTests {
    typealias Device = PackagerFixture.PackagerDevice
    typealias State = StorePackager.AsideState
    private static let mastodon = PackagerFixture.mastodon

    private static func post(_ id: Int, _ phrase: String) -> Note {
        Note(
            id: "https://\(mastodon.host)/users/ada/statuses/\(id)", source: mastodon, author: "Ada", handle: "@ada",
            body: phrase, postedAt: PackagerFixture.origin.addingTimeInterval(Double(id) * 60),
            categories: [.public], spoiler: "", statusID: "\(id)"
        )
    }

    private static let old = Data("old-store-phrase".utf8), new = Data("new-store-phrase".utf8)

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func names(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func asides(_ dir: URL) throws -> [URL] {
        try names(dir).filter { $0.hasPrefix("incoming-aside-") }.map { dir.appendingPathComponent($0) }
    }

    /// Whether any index under `dir` still holds the old store's posts: the one thing that
    /// must be true after anything a launch of any build does.
    private func oldStoreKept(under dir: URL) throws -> Bool {
        try FileManager.default.subpathsOfDirectory(atPath: dir.path).contains { path in
            path.hasSuffix("index.sqlite") && (try? Data(contentsOf: dir.appendingPathComponent(path)))?.range(of: Self.old) != nil
        }
    }

    /// A device holding the old store with no file open, a package holding the new one, and a
    /// packager on that device.
    private func devices(protected: ProtectedData = .always) async throws -> (onto: Device, package: URL, packager: StorePackager, cleanup: () -> Void) {
        let from = try await Device(sources: [Self.mastodon], notes: (1...3).map { Self.post($0, "new-store-phrase") })
        let onto = try await Device(noFile: true)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fediqo")
        try await from.packager().takeAway(to: package, key: .password("password"), pictures: false) { _ in }
        let held = try StoreFile(at: onto.directory)
        try await held.save(sources: [Self.mastodon], notes: (1...5).map { Self.post($0, "old-store-phrase") })
        try held.db.close()
        return (onto, package, onto.packager(protected: protected), {
            from.remove(); onto.remove()
            try? FileManager.default.removeItem(at: package)
        })
    }

    /// The folder as it stood at each point of a read back that lands — or, `refusing`, one
    /// whose last step refuses and is undone.
    private func points(refusing: Bool = false) async throws -> (at: [StorePackager.CommitPoint: URL], cleanup: () -> Void) {
        var (onto, package, packager, cleanup) = try await devices()
        let root = scratch()
        let taken = OSAllocatedUnfairLockBox<[StorePackager.CommitPoint: URL]>([:])
        let folder = onto.directory
        packager.witness = { point in
            let copy = root.appendingPathComponent("\(point)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: folder, to: copy)
            taken.with { $0[point] = copy }
        }
        if refusing {
            let blocking = folder.appendingPathComponent(LimitAccountFile.name, isDirectory: true)
            try FileManager.default.createDirectory(at: blocking, withIntermediateDirectories: true)
            try Data().write(to: blocking.appendingPathComponent("in the way"))
            await #expect(throws: (any Error).self) {
                try await packager.readBack(package, key: .password("password"), replacing: true) { _ in }
            }
        } else {
            try await packager.readBack(package, key: .password("password"), replacing: true) { _ in }
        }
        return (taken.with { $0 }, {
            cleanup()
            try? FileManager.default.removeItem(at: root)
        })
    }

    // MARK: - The layout

    @Test("At every point of a read back the anchor is there and empty, and the state is the one name beside it")
    func theLayout() async throws {
        let (landing, cleanup) = try await points()
        defer { cleanup() }
        let (undone, cleanupUndone) = try await points(refusing: true)
        defer { cleanupUndone() }
        let expected: [(StorePackager.CommitPoint, [StorePackager.CommitPoint: URL], State)] = [
            (.movedAside, landing, .aside), (.replacing, landing, .replacing), (.movedIn, landing, .replacing),
            (.landed, landing, .landed), (.replaced, landing, .replaced),
            (.undoing, undone, .undoing), (.undoneGap, undone, .undoing),
        ]
        for (point, taken, state) in expected {
            let dir = try #require(taken[point], "\(point) was never reached")
            let aside = try #require(try asides(dir).first, "\(point)")
            let marks = try names(aside).filter { $0.hasPrefix(".") }
            #expect(marks == [StorePackager.committingMarker, StorePackager.statePrefix + state.rawValue], "\(point): \(marks)")
            #expect(try Data(contentsOf: aside.appendingPathComponent(StorePackager.committingMarker)).isEmpty, "\(point)")
            #expect(try StorePackager.state(of: aside) == state, "\(point)")
        }
        let staged = try #require(landing[.staged])
        #expect(try asides(staged).isEmpty)
    }

    @Test("The state is read without opening anything: a device that will not let the anchor be read still says where the read back got to")
    func readUnderALock() async throws {
        let (landing, cleanup) = try await points()
        defer { cleanup() }
        let landed = try #require(landing[.landed])
        let aside = try #require(try asides(landed).first)
        let anchor = aside.appendingPathComponent(StorePackager.committingMarker)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: anchor.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: anchor.path) }
        #expect(throws: (any Error).self) { try Data(contentsOf: anchor) }
        #expect(try StorePackager.state(of: aside) == .landed)
        // And is moved on by a rename, which needs nothing read either: the same file, renamed.
        let named = aside.appendingPathComponent(".state-landed")
        let file = try FileManager.default.attributesOfItem(atPath: named.path)[.systemFileNumber] as? Int
        try StorePackager.say(.undoing, of: aside)
        #expect(try StorePackager.state(of: aside) == .undoing)
        #expect(try FileManager.default.attributesOfItem(atPath: aside.appendingPathComponent(".state-undoing").path)[.systemFileNumber] as? Int == file)
        #expect(try names(aside).filter { $0.hasPrefix(StorePackager.statePrefix) } == [".state-undoing"])
    }

    // MARK: - A build before this one

    /// An aside as a build before this one left it: its marker saying `word`, and no state name.
    private func earlier(saying word: Data, in dir: URL) throws -> URL {
        let aside = dir.appendingPathComponent("incoming-aside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try word.write(to: aside.appendingPathComponent(StorePackager.committingMarker))
        return aside
    }

    @Test("A marker with no state name beside it is an earlier build's, and says what that build wrote in it")
    func anEarlierBuildsMarker() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let words: [(Data, State)] = [
            (Data(), .aside), (StorePackager.replacingMark, .replacing), (StorePackager.replacedMark, .replaced),
            (StorePackager.undoingMark, .undoing), (StorePackager.displacedMark, .displaced), (Data("a word nobody wrote".utf8), .aside),
        ]
        for (word, state) in words {
            let aside = try earlier(saying: word, in: dir)
            #expect(try StorePackager.state(of: aside) == state)
        }
        // What it wrote and a locked device will not let be read is not "moved aside".
        let refused = try earlier(saying: StorePackager.replacedMark, in: dir)
        let marker = refused.appendingPathComponent(StorePackager.committingMarker)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: marker.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path) }
        #expect(throws: (any Error).self) { try StorePackager.state(of: refused) }
        // No anchor at all: no commit's aside.
        let bare = dir.appendingPathComponent("incoming-aside-bare", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        #expect(try StorePackager.state(of: bare) == nil)
    }

    @Test("Where a state name is present the anchor is still read: one an earlier build wrote into since — its word wins, and no date is asked")
    func anEarlierBuildSpokeSince() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aside = dir.appendingPathComponent("incoming-aside-a", isDirectory: true)
        try StorePackager.begin(aside, as: .aside)
        try StorePackager.say(.landed, of: aside)
        #expect(try StorePackager.state(of: aside) == .landed)
        let anchor = aside.appendingPathComponent(StorePackager.committingMarker)
        // An earlier build's choice to keep the store in place: written into the anchor.
        try StorePackager.displacedMark.write(to: anchor, options: .atomic)
        #expect(try StorePackager.state(of: aside) == .displaced)
        // However old that write is made to look, it is still what the anchor says.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: anchor.path)
        #expect(try StorePackager.state(of: aside) == .displaced)
        // This build speaking after it takes the word back.
        try StorePackager.say(.undoing, of: aside)
        #expect(try StorePackager.state(of: aside) == .undoing)
        #expect(try Data(contentsOf: anchor).isEmpty)
    }

    @Test("Chosen against is said both ways — the name, and the earlier build's own word — and an earlier build emptying the anchor makes it the store to put back, whatever the clock says")
    func displacedBothWays() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aside = dir.appendingPathComponent("incoming-aside-a", isDirectory: true)
        try StorePackager.begin(aside, as: .landed)
        try StorePackager.say(.displaced, of: aside)
        let anchor = aside.appendingPathComponent(StorePackager.committingMarker)
        #expect(try Data(contentsOf: anchor) == StorePackager.displacedMark, "a build before this one reads it as it always read one")
        #expect(try names(aside) == [".committing", ".state-displaced"])
        #expect(try StorePackager.state(of: aside) == .displaced && StorePackager.wasDisplaced(aside))
        // That build makes it the store again, as it always could: an empty marker. Dated
        // before everything else here, to show that no date is what decides.
        try Data().write(to: anchor, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: anchor.path)
        #expect(try StorePackager.state(of: aside) == .aside, "the name alone does not make it chosen against")
        #expect(try !StorePackager.wasDisplaced(aside))
        // And this build making one the store again says so in both places too.
        try StorePackager.say(.displaced, of: aside)
        #expect(StorePackager.reinstate(aside))
        #expect(try StorePackager.state(of: aside) == .aside)
        #expect(try Data(contentsOf: anchor).isEmpty && names(aside) == [".committing", ".state-aside"])
    }

    @Test("A state name this build does not know, or two at once, is not a state: nothing is settled, nothing opened, and the next word said leaves one name")
    func namesThatAreNotAState() async throws {
        let (landing, cleanup) = try await points()
        defer { cleanup() }
        let dir = try #require(landing[.landed])
        let aside = try #require(try asides(dir).first)
        let before = try names(dir)
        // A build after this one wrote a name of its own.
        try FileManager.default.moveItem(at: aside.appendingPathComponent(".state-landed"), to: aside.appendingPathComponent(".state-of-a-later-build"))
        #expect(throws: StorePackager.UnknownState.self) { try StorePackager.state(of: aside) }
        #expect(StorePackager.settleHalfCommits(in: dir) == (putBack: 0, unsettled: 1))
        let opened = StoreFile.open(at: dir)
        #expect(opened.file == nil && opened.trouble == .unreachable(.outOfReach))
        #expect(try names(dir) == before, "read as 'moved aside', the old index would have gone back over the package's")
        #expect(throws: StorePackager.UnknownState.self) { try StorePackager.say(.undoing, of: aside) }
        // Two names this build does know: a move cut short by something that was no rename.
        try FileManager.default.moveItem(at: aside.appendingPathComponent(".state-of-a-later-build"), to: aside.appendingPathComponent(".state-landed"))
        try Data().write(to: aside.appendingPathComponent(".state-undoing"))
        #expect(throws: StorePackager.UnknownState.self) { try StorePackager.state(of: aside) }
        #expect(StorePackager.settleHalfCommits(in: dir) == (putBack: 0, unsettled: 1))
        // Said again, there is one name, and it is the one said — at this launch and every later one.
        try StorePackager.say(.undoing, of: aside)
        #expect(try names(aside).filter { $0.hasPrefix(".state-") } == [".state-undoing"])
        try StorePackager.say(.undoing, of: aside)
        #expect(try StorePackager.state(of: aside) == .undoing)
    }

    @Test("A build before this one, meeting any state this build writes, puts the old store back or keeps both and asks — and never deletes it")
    func whatAnEarlierBuildDoes() async throws {
        let (landing, cleanup) = try await points()
        defer { cleanup() }
        let (undone, cleanupUndone) = try await points(refusing: true)
        defer { cleanupUndone() }
        // What it decides at each point, by the trace of its own reading: an empty marker is
        // "moved aside", so it puts the old index back where nothing with posts stands in its
        // place, and keeps both where something does.
        let expected: [(StorePackager.CommitPoint, [StorePackager.CommitPoint: URL], putBack: Int, unsettled: Int)] = [
            (.movedAside, landing, 1, 0), (.replacing, landing, 1, 0), (.movedIn, landing, 0, 1),
            (.landed, landing, 0, 1), (.replaced, landing, 0, 1), (.undoing, undone, 0, 1), (.undoneGap, undone, 1, 0),
        ]
        for (point, taken, putBack, unsettled) in expected {
            let dir = try #require(taken[point], "\(point) was never reached")
            let settled = try EarlierBuild.settle(in: dir)
            #expect(settled == (putBack, unsettled), "\(point): \(settled)")
            try EarlierBuild.saved(in: dir)
            #expect(try oldStoreKept(under: dir), "\(point): a build before this one deleted the old store")
            if putBack == 1 {
                #expect(try Data(contentsOf: dir.appendingPathComponent("index.sqlite")).range(of: Self.old) != nil, "\(point)")
                #expect(try asides(dir).isEmpty, "\(point)")
            }
        }
    }

    // MARK: - Choosing between two stores

    /// Both stores and the question, as a read back killed once its index landed leaves them —
    /// with something SQLite kept beside the index in place.
    private func twoStores() async throws -> (dir: URL, cleanup: () -> Void) {
        let (landing, cleanup) = try await points()
        let dir = try #require(landing[.landed])
        for name in try names(dir) where name.hasPrefix("incoming-") && !name.hasPrefix("incoming-aside-") {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        // What the run killed there left named — its steps, and the commit's own name — has
        // been said to the person, and gone with that (`toldLeftOwed`).
        for name in try names(dir) where name.hasPrefix(StorePackager.owedPrefix) || name.hasPrefix(StorePackager.Flight.prefix) {
            try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        try Data("beside the package's index".utf8).write(to: dir.appendingPathComponent("index.sqlite-shm"))
        return (dir, cleanup)
    }

    @Test("Keeping the store in place moves the other's state on to displaced, by a rename, and it goes at the first save")
    func keepInPlace() async throws {
        let (dir, cleanup) = try await twoStores()
        defer { cleanup() }
        let aside = try #require(try asides(dir).first)
        StorePackager.choose(.keepInPlace, in: dir)
        #expect(try StorePackager.state(of: aside) == .displaced)
        #expect(try Data(contentsOf: aside.appendingPathComponent(StorePackager.committingMarker)) == StorePackager.displacedMark)
        #expect(try !StorePackager.hasUnsettledReadBack(in: dir))
        // A build before this one reads it as this one does — chosen against: kept by its
        // launch, the chosen store opened, and let go by its first save, as the person chose.
        let copy = scratch()
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: dir, to: copy)
        #expect(try EarlierBuild.settle(in: copy) == (0, 0))
        #expect(try oldStoreKept(under: copy), "its launch alone lets nothing go")
        #expect(try Data(contentsOf: copy.appendingPathComponent("index.sqlite")).range(of: Self.new) != nil)
        try EarlierBuild.saved(in: copy)
        #expect(try asides(copy).isEmpty)
        // This build opens the chosen one, and its first save lets the other go.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("index.sqlite-shm"))
        let opened = StoreFile.open(at: dir)
        let file = try #require(opened.file)
        try await file.save(sources: opened.sources, notes: opened.notes, said: opened.said)
        #expect(try asides(dir).isEmpty)
    }

    @Test("Putting the old store back moves the one in place aside index first, and a move cut short there is finished by the next launch before anything is put back")
    func putBackCutShort() async throws {
        let (dir, cleanup) = try await twoStores()
        defer { cleanup() }
        struct Killed: Error {}
        // Killed with the index moved and what SQLite kept beside it still in place.
        var moved: [String] = []
        StorePackager.choose(.putBack, in: dir) { suffix in
            moved.append(suffix)
            throw Killed()
        }
        #expect(moved == [""], "the index went first")
        let displacing = try #require(try asides(dir).first { (try? StorePackager.state(of: $0)) == .displacing })
        #expect(FileManager.default.fileExists(atPath: displacing.appendingPathComponent("index.sqlite").path))
        #expect(try names(dir).contains("index.sqlite-shm") && !names(dir).contains("index.sqlite"))
        // A build before this one never meets an aside with a journal and no index, which it
        // would remove: it meets one with its index, and deletes neither store.
        let copy = scratch()
        defer { try? FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: dir, to: copy)
        _ = try EarlierBuild.settle(in: copy)
        try EarlierBuild.saved(in: copy)
        #expect(try oldStoreKept(under: copy))
        #expect(try FileManager.default.subpathsOfDirectory(atPath: copy.path).contains { path in
            path.hasSuffix("index.sqlite") && (try? Data(contentsOf: copy.appendingPathComponent(path)))?.range(of: Self.new) != nil
        }, "nor the package's")

        // This build's next launch: no store is opened beside the gap; the move is finished —
        // what was beside the package's index follows it — and only then is the old one put back.
        #expect(StoreFile.open(at: dir).file == nil)
        #expect(StorePackager.settleHalfCommits(in: dir) == (putBack: 1, unsettled: 0))
        #expect(try StorePackager.state(of: displacing) == .displaced)
        #expect(try Data(contentsOf: displacing.appendingPathComponent("index.sqlite-shm")) == Data("beside the package's index".utf8))
        #expect(try names(dir) == [displacing.lastPathComponent, "index.sqlite"], "nothing left beside the store but the one chosen against")
        let opened = StoreFile.open(at: dir)
        #expect(opened.notes.map(\.body) == Array(repeating: "old-store-phrase", count: 5))
    }

    @Test("Putting the old store back, uninterrupted: the old one is the store, and the other is kept as chosen against until a save")
    func putBack() async throws {
        let (dir, cleanup) = try await twoStores()
        defer { cleanup() }
        StorePackager.choose(.putBack, in: dir)
        let other = try #require(try asides(dir).first)
        #expect(try asides(dir).count == 1 && StorePackager.state(of: other) == .displaced)
        #expect(try names(other).sorted() == [".committing", ".state-displaced", "index.sqlite", "index.sqlite-shm"])
        #expect(StoreFile.open(at: dir).notes.map(\.body) == Array(repeating: "old-store-phrase", count: 5))
    }

    // MARK: - A locked device

    @Test("A take-away and a read back do not begin while the canary refuses: said as a lock, and nothing is staged or moved")
    func refusedWhileLocked() async throws {
        let hand = ProtectedByHand(.refused)
        let (onto, package, packager, cleanup) = try await devices(protected: hand.protected)
        defer { cleanup() }
        let before = try names(onto.directory)
        await #expect(throws: PackageFault.locked) {
            try await packager.readBack(package, key: .password("password"), replacing: true) { _ in }
        }
        #expect(try names(onto.directory) == before)
        // The same of a take-away, on a device with its store open.
        let holding = try await Device(sources: [Self.mastodon], notes: [Self.post(1, "held")])
        defer { holding.remove() }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).fediqo")
        defer { try? FileManager.default.removeItem(at: out) }
        await #expect(throws: PackageFault.locked) {
            try await holding.packager(protected: hand.protected).takeAway(to: out, key: .password("password"), pictures: false) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        // With no canary at all nothing says it is a lock, and it is not said to be one.
        hand.turn(canary: .none)
        try await holding.packager(protected: hand.protected).takeAway(to: out, key: .password("password"), pictures: false) { _ in }
    }

    @Test("A read back that held, and could not then say the old store was replaced, does not drop it: both are kept, and a launch asks")
    func heldButNotSaid() async throws {
        var (onto, package, packager, cleanup) = try await devices()
        let folder = onto.directory
        let manager = FileManager.default
        let aside = OSAllocatedUnfairLockBox<URL?>(nil)
        defer {
            if let kept = aside.with({ $0 }) { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: kept.path) }
            cleanup()
        }
        // From the moment the index lands nothing in the aside can be renamed: the last word
        // cannot be said.
        let reached = OSAllocatedUnfairLockBox<[StorePackager.CommitPoint]>([])
        packager.witness = { point in
            reached.with { $0.append(point) }
            guard point == .landed else { return }
            let made = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.first { $0.hasPrefix("incoming-aside-") }
            guard let made else { return }
            let url = folder.appendingPathComponent(made)
            aside.with { $0 = url }
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
        }
        try await packager.readBack(package, key: .password("password"), replacing: true) { _ in }
        // The folder that will not let the name be moved will not let itself be emptied
        // either, so its still being there shows nothing by itself: what shows that nothing
        // went on to drop the old store is that the point after "replaced" was never reached.
        #expect(reached.with { $0 }.contains(.landed) && !reached.with { $0 }.contains(.replaced))
        let kept = try #require(aside.with { $0 })
        #expect(manager.fileExists(atPath: kept.appendingPathComponent("index.sqlite").path), "dropped without its having been said")
        #expect(try StorePackager.state(of: kept) == .landed)
        #expect(try oldStoreKept(under: folder))
        guard case .twoStores = StoreFile.open(at: folder).trouble else {
            Issue.record("the next launch did not ask which is the store")
            return
        }
    }

    @Test("An undo a lock refused stays owed: both stores are kept meanwhile — by a launch too — and it is done when the canary reads again")
    func anUndoOwed() async throws {
        let hand = ProtectedByHand(.reads)
        var (onto, package, packager, cleanup) = try await devices(protected: hand.protected)
        let folder = onto.directory
        let manager = FileManager.default
        var closed: URL?
        defer {
            if let closed { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: closed.path) }
            cleanup()
        }
        // The step after the index refuses; and by then the device has locked, so the undo's
        // first move — the state's rename — is refused too.
        let blocking = folder.appendingPathComponent(LimitAccountFile.name, isDirectory: true)
        try manager.createDirectory(at: blocking, withIntermediateDirectories: true)
        try Data().write(to: blocking.appendingPathComponent("in the way"))
        let aside = OSAllocatedUnfairLockBox<URL?>(nil)
        packager.witness = { point in
            guard point == .landed else { return }
            let made = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.first { $0.hasPrefix("incoming-aside-") }
            guard let made else { return }
            let url = folder.appendingPathComponent(made)
            aside.with { $0 = url }
            try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
            hand.turn(canary: .refused)
        }
        await #expect(throws: PackageFault.unwound(steps: ["index"])) {
            try await packager.readBack(package, key: .password("password"), replacing: true) { _ in }
        }
        let kept = try #require(aside.with { $0 })
        closed = kept
        #expect(packager.owesUndo)
        #expect(StorePackager.owedNames(in: folder) == ["index"], "said beside the index, by a name")
        #expect(packager.leftOwed().isEmpty, "this run still holds the undo: nothing is left to another")
        // The sweep of a launch does not take the name for a leftover.
        StorePackager.sweepLeftovers(directory: scratch(), media: nil, temporary: scratch())
        #expect(try StorePackager.state(of: kept) == .landed, "nothing was said that was not done")
        #expect(try oldStoreKept(under: folder))
        #expect(try Data(contentsOf: folder.appendingPathComponent("index.sqlite")).range(of: Self.new) != nil)
        // Asked while the canary still refuses, it stays owed and nothing is tried — even
        // though by now nothing in the folder itself would stop it — and nothing more may begin.
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: kept.path)
        #expect(await packager.finishOwed() == false)
        #expect(try StorePackager.state(of: kept) == .landed, "tried behind a canary that refuses")
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: kept.path)
        await #expect(throws: PackageFault.locked) {
            try await packager.readBack(package, key: .password("password"), replacing: true) { _ in }
        }
        // Should the process die here, the next launch keeps both stores and asks.
        let copy = scratch()
        defer {
            if let aside = try? asides(copy).first { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: aside.path) }
            try? manager.removeItem(at: copy)
        }
        try manager.copyItem(at: folder, to: copy)
        #expect(StorePackager.settleHalfCommits(in: copy).unsettled == 1)
        guard case .twoStores = StoreFile.open(at: copy).trouble else {
            Issue.record("a launch after the lock did not keep both stores and ask")
            return
        }
        #expect(try oldStoreKept(under: copy))
        // **While the run that owes it lives, it is nobody else's to say**: another packager
        // on the folder — another copy of the app — finds the commit's own name held.
        #expect(onto.packager(protected: ProtectedData.always).leftOwed().isEmpty)
        // **The process dies with it owed** — the folder as it stands, with nobody holding
        // the commit's name. The next run holds no undo — what was to be put back was in that
        // run's memory — and finds the name: it is said, in the sentence the person was given
        // at the time, and nothing begins until it has been.
        let next = StorePackager(
            directory: copy, file: nil, store: ItemStore(sources: [], notes: []), media: nil, tokens: onto.tokens,
            credentials: onto.credentials, defaults: onto.defaults, device: "a test", appVersion: "0.7.0",
            protected: .always, freeSpace: { _ in .max }, rounds: 1000
        )
        #expect(next.leftOwed() == ["index"] && !next.owesUndo)
        await #expect(throws: PackageFault.unwound(steps: ["index"])) {
            try await next.readBack(package, key: .password("password"), replacing: true) { _ in }
        }
        #expect(next.leftOwed().isEmpty && StorePackager.owedNames(in: copy).isEmpty, "told, and so no longer kept to be said")
        #expect(try !names(copy).contains { $0.hasPrefix(StorePackager.Flight.prefix) }, "and the name of the commit that left it goes with it")
        try Guarded.write(Data(), to: copy.appendingPathComponent(".owed-index"), atomic: false)
        #expect(next.leftOwed().isEmpty, "said once in a run, whether or not its name could be removed")
        // Unlocked, and the step still failing for a reason that is no lock: said as what is
        // not put back, and not as a locked device.
        hand.turn(canary: .reads)
        await #expect(throws: PackageFault.unwound(steps: ["index"])) {
            try await packager.readBack(package, key: .password("password"), replacing: true) { _ in }
        }
        #expect(packager.owesUndo)
        // And with nothing in its way: what was owed is done — the device as it was.
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: kept.path)
        #expect(await packager.finishOwed())
        #expect(!packager.owesUndo)
        #expect(StorePackager.owedNames(in: folder).isEmpty, "its name goes as the step is done")
        #expect(try !names(folder).contains { $0.hasPrefix(StorePackager.Flight.prefix) }, "and the commit's own, with nothing owed any more")
        #expect(try asides(folder).isEmpty)
        #expect(try Data(contentsOf: folder.appendingPathComponent("index.sqlite")).range(of: Self.old) != nil)
    }
}

/// A value several closures write, one at a time.
final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
