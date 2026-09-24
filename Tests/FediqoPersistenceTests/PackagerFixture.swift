import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// What the packager tests share: one device — a folder for its index, a media cache, memory
/// Keychains and its own defaults — and a populated one to take away from.
enum PackagerFixture {
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    static let mastodon = Source(host: "one.example", kind: .mastodon)
    static let forum = Source(
        host: "forum.example", kind: .discuz, boards: [BoardSubscription(fid: 33, name: "a board")]
    )

    /// One device: a folder for its index, a media cache, memory Keychains and its own defaults.
    struct PackagerDevice {
        let root: URL
        let directory: URL
        let media: MediaCache
        let tokens = MemoryMastodonTokens()
        let credentials = MemoryCredentials()
        let defaults: UserDefaults
        let suite: String
        let store: ItemStore
        let file: StoreFile?

        init(sources: [Source] = [], notes: [Note] = [], noFile: Bool = false) async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("fediqo-device-\(UUID().uuidString)", isDirectory: true)
            directory = root.appendingPathComponent("Fediqo", isDirectory: true)
            media = try MediaCache(directory: root.appendingPathComponent("media", isDirectory: true))
            suite = "fediqo.test.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            store = ItemStore(sources: sources, notes: notes)
            if noFile {
                file = nil
            } else {
                let file = try StoreFile(at: directory)
                try await file.save(sources: sources, notes: notes)
                self.file = file
            }
        }

        func packager(free: Int = .max) -> StorePackager {
            StorePackager(
                directory: directory, file: file, store: store, media: media, tokens: tokens,
                credentials: credentials, defaults: defaults, device: "a test", appVersion: "0.7.0",
                freeSpace: { _ in free }, rounds: 1000
            )
        }

        /// Every byte of the index, and every picture copy with its bytes: what "untouched" means.
        func fingerprint() throws -> [String: Data] {
            var out: [String: Data] = [:]
            let index = directory.appendingPathComponent("index.sqlite")
            if FileManager.default.fileExists(atPath: index.path) {
                out["index"] = try Data(contentsOf: index)
            }
            for copy in media.copies() {
                out["media/\(copy.folder)/\(copy.name)"] = try Data(contentsOf: copy.url)
            }
            for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("fediqo.") {
                out["defaults/\(key)"] = Data(String(describing: value).utf8)
            }
            return out
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    static func note(
        _ id: String, source: Source = mastodon, holding: Holding = .arrived, body: String? = nil
    ) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada", body: body ?? "hello \(id)", postedAt: origin,
            categories: [.public], attachments: [Attachment(kind: .image, url: URL(string: "https://cdn.example/\(id).jpg"))],
            holding: holding
        )
    }

    /// A device holding two sources, three posts (one aside), two timelines, a preference, a
    /// token, an app registration and a forum password, and two picture copies.
    static func populated() async throws -> PackagerDevice {
        let device = try await PackagerDevice(
            sources: [mastodon, forum],
            notes: [note("1"), note("2", source: forum), note("3", holding: .aside)]
        )
        device.defaults.set(Data("{\"version\":2,\"timelines\":[{\"id\":\"a\",\"name\":\"A\",\"rules\":[]},{\"id\":\"b\",\"name\":\"B\",\"rules\":[]}]}".utf8), forKey: "fediqo.timelines")
        device.defaults.set("zh-TW", forKey: "fediqo.dummy.language")
        device.defaults.set("6", forKey: "fediqo.dummy.keepMonths")
        try device.tokens.save(MastodonToken(host: mastodon.host, accessToken: "t", clientID: "c", clientSecret: "s", scopes: "read"))
        try device.tokens.save(MastodonApp(host: mastodon.host, clientID: "c", clientSecret: "s", scopes: "read"))
        try device.credentials.save(ForumCredential(host: forum.host, username: "ada", password: "hunter2"))
        try device.media.store(Data(repeating: 7, count: 3000), host: mastodon.host, url: URL(string: "https://cdn.example/1.jpg")!)
        try device.media.store(Data(repeating: 9, count: 100), host: forum.host, url: URL(string: "https://forum.example/2.jpg")!)
        return device
    }

    static func package() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fediqo-\(UUID().uuidString).fdq")
    }
}
