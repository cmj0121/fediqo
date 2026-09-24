import CryptoKit
import Foundation

/// Writes one `FDQ1` package, entry by entry, never holding more than a chunk in memory.
///
/// The prelude and the header go down first, so the summary is known before an entry is added:
/// the caller counts and weighs what it will add, then adds exactly that. `finish` writes the
/// footer and refuses a count that does not match — a package that says one thing in its header
/// and holds another is not one this writer will leave behind.
///
/// Not `Sendable`: one task writes one package from start to finish.
public final class PackageWriter {
    private let handle: FileHandle
    private let keys: PackageKeys
    private let prefix: Data
    private let entryCount: Int
    private var counter: UInt64 = 0
    private var entries = 0
    private var chunks = 0
    private var finished = false
    /// Plaintext bytes written so far, for a progress line.
    public private(set) var bytesWritten = 0

    /// Starts a package at `url` — a file made new here — locked by `key`, saying `summary`.
    /// `summary.takenAt`, `.withPictures`, `.bytes` and `.entryCount` are what the prelude and
    /// footer are checked against. `rounds` is the password's stretch; only a test lowers it.
    public init(
        to url: URL, key: PackageKey, summary: PackageSummary, rounds: UInt32 = PackageFormat.rounds
    ) throws {
        if case .password(let password) = key, password.isEmpty { throw PackageFault.emptyPassword }
        let prelude = PackageFormat.Prelude(
            keying: key.keying, salt: PackageKeys.random(16), rounds: rounds,
            noncePrefix: PackageKeys.random(4), takenAt: summary.takenAt,
            withPictures: summary.withPictures, bytes: summary.bytes
        )
        keys = try PackageKeys(key, prelude: prelude)
        prefix = prelude.noncePrefix
        entryCount = summary.entryCount
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let preludeBytes = prelude.encode()
        try handle.write(contentsOf: preludeBytes)
        let header = try JSONEncoder().encode(PackageSummary.Header(summary))
        try seal(header, with: keys.header, aad: preludeBytes + PackageFormat.Place.header.aad)
    }

    /// Adds one entry of `bytes` plaintext bytes, pulled from `read` a chunk at a time: `read`
    /// is asked for at most the count it is handed and answers nil once it has nothing left.
    /// The entry's length on the wire is what was read, checked against `bytes`.
    public func add(
        _ kind: PackageFormat.Entry.Kind, name: String, bytes: Int, _ read: (Int) throws -> Data?
    ) throws {
        guard !finished, entries < entryCount else { throw PackageFault.miscounted }
        let entry = PackageFormat.Entry(kind: kind, name: name, length: bytes)
        let index = entries
        try seal(try JSONEncoder().encode(entry), with: keys.entries, aad: PackageFormat.Place.record(entry: index).aad)
        var written = 0
        var chunk = 0
        var pending = try read(PackageFormat.chunkBytes) ?? Data()
        // Every entry has at least one chunk, the last flagged, so an empty entry is still
        // one box and a cut between its record and its end is still `.cutShort`.
        while true {
            let next = pending.isEmpty ? nil : try read(PackageFormat.chunkBytes)
            let last = next == nil || next?.isEmpty == true
            try seal(pending, with: keys.entries, aad: PackageFormat.Place.chunk(entry: index, index: chunk, last: last).aad)
            written += pending.count
            bytesWritten += pending.count
            chunk += 1
            chunks += 1
            guard let next, !next.isEmpty else { break }
            pending = next
        }
        guard written == bytes else { throw PackageFault.miscounted }
        entries += 1
    }

    /// Writes the footer and closes the file. Refuses a package with fewer entries than its
    /// header promised.
    public func finish() throws {
        guard !finished, entries == entryCount else { throw PackageFault.miscounted }
        finished = true
        let footer = PackageFormat.Footer(entryCount: entries, chunkCount: chunks)
        try seal(try JSONEncoder().encode(footer), with: keys.entries, aad: PackageFormat.Place.footer.aad)
        try handle.close()
    }

    private func seal(_ plaintext: Data, with key: SymmetricKey, aad: Data) throws {
        let nonce = try PackageFormat.nonce(prefix: prefix, counter: counter)
        counter += 1
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        guard let combined = box.combined else { throw PackageFault.keyDerivation }
        var out = Data()
        out.appendLE(UInt32(combined.count))
        out.append(combined)
        try handle.write(contentsOf: out)
    }
}
