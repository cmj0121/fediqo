import CryptoKit
import Foundation
import Testing
@testable import FediqoCore

/// #252: a package that is not ours, newer, cut short or altered is refused with its own
/// reason, before anything is trusted — each test fails without the check it pins.
@Suite("A package that is not whole is refused, and says why")
struct PackageRefusalTests {
    private let fixture = PackageFixture()

    private func temp() -> URL { fixture.temp() }
    private func noise(_ count: Int) -> Data { fixture.noise(count) }
    private func write(
        _ entries: [(PackageFormat.Entry.Kind, String, Data)], key: PackageKey = .password("open sesame"), to url: URL
    ) throws {
        try fixture.write(entries, key: key, to: url)
    }

    @Test("A file that is not ours is refused as not ours, however long it is")
    func notOurs() throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("SQLite format 3\u{0}".utf8).write(to: url)
        #expect(throws: PackageRefusal.notOurs) { try PackageReader(at: url) }
        try Data("FD".utf8).write(to: url)
        #expect(throws: PackageRefusal.notOurs) { try PackageReader(at: url) }
        try Data().write(to: url)
        #expect(throws: PackageRefusal.notOurs) { try PackageReader(at: url) }
    }

    @Test("A package of a newer version, or with an entry kind this build does not know, is refused as newer")
    func newer() async throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        try write([(.settings, "settings", Data("x".utf8))], to: url)
        var bytes = try Data(contentsOf: url)
        // The version is the two bytes after the magic.
        bytes[4] = 2
        bytes[5] = 0
        try bytes.write(to: url)
        #expect(throws: PackageRefusal.newer) { try PackageReader(at: url) }

        // An entry kind from a later build: written by hand through the same writer, with the
        // record's kind spelt as that build would spell it.
        let later = temp()
        defer { try? FileManager.default.removeItem(at: later) }
        try FutureWriter.write(kind: "hologram", to: later, password: "open sesame")
        let reader = try PackageReader(at: later)
        _ = try reader.open(with: .password("open sesame"))
        await #expect(throws: PackageRefusal.newer) {
            for try await entry in reader.entries() { for try await _ in entry.chunks {} }
        }
    }

    @Test("A prelude asking for more rounds than any writer of ours sets is refused as altered before a password is stretched")
    func tooManyRounds() throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        try write([(.settings, "settings", Data("x".utf8))], to: url)
        var bytes = try Data(contentsOf: url)
        // The rounds are the four bytes after the salt: magic 4, version 2, keying 1, pad 1, salt 16.
        var rounds = (PackageFormat.maxRounds + 1).littleEndian
        withUnsafeBytes(of: &rounds) { bytes.replaceSubrange(24..<28, with: $0) }
        try bytes.write(to: url)
        let started = Date()
        #expect(throws: PackageRefusal.altered) { try PackageReader(at: url) }
        #expect(Date().timeIntervalSince(started) < 1, "refused without stretching")
        // The cap itself is still read.
        rounds = PackageFormat.maxRounds.littleEndian
        withUnsafeBytes(of: &rounds) { bytes.replaceSubrange(24..<28, with: $0) }
        try bytes.write(to: url)
        #expect(try PackageReader(at: url).prelude.rounds == PackageFormat.maxRounds)
        let prelude = PackageFormat.Prelude(
            keying: .password, salt: Data(repeating: 1, count: 16), rounds: PackageFormat.maxRounds + 1,
            noncePrefix: Data(repeating: 0, count: 4), takenAt: Date(), withPictures: false, bytes: 0
        )
        #expect(throws: PackageRefusal.altered) { try PackageKeys(.password("open sesame"), prelude: prelude) }
    }

    @Test("A header box of a length no writer of ours makes is altered, not the wrong password")
    func headerLengthIsAltered() throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        try write([(.settings, "settings", Data("x".utf8))], to: url)
        var bytes = try Data(contentsOf: url)
        var length = UInt32(PackageFormat.maxBoxBytes + 1).littleEndian
        withUnsafeBytes(of: &length) { bytes.replaceSubrange(PackageFormat.preludeBytes..<PackageFormat.preludeBytes + 4, with: $0) }
        try bytes.write(to: url)
        #expect(throws: PackageRefusal.altered) { try PackageReader(at: url).open(with: .password("open sesame")) }
    }

    @Test("A package cut short anywhere is refused as cut short, and what was read before it is not trusted")
    func cutShort() async throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let big = noise(PackageFormat.chunkBytes + 10)
        try write([(.store, "index.sqlite", big), (.settings, "settings", Data("x".utf8))], to: url)
        let whole = try Data(contentsOf: url)
        // Cut in the prelude, in the header, in the middle of a chunk, and just before the footer.
        let footerLength = 4 + 12 + 16 + "{\"entryCount\":2,\"chunkCount\":3}".utf8.count
        for cut in [20, PackageFormat.preludeBytes + 30, PackageFormat.preludeBytes + 400 + PackageFormat.chunkBytes / 2, whole.count - footerLength, whole.count - 1] {
            try whole.prefix(cut).write(to: url)
            await #expect(throws: PackageRefusal.cutShort, "cut at \(cut)") {
                let reader = try PackageReader(at: url)
                _ = try reader.open(with: .password("open sesame"))
                for try await entry in reader.entries() { for try await _ in entry.chunks {} }
            }
        }
    }

    @Test("A byte changed anywhere past the header is refused as altered; in the prelude or header, as the wrong password")
    func altered() async throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        let big = noise(PackageFormat.chunkBytes + 10)
        try write([(.store, "index.sqlite", big), (.settings, "settings", Data("x".utf8))], to: url)
        let whole = try Data(contentsOf: url)
        // Something is read before the flip: the prelude's rounds, so the derived key differs.
        for at in [40, PackageFormat.preludeBytes + 20] {
            var bent = whole
            bent[at] ^= 0x01
            try bent.write(to: url)
            #expect(throws: PackageRefusal.wrongPassword, "flip at \(at)") {
                try PackageReader(at: url).open(with: .password("open sesame"))
            }
        }
        for at in [PackageFormat.preludeBytes + 400 + 100, whole.count - 3000, whole.count - 5] {
            var bent = whole
            bent[at] ^= 0x01
            try bent.write(to: url)
            await #expect(throws: PackageRefusal.altered, "flip at \(at)") {
                let reader = try PackageReader(at: url)
                _ = try reader.open(with: .password("open sesame"))
                for try await entry in reader.entries() { for try await _ in entry.chunks {} }
            }
        }
        // Bytes after the footer are not ours either.
        try (whole + Data([0])).write(to: url)
        await #expect(throws: PackageRefusal.altered) {
            let reader = try PackageReader(at: url)
            _ = try reader.open(with: .password("open sesame"))
            for try await entry in reader.entries() { for try await _ in entry.chunks {} }
        }
    }

    @Test("A chunk moved to another place in the file fails its tag, so a splice reads as altered")
    func spliced() async throws {
        let a = temp()
        let b = temp()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        try write([(.settings, "settings", Data("first".utf8)), (.secrets, "secrets", Data("second".utf8))], to: a)
        let whole = try Data(contentsOf: a)
        // Every box past the header is one length-prefixed blob; swap the two entries' chunks.
        var cursor = PackageFormat.preludeBytes
        var boxes: [Range<Int>] = []
        while cursor < whole.count {
            let length = Int(whole[cursor..<cursor + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            boxes.append(cursor..<cursor + 4 + length)
            cursor += 4 + length
        }
        // header, record 0, chunk 0, record 1, chunk 1, footer
        #expect(boxes.count == 6)
        var spliced = whole.prefix(PackageFormat.preludeBytes)
        for i in [0, 1, 4, 3, 2, 5] { spliced.append(whole[boxes[i]]) }
        try spliced.write(to: b)
        await #expect(throws: PackageRefusal.altered) {
            let reader = try PackageReader(at: b)
            _ = try reader.open(with: .password("open sesame"))
            for try await entry in reader.entries() { for try await _ in entry.chunks {} }
        }
    }

    @Test("Entries whose chunks were not pulled are still read and verified when the next is asked for")
    func skippedEntriesAreStillChecked() async throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url) }
        try write([(.store, "index.sqlite", noise(5000)), (.settings, "settings", Data("x".utf8))], to: url)
        var whole = try Data(contentsOf: url)
        whole[PackageFormat.preludeBytes + 400 + 100] ^= 0x01
        try whole.write(to: url)
        let reader = try PackageReader(at: url)
        _ = try reader.open(with: .password("open sesame"))
        await #expect(throws: PackageRefusal.altered) {
            for try await _ in reader.entries() {}
        }
    }
}

/// Writes a package as a later build with an entry kind of its own would: the same frame, the
/// record's kind spelt as that build spells it.
private enum FutureWriter {
    static func write(kind: String, to url: URL, password: String) throws {
        struct Record: Encodable { var kind: String; var name: String; var length: Int }
        let summary = PackageSummary(
            sources: [], posts: 0, timelines: 0, takenAt: Date(), withPictures: false, bytes: 0, hasSecrets: false,
            device: "later", appVersion: "9.9.9", entryCount: 1
        )
        let prelude = PackageFormat.Prelude(
            keying: .password, salt: PackageKeys.random(16), rounds: 1000, noncePrefix: PackageKeys.random(4),
            takenAt: summary.takenAt, withPictures: false, bytes: 0
        )
        let keys = try PackageKeys(.password(password), prelude: prelude)
        var out = prelude.encode()
        var counter: UInt64 = 0
        func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws {
            let nonce = try PackageFormat.nonce(prefix: prelude.noncePrefix, counter: counter)
            counter += 1
            let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad).combined!
            out.appendLE(UInt32(box.count))
            out.append(box)
        }
        try seal(try JSONEncoder().encode(PackageSummary.Header(summary)), key: keys.header, aad: prelude.encode() + PackageFormat.Place.header.aad)
        try seal(try JSONEncoder().encode(Record(kind: kind, name: "x", length: 0)), key: keys.entries, aad: PackageFormat.Place.record(entry: 0).aad)
        try seal(Data(), key: keys.entries, aad: PackageFormat.Place.chunk(entry: 0, index: 0, last: true).aad)
        try seal(try JSONEncoder().encode(PackageFormat.Footer(entryCount: 1, chunkCount: 1)), key: keys.entries, aad: PackageFormat.Place.footer.aad)
        try out.write(to: url)
    }
}
