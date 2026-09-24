import FediqoCore
import Foundation
@testable import FediqoPersistence
@testable import FediqoUI

/// A session on a real index in a scratch folder, written, measured and compacted as the app's
/// is, with its picture copies under `media` and the limits' account beside the index — what a
/// limit on the store (#249) and its account (#251) are tested against, so the bytes a limit is
/// held to are bytes on disk.
@MainActor
struct LimitRoom {
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)
    static let alpha = Source(host: "alpha.test", kind: .mastodon)
    static let beta = Source(host: "beta.test", kind: .mastodon)

    let session: ShellSession
    let file: StoreFile
    let cache: MediaCache
    let pictures: ShellPictures
    /// How the rebuild behaves: how many more times it is to throw, and how often it ran.
    let compaction = Compaction()

    final class Compaction: @unchecked Sendable {
        var failing = 0
        var ran = 0
        var landed = 0
        struct Refused: Error {}
    }

    /// What the index weighs now, as the app measures it.
    var index: Int { file.bytesOnDisk() }

    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    static func address(_ n: Int) -> URL {
        URL(string: "https://example.test/\(n).png")!
    }

    /// A 4 KB post, `daysAgo` days before the origin.
    static func note(_ id: String, daysAgo: Double, from source: Source, holding: Holding = .arrived) -> Note {
        Note(
            id: id, source: source, author: "Ada", handle: "@ada", body: String(repeating: "x", count: 4_000),
            postedAt: origin.addingTimeInterval(-daysAgo * 86_400), categories: [.public], holding: holding
        )
    }

    /// Sixty posts, alternating sources, one a day back from the origin; the oldest held aside.
    static func held() -> [Note] {
        (0..<60).map { n in
            note("\(n)", daysAgo: Double(n), from: n.isMultiple(of: 2) ? alpha : beta, holding: n == 59 ? .aside : .arrived)
        }
    }

    init(at dir: URL, notes: [Note]) async throws {
        file = try StoreFile(at: dir)
        cache = try MediaCache(directory: dir.appendingPathComponent("media", isDirectory: true))
        let store = ItemStore(sources: [Self.alpha, Self.beta], notes: notes)
        pictures = ShellPictures(http: FixtureHTTP(), disk: cache)
        session = ShellSession(http: FixtureHTTP(), store: store, pictures: pictures, emojis: EmojiCache())
        let saver = StoreSaver(store: store, file: file)
        let file = self.file
        let compaction = self.compaction
        session.persist = { try? await saver.save() }
        session.measureStore = { file.bytesOnDisk() }
        session.weighStore = { file.bytesHeld() }
        session.compactStore = {
            compaction.ran += 1
            if compaction.failing > 0 {
                compaction.failing -= 1
                throw Compaction.Refused()
            }
            try await file.compact()
            compaction.landed += 1
        }
        session.limitStore = try LimitAccountFile(directory: dir)
        await session.reloadFromStore()
        await session.persist?()
    }

    /// `count` copies of `bytes` each under `host`, numbered from `n` and written oldest first.
    func copies(_ count: Int, of bytes: Int, host: String, from n: Int = 0) throws {
        for i in n..<(n + count) {
            try cache.store(Data(count: bytes), host: host, url: Self.address(i))
            try FileManager.default.setAttributes(
                [.modificationDate: Self.origin.addingTimeInterval(Double(i))],
                ofItemAtPath: cache.file(host: host, url: Self.address(i)).path
            )
        }
    }
}
