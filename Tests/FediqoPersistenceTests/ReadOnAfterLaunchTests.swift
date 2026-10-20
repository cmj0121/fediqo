import FediqoCore
import Foundation
import Testing
@testable import FediqoPersistence

/// A timeline read on after a launch reads on from the newest post the file holds of it (#201,
/// #283) — not only from what the pool has read in, which after a launch is little or nothing.
///
/// Before, a pool holding none of that timeline read no anchor, asked for the newest stretch,
/// and held nothing to tell it missed what lay between: a hole nothing said.
@Suite("A timeline read on after a launch reads on from what the file holds")
struct ReadOnAfterLaunchTests {
    private static let host = "one.example"
    private static let source = Source(host: host, kind: .mastodon)
    private static let base = Date(timeIntervalSince1970: 1_790_000_000)

    /// A public timeline of `ids`, paged as Mastodon pages it, each ask kept.
    actor Server: HTTPClient {
        private let ids: [Int]
        private(set) var cursors: [String] = []

        init(_ ids: ClosedRange<Int>) { self.ids = Array(ids) }

        func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value.flatMap(Int.init) }
            let limit = value("limit") ?? 20
            let page: [Int]
            if let min = value("min_id") {
                cursors.append("min_id=\(min)")
                page = Array(ids.filter { $0 > min }.prefix(limit)).reversed()
            } else if let max = value("max_id") {
                cursors.append("max_id=\(max)")
                page = Array(ids.filter { $0 < max }.suffix(limit)).reversed()
            } else {
                cursors.append("newest")
                page = Array(ids.suffix(limit)).reversed()
            }
            let body = "[" + page.map { id in
                """
                {"id":"\(id)","uri":"https://\(ReadOnAfterLaunchTests.host)/users/ada/statuses/\(id)",
                 "created_at":"2026-01-01T00:\(String(format: "%02d", id % 60)):00.000Z","content":"<p>\(id)</p>",
                 "visibility":"public","account":{"username":"ada","acct":"ada","display_name":"Ada"}}
                """
            }.joined(separator: ",") + "]"
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }

    /// Post `id`, listed by the public timeline. Ids of one length, as Mastodon's are.
    private static func note(_ id: Int, gone: Bool = false) -> Note {
        Note(
            id: "https://\(host)/users/ada/statuses/\(id)", source: source, author: "Ada", handle: "@ada",
            body: "\(id)", postedAt: base.addingTimeInterval(Double(id) * 60), categories: [.public],
            statusID: "\(id)", goneSince: gone ? base : nil, listed: [.public: "\(id)"]
        )
    }

    /// A store over a file holding `notes`, as a launch opens it: nothing read in.
    private func launched(_ notes: [Note]) async throws -> ItemStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = try StoreFile(at: dir)
        try await file.save(sources: [Self.source], notes: notes)
        try await file.makeIndexes()
        return ItemStore(sources: [Self.source], rows: file)
    }

    @Test("The newest post held only by the file is the anchor, not a gone one; a newer one read in wins")
    func anchorFromTheFile() async throws {
        let store = try await launched((101...110).map { Self.note($0) } + [Self.note(111, gone: true)])
        #expect(await store.all().isEmpty, "the premise: the pool holds nothing")
        #expect(await store.newestListedID(host: Self.host, category: .public) == "110")
        #expect(await store.newestListedID(host: Self.host, category: .home) == nil, "listed by no read of Home")
        #expect(await store.held(host: Self.host, category: .public).count == 11)

        await store.ingest([Self.note(112)])
        #expect(await store.newestListedID(host: Self.host, category: .public) == "112")
    }

    @Test("Read on after a launch, what arrived while the app was closed comes from the file's newest on, with no hole and nothing said")
    func noUnmarkedHole() async throws {
        let store = try await launched((101...110).map { Self.note($0) })
        let server = Server(101...160)
        let anchor = await store.newestListedID(host: Self.host, category: .public)
        let held = anchor == nil ? await store.held(host: Self.host, category: .public) : []
        let read = try await MastodonClient(http: server, host: Self.host)
            .publicTimeline(source: Self.source, readingOnFrom: anchor, holding: held, catchingUp: true)
        await store.land(read, of: .public, ifSourceHere: Self.host)

        #expect(await server.cursors.first == "min_id=109", "read on from the file's newest")
        let ids = Set(read.notes.compactMap { $0.statusID.flatMap(Int.init) })
        #expect(ids == Set(110...160), "everything after it, and no hole")
        #expect(read.missingBelow == nil && read.newerRemainAbove == nil)
    }
}
