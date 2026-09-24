import Foundation
import Testing
@testable import FediqoCore

/// What the package tests share: a summary, a scratch path, bytes that are not all one value,
/// and a package written and read back whole — at a low round count, so a test is not a wait.
struct PackageFixture {
    static let takenAt = Date(timeIntervalSince1970: 1_800_000_000)

    func summary(entries: Int, bytes: Int, pictures: Bool = false) -> PackageSummary {
        PackageSummary(
            sources: [.init(host: "one.example", kind: .mastodon), .init(host: "forum.example", kind: .discuz)],
            posts: 12, timelines: 2, takenAt: Self.takenAt, withPictures: pictures, bytes: bytes,
            hasSecrets: true, device: "a laptop", appVersion: "0.7.0", entryCount: entries
        )
    }

    func temp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fediqo-package-\(UUID().uuidString).fdq")
    }

    /// A pull that hands `data` over in slices no larger than asked.
    func slices(of data: Data) -> (Int) -> Data? {
        var offset = 0
        return { most in
            guard offset < data.count else { return nil }
            let end = min(data.count, offset + most)
            defer { offset = end }
            return data[offset..<end]
        }
    }

    /// Writes one package of `entries` under `key`.
    func write(
        _ entries: [(PackageFormat.Entry.Kind, String, Data)], key: PackageKey = .password("open sesame"),
        to url: URL
    ) throws {
        let writer = try PackageWriter(
            to: url, key: key, summary: summary(entries: entries.count, bytes: entries.reduce(0) { $0 + $1.2.count }),
            rounds: 1000
        )
        for (kind, name, data) in entries {
            try writer.add(kind, name: name, bytes: data.count, slices(of: data))
        }
        try writer.finish()
    }

    /// Reads every entry of the package at `url` back, whole.
    func readAll(_ url: URL, key: PackageKey = .password("open sesame")) async throws
        -> (PackageSummary, [(PackageFormat.Entry.Kind, String, Data)])
    {
        let reader = try PackageReader(at: url)
        let summary = try reader.open(with: key)
        var read: [(PackageFormat.Entry.Kind, String, Data)] = []
        for try await entry in reader.entries() {
            var whole = Data()
            for try await chunk in entry.chunks { whole.append(chunk) }
            #expect(whole.count == entry.length)
            read.append((entry.kind, entry.name, whole))
        }
        return (summary, read)
    }

    /// Bytes that are not all one value, so a chunk out of place would show.
    func noise(_ count: Int) -> Data {
        var data = Data(count: count)
        var x: UInt32 = 2_463_534_242
        for i in 0..<count {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            data[i] = UInt8(truncatingIfNeeded: x)
        }
        return data
    }
}
