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
/// this device changes. Only then: the index, the picture copies, the defaults, and the Keychain
/// last, with what it held read first and put back if a save refuses. A failure before the
/// commit removes the staging and leaves the store byte for byte as it was.
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

    /// `directory` is where the index lives; `file` is the index as this run opened it, or nil
    /// where this run has none to write (then the staged index is moved into place instead).
    /// `freeSpace` and `rounds` are for tests; the app takes the defaults.
    public init(
        directory: URL, file: StoreFile?, store: ItemStore, media: MediaCache?,
        tokens: any MastodonTokenStore, credentials: any ForumCredentialStore,
        defaults: UserDefaults, device: String, appVersion: String,
        freeSpace: @escaping @Sendable (URL) -> Int = StorePackager.volumeFree,
        rounds: UInt32 = PackageFormat.rounds
    ) {
        self.directory = directory
        self.file = file
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
        let held = await !store.sources().isEmpty
        return PackageWeight(
            withoutPictures: index + settings, withPictures: index + settings + pictures,
            free: freeSpace(directory), holdsStore: held
        )
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

    public func takeAway(
        to url: URL, key: PackageKey, pictures: Bool, progress: @escaping @Sendable (PackageProgress) -> Void
    ) async throws {
        if case .password(let password) = key, password.isEmpty { throw PackageFault.emptyPassword }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("takeaway-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let snapshot = await store.snapshot()
        let staged = try StoreFile(at: scratch)
        try await staged.save(sources: snapshot.sources, notes: snapshot.notes, said: snapshot.said)
        let pieces = try pieces(
            index: scratch.appendingPathComponent(Self.indexName), sources: snapshot.sources.map(\.host),
            said: snapshot.said, pictures: pictures
        )
        let total = pieces.reduce(0) { $0 + $1.bytes }
        let summary = PackageSummary(
            sources: snapshot.sources.map { .init(host: $0.host, kind: $0.kind) },
            posts: snapshot.notes.count, timelines: timelinesKept(), takenAt: Date(), withPictures: pictures,
            bytes: total, hasSecrets: pieces.contains { $0.kind == .secrets && $0.bytes > 0 },
            device: device, appVersion: appVersion, entryCount: pieces.count
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

    /// Files `fresh` in the Keychain in place of whatever is there. Where a save refuses, what
    /// was there is put back first, so the Keychain is as it was or as the package says.
    private func refile(_ fresh: Secrets) throws {
        let previous = try secrets(sources: fresh.apps.map(\.host))
        do {
            try clearSecrets(previous)
            try clearSecrets(fresh)
            try fileSecrets(fresh)
        } catch {
            try? clearSecrets(fresh)
            try? fileSecrets(previous)
            throw error
        }
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
    private struct Staged {
        var index: URL?
        var settings: [String: Any]?
        var secrets: Secrets?
        var media: URL?
        var pictures = 0
        var said: [SourceProfile] = []
    }

    public func readBack(
        _ url: URL, key: PackageKey, replacing: Bool, progress: @escaping @Sendable (PackageProgress) -> Void
    ) async throws {
        let reader = try PackageReader(at: url)
        let summary = try reader.open(with: key)
        let held = await !store.sources().isEmpty
        if held, !replacing, summary.contents == .whole { throw PackageFault.alreadyHeld }
        let free = freeSpace(directory)
        if free < reader.prelude.bytes { throw PackageFault.noRoom(needed: reader.prelude.bytes, free: free) }

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
        if summary.contents == .whole {
            guard staged.index != nil, staged.settings != nil, staged.secrets != nil else { throw PackageRefusal.altered }
            do {
                contents = try StoreFile(at: incoming).load()
                // The profile entries are the words as taken away; the index's rows are the same
                // words, and where a package carried entries they are what is read back.
                if !staged.said.isEmpty { contents?.said = staged.said }
            } catch is StoreFile.Newer {
                throw PackageRefusal.newer
            } catch {
                throw PackageFault.unreadableStore
            }
        } else {
            guard staged.secrets != nil else { throw PackageRefusal.altered }
            contents = nil
        }
        try await commit(staged, contents: contents, summary: summary)
    }

    /// The commit, in the order that leaves the least behind if a step refuses: the index, the
    /// picture copies, the defaults, the Keychain, and then the store in memory.
    private func commit(
        _ staged: Staged, contents: (sources: [Source], notes: [Note], said: [SourceProfile])?, summary: PackageSummary
    ) async throws {
        if let contents {
            if let file {
                try await file.save(sources: contents.sources, notes: contents.notes, said: contents.said)
            } else if let index = staged.index {
                let target = directory.appendingPathComponent(Self.indexName)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: index, to: target)
            }
            // The copies kept here were for posts that are no longer here: replaced by the
            // package's where it carried any, and dropped where it did not.
            if let media {
                if let fresh = staged.media { try media.adopt(fresh) } else { media.removeAll() }
            }
            if let settings = staged.settings {
                for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.defaultsPrefix) {
                    defaults.removeObject(forKey: key)
                }
                for (key, value) in settings { defaults.set(value, forKey: key) }
            }
        }
        if let secrets = staged.secrets { try refile(secrets) }
        if let contents {
            await store.replace(sources: contents.sources, notes: contents.notes, said: contents.said)
        }
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

    /// A host as a profile entry may be named: lower-case letters, digits, dots and hyphens.
    private static func isHostName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && name.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "." || $0 == "-" }
    }
}
