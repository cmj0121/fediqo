import CryptoKit
import Foundation
import Testing
@testable import FediqoCore

/// #247: the `FDQ1` package — written a chunk at a time and read back the same, locked by a
/// password or a direct key, and never finished with a count that does not add up. What is
/// refused, and why, is `PackageRefusalTests` (#252).
@Suite("The take-away package")
struct PackageTests {
    private let fixture = PackageFixture()
    private static let takenAt = PackageFixture.takenAt

    private func summary(entries: Int, bytes: Int, pictures: Bool = false) -> PackageSummary {
        fixture.summary(entries: entries, bytes: bytes, pictures: pictures)
    }
    private func temp() -> URL { fixture.temp() }
    private func slices(of data: Data) -> (Int) -> Data? { fixture.slices(of: data) }
    private func noise(_ count: Int) -> Data { fixture.noise(count) }
    private func write(
        _ entries: [(PackageFormat.Entry.Kind, String, Data)], key: PackageKey = .password("open sesame"), to url: URL
    ) throws {
        try fixture.write(entries, key: key, to: url)
    }
    private func readAll(_ url: URL, key: PackageKey = .password("open sesame")) async throws
        -> (PackageSummary, [(PackageFormat.Entry.Kind, String, Data)])
    {
        try await fixture.readAll(url, key: key)
    }

    @Test("Entries of many chunks go in a chunk at a time and come back whole, in order")
    func roundTripsChunked() async throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let big = noise(PackageFormat.chunkBytes * 2 + 12_345)
        let entries: [(PackageFormat.Entry.Kind, String, Data)] = [
            (.store, "index.sqlite", big),
            (.settings, "settings", Data("{}".utf8)),
            (.secrets, "secrets", Data()),
            (.picture, "ab/cd", noise(700)),
        ]
        try write(entries, to: url)
        let (summary, read) = try await readAll(url)
        #expect(summary == self.summary(entries: 4, bytes: big.count + 2 + 700))
        #expect(read.count == 4)
        for (want, got) in zip(entries, read) {
            #expect(got.0 == want.0)
            #expect(got.1 == want.1)
            #expect(got.2 == want.2)
        }
    }

    @Test("A chunk is never larger than the format's chunk, so the whole entry is never in memory")
    func streamsInChunks() async throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let big = noise(PackageFormat.chunkBytes * 3)
        try write([(.store, "index.sqlite", big)], to: url)
        let reader = try PackageReader(at: url)
        _ = try reader.open(with: .password("open sesame"))
        var chunks = 0
        for try await entry in reader.entries() {
            for try await chunk in entry.chunks {
                #expect(chunk.count <= PackageFormat.chunkBytes)
                chunks += 1
            }
        }
        #expect(chunks == 3)
    }

    @Test("The prelude reads without a password; the header is the first thing a password opens")
    func preludeThenHeader() throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        try write([(.settings, "settings", Data("x".utf8))], to: url)
        let reader = try PackageReader(at: url)
        #expect(reader.prelude.keying == .password)
        #expect(reader.prelude.takenAt == Self.takenAt)
        #expect(reader.prelude.bytes == 1)
        #expect(reader.prelude.rounds == 1000)
        #expect(throws: PackageRefusal.wrongPassword) { try reader.open(with: .password("open sesamE")) }
        #expect(throws: PackageRefusal.wrongPassword) { try reader.open(with: .direct(SymmetricKey(size: .bits256))) }
        #expect(try reader.open(with: .password("open sesame")).posts == 12)
    }

    @Test("A direct key locks a package as a password does, and neither opens the other's")
    func directKey() async throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let key = SymmetricKey(size: .bits256)
        try write([(.secrets, "secrets", Data("s".utf8))], key: .direct(key), to: url)
        #expect(try PackageReader(at: url).prelude.keying == .direct)
        let (_, read) = try await readAll(url, key: .direct(key))
        #expect(read.first?.2 == Data("s".utf8))
        #expect(throws: PackageRefusal.wrongPassword) { try PackageReader(at: url).open(with: .password("open sesame")) }
        #expect(throws: PackageRefusal.wrongPassword) {
            try PackageReader(at: url).open(with: .direct(SymmetricKey(size: .bits256)))
        }
    }

    @Test("An empty or a short password is refused before a byte is written")
    func emptyPassword() throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: PackageFault.emptyPassword) {
            try PackageWriter(to: url, key: .password(""), summary: summary(entries: 0, bytes: 0))
        }
        #expect(throws: PackageFault.shortPassword) {
            try PackageWriter(to: url, key: .password("seven77"), summary: summary(entries: 0, bytes: 0))
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A writer that adds fewer or more entries than it promised, or fewer bytes, finishes nothing")
    func miscount() throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let short = try PackageWriter(to: url, key: .password("password"), summary: summary(entries: 2, bytes: 1), rounds: 1000)
        try short.add(.settings, name: "a", bytes: 1, slices(of: Data("a".utf8)))
        #expect(throws: PackageFault.miscounted) { try short.finish() }
        let over = try PackageWriter(to: url, key: .password("password"), summary: summary(entries: 0, bytes: 0), rounds: 1000)
        #expect(throws: PackageFault.miscounted) { try over.add(.settings, name: "a", bytes: 0) { _ in nil } }
        let lied = try PackageWriter(to: url, key: .password("password"), summary: summary(entries: 1, bytes: 5), rounds: 1000)
        #expect(throws: PackageFault.miscounted) { try lied.add(.settings, name: "a", bytes: 5, slices(of: Data("a".utf8))) }
    }

    @Test("A password is stretched through the prelude's rounds and salt into two keys, and differs by salt")
    func keys() throws {
        let prelude = PackageFormat.Prelude(
            keying: .password, salt: Data(repeating: 1, count: 16), rounds: 10, noncePrefix: Data(repeating: 0, count: 4),
            takenAt: Self.takenAt, withPictures: false, bytes: 0
        )
        let a = try PackageKeys(.password("p"), prelude: prelude)
        let b = try PackageKeys(.password("p"), prelude: prelude)
        #expect(a.header == b.header && a.entries == b.entries)
        #expect(a.header != a.entries)
        let other = PackageFormat.Prelude(
            keying: .password, salt: Data(repeating: 2, count: 16), rounds: 10, noncePrefix: Data(repeating: 0, count: 4),
            takenAt: Self.takenAt, withPictures: false, bytes: 0
        )
        #expect(try PackageKeys(.password("p"), prelude: other).header != a.header)
        #expect(throws: PackageFault.emptyPassword) { try PackageKeys(.password(""), prelude: prelude) }
    }
}
