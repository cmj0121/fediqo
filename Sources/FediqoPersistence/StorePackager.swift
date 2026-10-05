import FediqoCore
import Foundation

/// The real `StoreCarrier` (#247): what this device holds, taken away as one `FDQ1` package and
/// read back from one.
///
/// **What rides.** The index as one SQLite file, written fresh from the store's snapshot into a
/// scratch folder so the live file is never read raw; every `fediqo.` default as a plist; what
/// signs in — tokens, app registrations, forum credentials — as JSON, the only place they ride;
/// and, where the person chose, every picture copy on disk. Each is one entry of the package,
/// and adding a kind is one line in `pieces(pictures:)`.
///
/// **Read back is staged, then committed.** Every entry is decrypted into
/// `incoming-<uuid>/` under the store's own folder with its tags checked and the footer seen,
/// and the staged index is opened as a store — a `Newer` there is `.newer` — before anything on
/// this device changes. Only then the commit, each step undone if a later one refuses: the
/// Keychain first, with what it held read and put back; the index, with what it held read and
/// written back; the picture copies, put aside and put back; the defaults, read and set back;
/// and the store in memory last, which nothing follows. A failure anywhere leaves the device as
/// it was, and the staging goes.
///
/// **Nothing here reaches off this device**, and the shell records each call under "this
/// device" in the run's list.
///
/// `@unchecked` for one member: `UserDefaults`, which Foundation documents as thread-safe and
/// does not mark. Everything else here is `Sendable` on its own.
public struct StorePackager: StoreCarrier, @unchecked Sendable {
    /// How a `fediqo.` default is told apart from every other key in the domain.
    static let defaultsPrefix = "fediqo."
    static let indexName = "index.sqlite"

    private let directory: URL
    private let file: StoreFile?
    private let store: ItemStore
    private let media: MediaCache?
    private let tokens: any MastodonTokenStore
    private let credentials: any ForumCredentialStore
    private let defaults: UserDefaults
    private let device: String
    private let appVersion: String
    private let freeSpace: @Sendable (URL) -> Int
    private let rounds: UInt32
    /// The one writer of the index this run, where there is one: the commit runs inside its
    /// queue, so no save writes the old snapshot over the new index.
    private let saver: StoreSaver?
    /// The index on disk was written by a newer build and this run left it alone: a read back
    /// must not write over it.
    private let storeIsNewer: Bool
    /// This run did not open the store on disk — in use, out of reach, or one of two (#295). A
    /// read back that would replace it is refused, as a newer build's is, and a take-away has
    /// nothing to take.
    private let storeNotOpened: Bool
    /// Told as a read back's commit passes each point a run killed there would leave on disk.
    /// Nothing in the app sets it: a test does, to copy the folder as it stands at that point.
    var witness: (@Sendable (CommitPoint) -> Void)?

    /// Where a read back that moves its index into place can be stopped, and what is then on
    /// disk (`settleHalfCommits`).
    enum CommitPoint: Sendable {
        /// The package's index is staged and proven; nothing of this device's has moved.
        case staged
        /// The old index is aside, with its marker saying so; the new one is not in place.
        case movedAside
        /// The marker says the new index is on its way in; it has not been moved yet.
        case replacing
        /// The new index is in place and the marker still says it is on its way in.
        case movedIn
        /// The new index is in place and the marker says the old one was replaced.
        case replaced
        /// A later step refused: the marker says the commit is being undone; the new index is
        /// still in place.
        case undoing
        /// Being undone, the new index taken out and the old one not yet back.
        case undoneGap
    }

    /// `directory` is where the index lives; `file` is the index as this run opened it, or nil
    /// where this run has none to write (then the staged index is moved into place instead).
    /// `freeSpace` and `rounds` are for tests; the app takes the defaults.
    public init(
        directory: URL, file: StoreFile?, store: ItemStore, media: MediaCache?,
        tokens: any MastodonTokenStore, credentials: any ForumCredentialStore,
        defaults: UserDefaults, device: String, appVersion: String, storeIsNewer: Bool = false,
        storeNotOpened: Bool = false, saver: StoreSaver? = nil,
        freeSpace: @escaping @Sendable (URL) -> Int = StorePackager.volumeFree,
        rounds: UInt32 = PackageFormat.rounds
    ) {
        self.directory = directory
        self.file = file
        self.saver = saver
        self.storeIsNewer = storeIsNewer
        self.storeNotOpened = storeNotOpened
        self.store = store
        self.media = media
        self.tokens = tokens
        self.credentials = credentials
        self.defaults = defaults
        self.device = device
        self.appVersion = appVersion
        self.freeSpace = freeSpace
        self.rounds = rounds
    }

    /// Removes what a run that ended midway left behind: a take-away's scratch folder in the
    /// temporary directory, a read back's staging under the store's folder, and the copies put
    /// aside while a package's were moved in. Each holds a plaintext index or the pictures, and
    /// none is anything a later run reads. Asked at launch, before the first frame.
    public static func sweepLeftovers(
        directory: URL, media: URL?, temporary: URL = FileManager.default.temporaryDirectory
    ) {
        let manager = FileManager.default
        func sweep(_ folder: URL, prefix: String) {
            let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasPrefix(prefix) {
                try? manager.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        sweep(temporary, prefix: "takeaway-")
        // A read back killed midway is settled first, one way or the other, so that the index
        // this run opens is either the one this device held or the one the package brought —
        // never an empty one made in the gap between them. Only then does what is left of a
        // staging go: by now nothing under `incoming-` without a marker is the only copy of
        // anything.
        let settled = settleHalfCommits(in: directory)
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("incoming-") {
            let folder = directory.appendingPathComponent(name)
            // One that could not be settled keeps its marker, and is kept: see `settleHalfCommits`.
            if manager.fileExists(atPath: folder.appendingPathComponent(committingMarker).path) { continue }
            try? manager.removeItem(at: folder)
        }
        StoreSaver.reportHalfCommits(putBack: settled.putBack, unsettled: settled.unsettled)
        if let media { sweep(media.deletingLastPathComponent(), prefix: "media-aside-") }
    }

    /// The file in an `incoming-aside-*` folder that says its commit has not finished, and how
    /// far it got: empty while the old index is moved aside, `replacingMark` from just before
    /// the package's index is moved in, `replacedMark` once it is in place, and `undoingMark`
    /// once a later step refused and the commit is being taken back.
    static let committingMarker = ".committing"
    /// What the marker holds from just before the new index is moved to where the old one was,
    /// until it says `replacedMark`: an index in place, if there is one, is the package's, and
    /// the commit did not get as far as saying so.
    static let replacingMark = Data("replacing".utf8)
    /// What the marker holds once the new index is where the old one was.
    static let replacedMark = Data("replaced".utf8)
    /// What the marker holds from the moment a commit that had replaced the index is undone:
    /// the index in place, if there is one, is the package's and on its way out.
    static let undoingMark = Data("undoing".utf8)

    /// What the marker holds once the person has chosen against the store in its folder (#295):
    /// of two stores a read back left, this is the one that is not the store. It is never put
    /// back, it stands in nobody's way, and it goes once the chosen one has opened and saved
    /// (`StoreFile.dropWhatWasReplaced`).
    static let displacedMark = Data("displaced".utf8)

    /// Whether `aside` holds a store the person chose against.
    static func wasDisplaced(_ aside: URL) -> Bool {
        (try? Data(contentsOf: aside.appendingPathComponent(committingMarker))) == displacedMark
    }

    /// Whether the old index in `aside` was replaced — the package's index is in its place —
    /// rather than only moved out of the way.
    ///
    /// **The marker's word, and an index standing where the old one was** (`directory`). The
    /// marker alone is not enough: one that says replaced beside no index at all is a commit
    /// whose new index has gone again, and the aside is then the only store there is. And an
    /// index found in place is not enough without the marker: any run that opened this folder
    /// in between would have made one.
    static func wasReplaced(_ aside: URL, in directory: URL) -> Bool {
        (try? Data(contentsOf: aside.appendingPathComponent(committingMarker))) == replacedMark
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent(indexName).path)
    }

    /// Whether `directory` holds a read back's old index that is neither replaced nor put back:
    /// an aside with its marker that `settleHalfCommits` has not settled — not asked yet, or
    /// could not. **While there is one, no index is opened or made here** (`StoreFile.open`):
    /// the store this device held is aside, and a fresh index made beside it would collect what
    /// a run reads only to be thrown away, or stand in the old one's way, the day it is put back.
    static func hasUnsettledReadBack(in directory: URL) -> Bool {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { name in
            guard name.hasPrefix(StoreFile.readBackAsidePrefix) else { return false }
            let aside = directory.appendingPathComponent(name)
            return manager.fileExists(atPath: aside.appendingPathComponent(committingMarker).path)
                && !wasReplaced(aside, in: directory) && !wasDisplaced(aside)
        }
    }

    /// The first aside in `directory` that is neither replaced, displaced nor put back.
    private static func unsettledAside(in directory: URL) -> URL? {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.sorted().lazy.filter { $0.hasPrefix(StoreFile.readBackAsidePrefix) }
            .map { directory.appendingPathComponent($0) }
            .first { aside in
                manager.fileExists(atPath: aside.appendingPathComponent(committingMarker).path)
                    && !wasReplaced(aside, in: directory) && !wasDisplaced(aside)
            }
    }

    /// What an unsettled read back in `directory` is to the person (#295), or nothing where
    /// there is none: two stores to choose between, where an index stands in the old one's
    /// place — with what can be said of each without opening it to write — and otherwise a
    /// store that could not be put back.
    static func unsettledReadBack(in directory: URL) -> StoreTrouble? {
        guard let aside = unsettledAside(in: directory) else { return nil }
        let inPlace = directory.appendingPathComponent(indexName)
        guard FileManager.default.fileExists(atPath: inPlace.path) else { return .unreachable(.readBackInterrupted) }
        return .twoStores(
            inPlace: StoreGlance.of(indexAt: inPlace),
            setAside: StoreGlance.of(indexAt: aside.appendingPathComponent(indexName))
        )
    }

    /// Which of two stores a read back left is the store.
    public enum Choice: Sendable {
        /// The one where the store belongs.
        case keepInPlace
        /// The one the read back moved out of the way.
        case putBack
    }

    /// The person's choice between two stores (#295), written down in `directory`.
    ///
    /// **The store not chosen is not deleted here**, and not by the next launch either: it is
    /// marked displaced, and goes only after the chosen one has opened and saved
    /// (`StoreFile.dropWhatWasReplaced`). Should the chosen one turn out damaged, it comes back
    /// (`reinstateDisplaced`).
    ///
    /// - **Keep the one in place**: the aside's marker is rewritten, whole or not at all, to say
    ///   displaced. Nothing moves.
    /// - **Put back the one set aside**: the one in place is moved into an aside of its own,
    ///   marked displaced before anything moves — what SQLite kept beside it first, the index
    ///   last, so that the aside holds the index only once it holds all of it. Then the old one
    ///   is put back the way a launch puts one back (`settleHalfCommits`), there being nothing
    ///   in its place now. A step that fails leaves a state a launch settles or asks about again.
    public static func choose(_ choice: Choice, in directory: URL) {
        let manager = FileManager.default
        guard let aside = unsettledAside(in: directory) else { return }
        switch choice {
        case .keepInPlace:
            try? displacedMark.write(to: aside.appendingPathComponent(committingMarker), options: .atomic)
        case .putBack:
            let other = directory.appendingPathComponent("\(StoreFile.readBackAsidePrefix)\(UUID().uuidString)", isDirectory: true)
            do {
                try manager.createDirectory(at: other, withIntermediateDirectories: true)
                try displacedMark.write(to: other.appendingPathComponent(committingMarker))
                for suffix in StoreFile.sidecars + [""] {
                    let stands = directory.appendingPathComponent(indexName + suffix)
                    guard manager.fileExists(atPath: stands.path) else { continue }
                    try manager.moveItem(at: stands, to: other.appendingPathComponent(indexName + suffix))
                }
            } catch {
                return
            }
            _ = settleHalfCommits(in: directory)
        }
    }

    /// Makes a store the person chose against the store to put back again (#295), where there is
    /// one: its marker goes back to saying only that it was moved out of the way. Asked when the
    /// store they chose instead proves damaged, before anything is made in its place. Whether
    /// there was one.
    static func reinstateDisplaced(in directory: URL) -> Bool {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where name.hasPrefix(StoreFile.readBackAsidePrefix) {
            let aside = directory.appendingPathComponent(name)
            guard wasDisplaced(aside), manager.fileExists(atPath: aside.appendingPathComponent(indexName).path) else { continue }
            guard (try? Data().write(to: aside.appendingPathComponent(committingMarker), options: .atomic)) != nil else { continue }
            return true
        }
        return false
    }

    /// Settles every read back a run was killed in the middle of (#247, #292), before any index
    /// is opened: how many were put back as they were, and how many could not be settled.
    ///
    /// A commit that moves its index into place passes these points a kill can leave on disk:
    ///
    /// - **Staged**, nothing moved. There is no aside; the staging is swept like any other.
    /// - **The old index aside, the new one not in place** — the marker is there and empty.
    ///   *The read back did not happen.* The old index is moved back to where it was, with what
    ///   SQLite kept beside it. The device is as it was.
    /// - **The new index on its way in** — the marker says `replacingMark`. The index in place,
    ///   if it got there, is the package's, and the commit never said it had replaced anything:
    ///   it goes, and the old one is moved back. The read back is asked again.
    /// - **The new index in place** — the marker says `replacedMark` and an index stands there.
    ///   The package's index is the store, and the old one, replaced, is dropped with its marker.
    /// - **Being undone** — a later step refused, and the marker says `undoingMark`. The index in
    ///   place, if it is still there, is the package's and was on its way out: it goes, and the
    ///   old one is moved back.
    ///
    /// So a kill between the new index landing and the marker saying replaced is the third, by
    /// the marker's own word, and not an empty marker beside an index with rows in it — which
    /// only ever means an index some other run made. That is the side to err on.
    ///
    /// **Nothing here, and nothing after it, deletes an old index that was not replaced** — and
    /// replaced means the marker says so *and* an index stands in its place. A marker saying
    /// replaced beside no index is put back like any other.
    ///
    /// **An index standing in the old one's place goes only if it holds nothing**, where the
    /// marker is empty — where it says the index in place is the package's, it goes whatever it
    /// holds: an index a run made for want of one, with no source and no post in it.
    /// One that holds anything is somebody's reading, and which of the two is the store is not
    /// this function's to guess — both are kept, nothing is changed, and it is counted as
    /// unsettled. So is an aside the system would not let be moved back.
    ///
    /// **While one is unsettled this run has no index at all** (`hasUnsettledReadBack`), and
    /// every launch tries again.
    ///
    /// **Put back so that a second kill costs nothing.** What stands in the old index's place
    /// goes first; then what SQLite kept beside the old index comes back; the index itself comes
    /// back last. Until that last move the aside still holds the index, so a launch that finds
    /// it half done does the rest — and what is already back beside the gap is the old index's,
    /// and is left.
    static func settleHalfCommits(in directory: URL) -> (putBack: Int, unsettled: Int) {
        let manager = FileManager.default
        var putBack = 0
        var unsettled = 0
        let target = directory.appendingPathComponent(indexName)
        let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where name.hasPrefix(StoreFile.readBackAsidePrefix) {
            let aside = directory.appendingPathComponent(name)
            let marker = aside.appendingPathComponent(committingMarker)
            guard manager.fileExists(atPath: marker.path) else { continue }
            if wasReplaced(aside, in: directory) {
                try? manager.removeItem(at: aside)
                continue
            }
            if wasDisplaced(aside) {
                // A store the person chose against (#295): kept, untouched, until the one they
                // chose has opened and saved. One that never came to hold its index — a choice
                // cut short while the index in place was being moved in — hands back what it
                // took from beside that index and goes; the choice is then asked again.
                if !manager.fileExists(atPath: aside.appendingPathComponent(indexName).path) {
                    for suffix in StoreFile.sidecars {
                        let taken = aside.appendingPathComponent(indexName + suffix)
                        let home = directory.appendingPathComponent(indexName + suffix)
                        if manager.fileExists(atPath: taken.path), !manager.fileExists(atPath: home.path) {
                            try? manager.moveItem(at: taken, to: home)
                        }
                    }
                    try? manager.removeItem(at: aside)
                }
                continue
            }
            guard manager.fileExists(atPath: aside.appendingPathComponent(indexName).path) else {
                // The marker was written and the index never left, or is already back: there
                // is nothing to put back.
                try? manager.removeItem(at: aside)
                continue
            }
            // Whether the marker says whose the index in place is: the package's, on its way in
            // or on its way out.
            let word = try? Data(contentsOf: marker)
            let thePackages = word == replacingMark || word == undoingMark
            if manager.fileExists(atPath: target.path), !thePackages, StoreFile.holdsNothing(indexAt: target.path) != true {
                unsettled += 1
                continue
            }
            do {
                if manager.fileExists(atPath: target.path) {
                    for suffix in [""] + StoreFile.sidecars {
                        let stands = directory.appendingPathComponent(indexName + suffix)
                        if manager.fileExists(atPath: stands.path) { try manager.removeItem(at: stands) }
                    }
                }
                for suffix in StoreFile.sidecars + [""] {
                    let kept = aside.appendingPathComponent(indexName + suffix)
                    guard manager.fileExists(atPath: kept.path) else { continue }
                    try manager.moveItem(at: kept, to: directory.appendingPathComponent(indexName + suffix))
                }
                try manager.removeItem(at: aside)
                putBack += 1
            } catch {
                unsettled += 1
            }
        }
        return (putBack, unsettled)
    }

    /// What the volume under `url` has free for what matters.
    public static func volumeFree(_ url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int(clamping: $0) } ?? 0
    }

    // MARK: - Weighing

    public func weigh() async throws -> PackageWeight {
        // The figure Usage shows (#194), where this run has the index open; the file's size where
        // it does not.
        let index = file?.bytesOnDisk() ?? StoreFile.bytesOnDisk(indexAt: directory.appendingPathComponent(Self.indexName).path)
        let settings = (try? settingsPlist().count) ?? 0
        let pictures = media?.totalBytes() ?? 0
        let held = await holdsStore()
        return PackageWeight(
            withoutPictures: index + settings, withPictures: index + settings + pictures,
            free: freeSpace(directory), holdsStore: held
        )
    }

    /// Whether this device holds a store a read back would replace: a source in memory, or an
    /// index on disk this run could not open — a newer build's, or one it left as found.
    private func holdsStore() async -> Bool {
        if await !store.sources().isEmpty { return true }
        return file == nil && FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.indexName).path)
    }

    // MARK: - Taking away

    /// One entry as it will be written: what it is, and where its bytes come from.
    struct Piece {
        enum Body {
            case file(URL)
            case data(Data)
        }

        let kind: PackageFormat.Entry.Kind
        let name: String
        let body: Body
        let bytes: Int

        init(_ kind: PackageFormat.Entry.Kind, name: String, data: Data) {
            self.kind = kind
            self.name = name
            body = .data(data)
            bytes = data.count
        }

        init(_ kind: PackageFormat.Entry.Kind, name: String, file: URL, bytes: Int) {
            self.kind = kind
            self.name = name
            body = .file(file)
            self.bytes = bytes
        }
    }

    public func stagingFolder() -> URL { directory }

    public func takeAway(
        to url: URL, key: PackageKey, pictures: Bool, contents: PackageSummary.Contents,
        progress: @escaping @Sendable (PackageProgress) -> Void
    ) async throws {
        // A run that did not open this device's store holds none of it: what it would take away
        // is an empty store under this device's name, which is not what the person asked for.
        if storeNotOpened || storeIsNewer { throw PackageFault.nothingToTake }
        if case .password(let password) = key {
            if password.isEmpty { throw PackageFault.emptyPassword }
            if password.count < PackageFormat.minPasswordCount { throw PackageFault.shortPassword }
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeaway-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let snapshot = await store.snapshot()
        let pieces: [Piece]
        let sources: [PackageSummary.SourceLine]
        switch contents {
        case .whole:
            let staged = try StoreFile(at: scratch)
            try await staged.save(sources: snapshot.sources, notes: snapshot.notes, said: snapshot.said)
            pieces = try self.pieces(
                index: scratch.appendingPathComponent(Self.indexName), sources: snapshot.sources.map(\.host),
                said: snapshot.said, pictures: pictures
            )
            sources = snapshot.sources.map { .init(host: $0.host, kind: $0.kind) }
        case .signInsOnly:
            // Only what signs in (#6): the one entry, and the header names the sources it
            // signs in to and nothing else.
            let held = try secrets(sources: snapshot.sources.map(\.host))
            pieces = [Piece(.secrets, name: "secrets", data: held.isEmpty ? Data() : try JSONEncoder().encode(held))]
            let hosts = Set(held.mastodon.map(\.host) + held.apps.map(\.host) + held.forums.map(\.host))
            sources = snapshot.sources.filter { hosts.contains($0.host) }.map { .init(host: $0.host, kind: $0.kind) }
        }
        let total = pieces.reduce(0) { $0 + $1.bytes }
        let summary = PackageSummary(
            contents: contents, sources: sources,
            posts: contents == .whole ? snapshot.notes.count : 0,
            timelines: contents == .whole ? timelinesKept() : 0, takenAt: Date(),
            withPictures: pictures && contents == .whole,
            bytes: total, hasSecrets: pieces.contains { $0.kind == .secrets && $0.bytes > 0 },
            device: device, appVersion: appVersion, entryCount: pieces.count,
            kept: contents == .whole ? snapshot.notes.filter(\.kept).count : nil
        )
        try? FileManager.default.removeItem(at: url)
        let writer = try PackageWriter(to: url, key: key, summary: summary, rounds: rounds)
        var done = 0
        for piece in pieces {
            try Task.checkCancellation()
            switch piece.body {
            case .data(let data):
                var offset = 0
                try writer.add(piece.kind, name: piece.name, bytes: piece.bytes) { most in
                    guard offset < data.count else { return nil }
                    let end = min(data.count, offset + most)
                    defer { offset = end }
                    return data[offset..<end]
                }
            case .file(let file):
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                try writer.add(piece.kind, name: piece.name, bytes: piece.bytes) { most in
                    let read = try handle.read(upToCount: most)
                    return read?.isEmpty == true ? nil : read
                }
            }
            done += piece.bytes
            progress(PackageProgress(done: done, total: total))
        }
        try writer.finish()
    }

    /// Every entry of a take-away, in the order they ride. **Adding a kind is one line here.**
    private func pieces(index: URL, sources: [String], said: [SourceProfile], pictures: Bool) throws -> [Piece] {
        let indexBytes = try index.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var pieces: [Piece] = [
            Piece(.store, name: Self.indexName, file: index, bytes: indexBytes),
            Piece(.settings, name: "settings", data: try settingsPlist()),
            Piece(.secrets, name: "secrets", data: try secretsJSON(sources: sources)),
            Piece(.limits, name: Self.limitsName, data: limitsJSON()),
        ]
        // What each source last said about itself (#188), one entry a host, so a build that
        // keeps them elsewhere than the index still finds them.
        pieces += try said.sorted { $0.host < $1.host }.map {
            Piece(.profile, name: $0.host, data: try JSONEncoder().encode(ProfileWire($0)))
        }
        if pictures, let media {
            pieces += media.copies().map { Piece(.picture, name: "\($0.folder)/\($0.name)", file: $0.url, bytes: $0.size) }
        }
        return pieces
    }

    /// How many timelines the person wrote, read off their default as the timeline store keeps
    /// it — a count for the header, never the rules themselves.
    private func timelinesKept() -> Int {
        guard let data = defaults.data(forKey: "fediqo.timelines"),
              let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = top["timelines"] as? [Any]
        else { return 0 }
        return rows.count
    }

    /// Every `fediqo.` default, as a plist.
    private func settingsPlist() throws -> Data {
        let kept = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(Self.defaultsPrefix) }
        return try PropertyListSerialization.data(fromPropertyList: kept, format: .xml, options: 0)
    }

    // MARK: - Secrets

    /// What signs in, as it rides. The one place a token or a password becomes bytes outside the
    /// Keychain, and it goes straight into a sealed entry.
    struct Secrets: Codable, Equatable {
        struct Token: Codable, Equatable {
            var host: String
            var accessToken: String
            var clientID: String
            var clientSecret: String
            var scopes: String?
        }

        struct App: Codable, Equatable {
            var host: String
            var clientID: String
            var clientSecret: String
            var scopes: String?
        }

        struct Forum: Codable, Equatable {
            var host: String
            var username: String
            var password: String
        }

        var mastodon: [Token] = []
        var apps: [App] = []
        var forums: [Forum] = []

        var isEmpty: Bool { mastodon.isEmpty && apps.isEmpty && forums.isEmpty }
    }

    /// Everything the Keychain holds for this app, read once. Hosts with a token, and every
    /// source's registration, and every forum with a password.
    private func secrets(sources: [String]) throws -> Secrets {
        var out = Secrets()
        let signedIn = try tokens.signedInHosts()
        for host in signedIn.sorted() {
            guard let token = try tokens.token(host: host) else { continue }
            out.mastodon.append(.init(
                host: token.host, accessToken: token.accessToken, clientID: token.clientID,
                clientSecret: token.clientSecret, scopes: token.scopes
            ))
        }
        for host in Set(sources).union(signedIn).sorted() {
            guard let app = try tokens.app(host: host) else { continue }
            out.apps.append(.init(host: app.host, clientID: app.clientID, clientSecret: app.clientSecret, scopes: app.scopes))
        }
        for host in try credentials.savedHosts().sorted() {
            guard let credential = try credentials.credential(host: host) else { continue }
            out.forums.append(.init(host: credential.host, username: credential.username, password: credential.password))
        }
        return out
    }

    /// Nothing at all where nothing signs in, so the header can say so.
    private func secretsJSON(sources: [String]) throws -> Data {
        let held = try secrets(sources: sources)
        guard !held.isEmpty else { return Data() }
        return try JSONEncoder().encode(held)
    }

    /// Files `fresh` in the Keychain in place of whatever is there — or, where `onlyTheirs`, in
    /// place of what is there for the package's hosts and nothing else (#6). Where a save
    /// refuses, what was there is put back, so the Keychain is as it was or as the package says.
    /// Hands back what was there, for a later step that refuses to put back the same way.
    private func refile(_ fresh: Secrets, onlyTheirs: Bool) throws -> Secrets {
        var previous = try secrets(sources: fresh.apps.map(\.host))
        if onlyTheirs {
            let hosts = Set(fresh.mastodon.map(\.host) + fresh.apps.map(\.host) + fresh.forums.map(\.host))
            previous.mastodon.removeAll { !hosts.contains($0.host) }
            previous.apps.removeAll { !hosts.contains($0.host) }
            previous.forums.removeAll { !hosts.contains($0.host) }
        }
        do {
            try clearSecrets(previous)
            try clearSecrets(fresh)
            try fileSecrets(fresh)
        } catch {
            try? clearSecrets(fresh)
            try? fileSecrets(previous)
            throw error
        }
        return previous
    }

    /// `fresh` taken out and `previous` put back: the Keychain as it was before `refile`, or a
    /// throw where it could not be.
    private func unfile(_ fresh: Secrets, previous: Secrets) throws {
        try clearSecrets(fresh)
        try fileSecrets(previous)
    }

    private func clearSecrets(_ secrets: Secrets) throws {
        for token in secrets.mastodon { try tokens.forget(host: token.host) }
        for app in secrets.apps { try tokens.forgetApp(host: app.host) }
        for forum in secrets.forums { try credentials.forget(host: forum.host) }
    }

    private func fileSecrets(_ secrets: Secrets) throws {
        for token in secrets.mastodon {
            try tokens.save(MastodonToken(
                host: token.host, accessToken: token.accessToken, clientID: token.clientID,
                clientSecret: token.clientSecret, scopes: token.scopes
            ))
        }
        for app in secrets.apps {
            try tokens.save(MastodonApp(host: app.host, clientID: app.clientID, clientSecret: app.clientSecret, scopes: app.scopes))
        }
        for forum in secrets.forums {
            let credential = ForumCredential(host: forum.host, username: forum.username, password: forum.password)
            guard credential.isComplete else { continue }
            try credentials.save(credential)
        }
    }

    /// `SourceProfile` as a profile entry carries it (#188): every field the page draws, and
    /// when it was said. A kind this build cannot name reads as no word, as the index reads it.
    struct ProfileWire: Codable {
        var kind: String
        var title: String?
        var summary: String?
        var thumbnail: URL?
        var activeMonth: Int?
        var statusLimit: Int?
        var people: Int?
        var posts: Int?
        var registration: String?
        var readsWithoutAccount: Bool?
        var rules: [String]
        var asOf: Date?

        init(_ profile: SourceProfile) {
            kind = profile.kind.rawValue
            title = profile.title
            summary = profile.summary
            thumbnail = profile.thumbnail
            activeMonth = profile.activeMonth
            statusLimit = profile.statusLimit
            people = profile.people
            posts = profile.posts
            registration = profile.registration?.rawValue
            readsWithoutAccount = profile.readsWithoutAccount
            rules = profile.rules
            asOf = profile.asOf
        }

        func profile(host: String) -> SourceProfile? {
            guard let kind = ProtocolKind(rawValue: kind), kind != .unknown, let asOf else { return nil }
            return SourceProfile(
                host: host, kind: kind, title: title, summary: summary, thumbnail: thumbnail,
                activeMonth: activeMonth, statusLimit: statusLimit, people: people, posts: posts,
                registration: registration.flatMap(SourceProfile.Registration.init(rawValue:)),
                readsWithoutAccount: readsWithoutAccount, rules: rules, asOf: asOf
            )
        }
    }

    // MARK: - Reading back

    public func preview(_ url: URL, key: PackageKey) async throws -> PackageSummary {
        try PackageReader(at: url).open(with: key)
    }

    /// What a read back staged, before the commit.
    /// `@unchecked` for the settings plist, whose values are Foundation value types.
    private struct Staged: @unchecked Sendable {
        var index: URL?
        var settings: [String: Any]?
        var secrets: Secrets?
        var media: URL?
        var pictures = 0
        var said: [SourceProfile] = []
        var limits: Data?
    }

    static let limitsName = "limits"

    /// The limits' account beside the index (#251) as it is, or an empty account where there is
    /// none: it rides with the store it is about, so the lines still say what went from it.
    private func limitsJSON() -> Data {
        (try? Data(contentsOf: directory.appendingPathComponent(LimitAccountFile.name))) ?? Data("[]".utf8)
    }

    /// The account replaced by the package's, with what was there read first and put back on
    /// a refusal. Only where the package carried the store: a package of secrets alone says
    /// nothing about what this device's limits let go.
    private func commitLimits(_ staged: Staged, into undo: inout [Undo]) throws {
        guard let data = staged.limits else { return }
        let target = directory.appendingPathComponent(LimitAccountFile.name)
        let previous = try? Data(contentsOf: target)
        try data.write(to: target, options: .atomic)
        undo.append(Undo(name: "limits") {
            if let previous { try previous.write(to: target, options: .atomic) } else { try? FileManager.default.removeItem(at: target) }
        })
    }

    public func readBack(
        _ url: URL, key: PackageKey, replacing: Bool, progress: @escaping @Sendable (PackageProgress) -> Void
    ) async throws {
        let reader = try PackageReader(at: url)
        let summary = try reader.open(with: key)
        if storeIsNewer, summary.contents == .whole { throw PackageFault.indexIsNewer }
        if storeNotOpened, summary.contents == .whole { throw PackageFault.storeNotOpened }
        let held = await holdsStore()
        if held, !replacing, summary.contents == .whole { throw PackageFault.alreadyHeld }
        // Twice the package: the staging, and what is moved into place beside what was there
        // until the last step holds.
        let free = freeSpace(directory)
        let needed = reader.prelude.bytes * 2
        if free < needed { throw PackageFault.noRoom(needed: needed, free: free) }

        let manager = FileManager.default
        let incoming = directory.appendingPathComponent("incoming-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: incoming) }
        var staged = Staged()
        var done = 0
        let total = reader.prelude.bytes
        for try await entry in reader.entries() {
            try Task.checkCancellation()
            switch entry.kind {
            case .store:
                guard entry.name == Self.indexName, staged.index == nil else { throw PackageRefusal.altered }
                let target = incoming.appendingPathComponent(Self.indexName)
                try await Self.write(entry, to: target)
                staged.index = target
            case .settings:
                guard staged.settings == nil else { throw PackageRefusal.altered }
                let data = try await Self.whole(entry)
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let dictionary = plist as? [String: Any]
                else { throw PackageRefusal.altered }
                staged.settings = dictionary.filter { $0.key.hasPrefix(Self.defaultsPrefix) }
            case .secrets:
                guard staged.secrets == nil else { throw PackageRefusal.altered }
                let data = try await Self.whole(entry)
                if data.isEmpty {
                    staged.secrets = Secrets()
                } else {
                    guard let secrets = try? JSONDecoder().decode(Secrets.self, from: data) else { throw PackageRefusal.altered }
                    staged.secrets = secrets
                }
            case .profile:
                guard Self.isHostName(entry.name) else { throw PackageRefusal.altered }
                let data = try await Self.whole(entry)
                guard let wire = try? JSONDecoder().decode(ProfileWire.self, from: data),
                      let profile = wire.profile(host: entry.name)
                else { throw PackageRefusal.altered }
                staged.said.append(profile)
            case .limits:
                guard entry.name == Self.limitsName, staged.limits == nil else { throw PackageRefusal.altered }
                // Leniently: a line this build cannot read is left out, and the account is never
                // a reason to refuse the store it rides with.
                staged.limits = try LimitAccount.data(LimitAccount.lines(from: try await Self.whole(entry)))
            case .picture:
                let parts = entry.name.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.count == 2, parts.allSatisfy(Self.isDigest) else { throw PackageRefusal.altered }
                let media = incoming.appendingPathComponent("media", isDirectory: true)
                let folder = media.appendingPathComponent(String(parts[0]), isDirectory: true)
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                try await Self.write(entry, to: folder.appendingPathComponent(String(parts[1])))
                staged.media = media
                staged.pictures += 1
            }
            done += entry.length
            progress(PackageProgress(done: min(done, total), total: total))
        }
        // Every tag has held and the footer was seen. Now: is the staged store one this build
        // can read? Opened before a byte here changes.
        var contents: (sources: [Source], notes: [Note], said: [SourceProfile])?
        var kept: Int?
        if summary.contents == .whole {
            guard staged.index != nil, staged.settings != nil, staged.secrets != nil else { throw PackageRefusal.altered }
            do {
                let index = try StoreFile(at: incoming)
                // No row of a store read back still owes a load (`ItemStore.replace`): taken off
                // in the staged file, which may be moved into place as it stands, and so off
                // what is read out of it for the store in memory and the index this run holds.
                try index.settleReferences()
                contents = try index.load()
                kept = try index.keptCount()
                // Read, and so one this build may write: where this run has no file of its own
                // the staged index is moved in as it stands, and it is not left holding words a
                // build before this one freed without zeroing (#292).
                index.scrub()
                // The profile entries are the words as taken away; the index's rows are the same
                // words, and where a package carried entries they are what is read back.
                if !staged.said.isEmpty { contents?.said = staged.said }
            } catch is StoreFile.Newer {
                throw PackageRefusal.newer
            } catch {
                throw PackageFault.unreadableStore
            }
            // **The header's word on what is kept is checked against the store it came with**
            // (#294), here, with the index staged and proven readable and nothing of this
            // device's touched. The header is sealed, but by whoever made the package: one that
            // says none is kept over a store in which every post is would have the question tell
            // the person so, and bring in posts no limit here will ever let go. A header that
            // states a number the index does not bear out is a package that is not as it says —
            // from a file and from a device nearby alike, since both are read back through here.
            if let said = summary.kept, said != kept { throw PackageRefusal.altered }
        } else {
            guard staged.secrets != nil else { throw PackageRefusal.altered }
            contents = nil
        }
        try await commit(staged, contents: contents, summary: summary)
    }

    /// The commit, whole or not at all: every step reads what it replaces first, and a step that
    /// refuses undoes every step before it, newest first. The Keychain goes first, being the
    /// step most likely to refuse; the store in memory goes last, and nothing follows it.
    private func commit(
        _ staged: Staged, contents: (sources: [Source], notes: [Note], said: [SourceProfile])?, summary: PackageSummary
    ) async throws {
        guard let saver else { return try await commitNow(staged, contents: contents) }
        try await saver.exclusively { try await commitNow(staged, contents: contents) }
    }

    /// One step of the commit that can be put back: its name, for the sentence that says it
    /// could not be, and the putting back, which says so by throwing.
    private struct Undo {
        let name: String
        let run: () async throws -> Void
    }

    private func commitNow(
        _ staged: Staged, contents: (sources: [Source], notes: [Note], said: [SourceProfile])?
    ) async throws {
        var undo: [Undo] = []
        var settle: [() -> Void] = []
        do {
            if let secrets = staged.secrets {
                let previous = try refile(secrets, onlyTheirs: contents == nil)
                undo.append(Undo(name: "secrets") { try unfile(secrets, previous: previous) })
            }
            guard let contents else { return }
            witness?(.staged)
            let index = try await commitIndex(contents, staged: staged)
            undo.append(Undo(name: "index", run: index.undo))
            settle.append(index.settle)
            if let media {
                // The copies kept here were for posts that are no longer here: replaced by the
                // package's where it carried any, and dropped where it did not.
                let aside = try media.adopt(staged.media ?? Self.emptyFolder(beside: directory))
                undo.append(Undo(name: "pictures") { try media.restore(aside) })
                settle.append { media.settle(aside) }
            }
            try await commitDefaults(staged, into: &undo)
            try commitLimits(staged, into: &undo)
            await store.replace(sources: contents.sources, notes: contents.notes, said: contents.said)
        } catch {
            // Newest first, every one tried, and the ones that refused named: the device is
            // then neither as it was nor as the package says, and the sentence must say so.
            var refused: [String] = []
            for step in undo.reversed() {
                do { try await step.run() } catch { refused.append(step.name) }
            }
            if refused.isEmpty { throw error }
            throw PackageFault.unwound(steps: refused)
        }
        // Every step held: what was put aside for putting back goes, explicitly and last.
        for step in settle { step() }
    }

    /// The index replaced, and how to put it back: through the open file where this run has one,
    /// which reads what it held first; by a move where it has none, with what was there — the
    /// index and what SQLite keeps beside it — put aside first.
    private func commitIndex(
        _ contents: (sources: [Source], notes: [Note], said: [SourceProfile]), staged: Staged
    ) async throws -> (undo: () async throws -> Void, settle: () -> Void) {
        if let file {
            let previous = try file.load()
            try await file.save(sources: contents.sources, notes: contents.notes, said: contents.said)
            return ({ try await file.save(sources: previous.sources, notes: previous.notes, said: previous.said) }, {})
        }
        guard let index = staged.index else { return ({}, {}) }
        let manager = FileManager.default
        let target = directory.appendingPathComponent(Self.indexName)
        let aside = directory.appendingPathComponent("\(StoreFile.readBackAsidePrefix)\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: aside, withIntermediateDirectories: true)
        // The marker first, and empty: while it is there and says no more, what is in this
        // folder is the old index, not replaced, and a launch puts it back (`settleHalfCommits`).
        let marker = aside.appendingPathComponent(Self.committingMarker)
        try Data().write(to: marker)
        var moved: [(from: URL, to: URL)] = []
        for suffix in [""] + StoreFile.sidecars {
            let file = directory.appendingPathComponent(Self.indexName + suffix)
            guard manager.fileExists(atPath: file.path) else { continue }
            let kept = aside.appendingPathComponent(Self.indexName + suffix)
            try manager.moveItem(at: file, to: kept)
            moved.append((kept, file))
        }
        witness?(.movedAside)
        do {
            // Said before it is done: from here an index in place is the package's, whether or
            // not the commit lives to say it replaced the old one.
            try Self.replacingMark.write(to: marker, options: .atomic)
            witness?(.replacing)
            try manager.moveItem(at: index, to: target)
            witness?(.movedIn)
            // Only now is the old index replaced, and the marker says so — whole or not at all,
            // so a kill here leaves it saying what it said. One that cannot be written leaves the
            // old index to be put back by a launch, which is the side to err on.
            try Self.replacedMark.write(to: marker, options: .atomic)
        } catch {
            try? manager.removeItem(at: target)
            for (kept, file) in moved { try? manager.moveItem(at: kept, to: file) }
            try? manager.removeItem(at: aside)
            throw error
        }
        witness?(.replaced)
        let witness = self.witness
        let undo: () async throws -> Void = {
            // The marker first, whole or not at all: from here the index in place is on its way
            // out and the aside is the store again. Taken out before the marker said so, a kill
            // would leave an aside marked replaced beside no index.
            try Self.undoingMark.write(to: marker, options: .atomic)
            witness?(.undoing)
            // Refused, the undo stops here with nothing moved: what SQLite kept beside the old
            // index must not come back to lie beside the package's.
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            witness?(.undoneGap)
            // The index itself last, as `settleHalfCommits` puts one back: while the aside still
            // holds it, a launch that finds this half done does the rest.
            for (kept, file) in moved.reversed() { try manager.moveItem(at: kept, to: file) }
            try? manager.removeItem(at: aside)
        }
        let settle: () -> Void = {
            try? manager.removeItem(at: aside.appendingPathComponent(Self.committingMarker))
            try? manager.removeItem(at: aside)
        }
        return (undo, settle)
    }

    /// The defaults replaced, with what they held read first and how to set it back.
    private func commitDefaults(_ staged: Staged, into undo: inout [Undo]) async throws {
        guard let settings = staged.settings else { return }
        let previous = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(Self.defaultsPrefix) }
        func set(_ values: [String: Any]) {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.defaultsPrefix) {
                defaults.removeObject(forKey: key)
            }
            for (key, value) in values { defaults.set(value, forKey: key) }
        }
        set(settings)
        undo.append(Undo(name: "settings") { set(previous) })
    }

    /// An empty folder to adopt as the copies where the package carried none.
    private static func emptyFolder(beside directory: URL) throws -> URL {
        let folder = directory.appendingPathComponent("incoming-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func write(_ entry: PackageReader.Entry, to url: URL) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var written = 0
        for try await chunk in entry.chunks {
            try handle.write(contentsOf: chunk)
            written += chunk.count
        }
        guard written == entry.length else { throw PackageRefusal.altered }
    }

    /// A small entry — settings, secrets, a profile — read whole. Bounded: none of these is a
    /// picture or a store, and one longer than a few chunks is not as written.
    private static func whole(_ entry: PackageReader.Entry) async throws -> Data {
        guard entry.length <= PackageFormat.chunkBytes * 4 else { throw PackageRefusal.altered }
        var data = Data()
        for try await chunk in entry.chunks { data.append(chunk) }
        guard data.count == entry.length else { throw PackageRefusal.altered }
        return data
    }

    /// A 64-character hex digest, which is every name a picture entry may have.
    private static func isDigest(_ part: Substring) -> Bool {
        part.count == 64 && part.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// A host as a profile entry may be named: lower-case letters, digits, dots and hyphens,
    /// and a port or brackets where `Host.parse` let one through.
    private static func isHostName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && name.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || ".-:[]".contains($0) }
    }
}
