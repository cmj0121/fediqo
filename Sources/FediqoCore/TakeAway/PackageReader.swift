import CryptoKit
import Foundation
import Synchronization

/// Reads one `FDQ1` package, verifying every tag as it goes and never holding more than a
/// chunk in memory.
///
/// Three steps, each refusing before the next: `init(at:)` reads the plaintext prelude
/// (`.notOurs`, `.newer`, `.cutShort`); `open(with:)` unseals the header (`.wrongPassword`)
/// and hands back #252's summary; `entries()` then walks the file. Each entry's chunks are pulled
/// through the entry's own stream, and asking for the next entry first reads — and verifies —
/// whatever of the last one was not pulled. **The footer is read when the entry stream ends**,
/// so a consumer that reads the stream to its end has seen every tag hold; one that stops early
/// has committed nothing, because nothing here commits.
///
/// A class under a lock, so the two lazy streams can pull from one cursor.
public final class PackageReader: @unchecked Sendable {
    public let prelude: PackageFormat.Prelude

    private struct State {
        var handle: FileHandle
        let prefix: Data
        var keys: PackageKeys?
        var summary: PackageSummary?
        var counter: UInt64 = 0
        /// The entry being read, and whether its last chunk has been seen.
        var entry: Int = 0
        var chunk: Int = 0
        var inEntry = false
        var chunks = 0
        var done = false
    }

    private let state: Mutex<State>

    /// Reads the prelude of the package at `url`. Nothing is unsealed yet.
    public init(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let head = try handle.read(upToCount: PackageFormat.preludeBytes) ?? Data()
        // Four bytes that are not ours are not ours, however short the rest.
        if head.count < 4 || head.prefix(4) != PackageFormat.magic { throw PackageRefusal.notOurs }
        prelude = try PackageFormat.Prelude.decode(head)
        state = Mutex(State(handle: handle, prefix: prelude.noncePrefix))
    }

    /// Unseals the header with `key`, which is the one check a password gets: a wrong one fails
    /// here and nothing past the prelude has been read.
    public func open(with key: PackageKey) throws -> PackageSummary {
        let keys = try PackageKeys(key, prelude: prelude)
        return try state.withLock { state in
            // Asked again after a wrong password: the header is read from its place each time,
            // and nothing past it has moved.
            try state.handle.seek(toOffset: UInt64(PackageFormat.preludeBytes))
            state.counter = 0
            let aad = prelude.encode() + PackageFormat.Place.header.aad
            let plaintext: Data
            do {
                plaintext = try Self.unseal(&state, with: keys.header, aad: aad)
            } catch PackageRefusal.altered {
                throw PackageRefusal.wrongPassword
            }
            guard let header = try? JSONDecoder().decode(PackageSummary.Header.self, from: plaintext) else {
                throw PackageRefusal.altered
            }
            let summary = try header.summary(prelude)
            state.keys = keys
            state.summary = summary
            return summary
        }
    }

    /// One entry as it is read: what it is, and its bytes, a chunk at a time.
    public struct Entry: Sendable {
        public let kind: PackageFormat.Entry.Kind
        public let name: String
        public let length: Int
        /// The entry's bytes in order, each at most `PackageFormat.chunkBytes`. Pulled, so
        /// nothing is read ahead of the consumer.
        public let chunks: AsyncThrowingStream<Data, any Error>
    }

    /// Every entry in order, after `open`. Ends once the footer has been read and checked.
    public func entries() -> AsyncThrowingStream<Entry, any Error> {
        AsyncThrowingStream(unfolding: { [self] in try self.nextEntry() })
    }

    private func nextEntry() throws -> Entry? {
        try state.withLock { state in
            guard let keys = state.keys, let summary = state.summary else { throw PackageRefusal.altered }
            guard !state.done else { return nil }
            // What the consumer left of the last entry is read and checked all the same.
            while state.inEntry { _ = try Self.nextChunk(&state, keys: keys) }
            if state.entry == summary.entryCount {
                let footer = try Self.unseal(&state, with: keys.entries, aad: PackageFormat.Place.footer.aad)
                guard let read = try? JSONDecoder().decode(PackageFormat.Footer.self, from: footer),
                      read == PackageFormat.Footer(entryCount: state.entry, chunkCount: state.chunks)
                else { throw PackageRefusal.altered }
                // A package ends at its footer; anything after it was not written by us.
                guard try state.handle.read(upToCount: 1)?.isEmpty ?? true else { throw PackageRefusal.altered }
                state.done = true
                return nil
            }
            let record = try Self.unseal(&state, with: keys.entries, aad: PackageFormat.Place.record(entry: state.entry).aad)
            guard let entry = try? JSONDecoder().decode(PackageFormat.Entry.self, from: record) else {
                // A kind this build does not know decodes as nothing: a newer build's package,
                // told apart from a damaged record by whether the JSON itself reads.
                if let loose = try? JSONDecoder().decode(LooseEntry.self, from: record),
                   PackageFormat.Entry.Kind(rawValue: loose.kind) == nil
                {
                    throw PackageRefusal.newer
                }
                throw PackageRefusal.altered
            }
            guard entry.length >= 0 else { throw PackageRefusal.altered }
            state.inEntry = true
            state.chunk = 0
            return Entry(
                kind: entry.kind, name: entry.name, length: entry.length,
                chunks: AsyncThrowingStream(unfolding: { [self] in try self.pullChunk() })
            )
        }
    }

    private struct LooseEntry: Decodable {
        var kind: String
    }

    private func pullChunk() throws -> Data? {
        try state.withLock { state in
            guard let keys = state.keys, state.inEntry else { return nil }
            return try Self.nextChunk(&state, keys: keys)
        }
    }

    /// The next chunk of the entry being read, and nil past its last. Whether a chunk is the
    /// last is in its AAD, so it is tried both ways: only the one the writer flagged unseals.
    private static func nextChunk(_ state: inout State, keys: PackageKeys) throws -> Data? {
        guard state.inEntry else { return nil }
        let (entry, index) = (state.entry, state.chunk)
        let place = { (last: Bool) in PackageFormat.Place.chunk(entry: entry, index: index, last: last).aad }
        let box = try readBox(&state)
        let (plaintext, last) = try unsealBox(
            box, counter: &state.counter, prefix: state.prefix, with: keys.entries, aads: [place(false), place(true)]
        )
        state.chunk += 1
        state.chunks += 1
        if last {
            state.inEntry = false
            state.entry += 1
        }
        return plaintext
    }

    private static func unseal(_ state: inout State, with key: SymmetricKey, aad: Data) throws -> Data {
        let box = try readBox(&state)
        return try unsealBox(box, counter: &state.counter, prefix: state.prefix, with: key, aads: [aad]).0
    }

    /// The next box on the wire: its length, then that many bytes. Short is `.cutShort`; a
    /// length no writer of ours makes is `.altered`.
    private static func readBox(_ state: inout State) throws -> Data {
        guard let lengthBytes = try state.handle.read(upToCount: 4), lengthBytes.count == 4 else {
            throw PackageRefusal.cutShort
        }
        let length = Int(lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard length >= 28, length <= PackageFormat.maxBoxBytes else { throw PackageRefusal.altered }
        guard let box = try state.handle.read(upToCount: length), box.count == length else {
            throw PackageRefusal.cutShort
        }
        return box
    }

    /// Opens one box under the next counter, trying each AAD in `aads`; answers which one
    /// held (its index as `last` where two were offered).
    private static func unsealBox(
        _ box: Data, counter: inout UInt64, prefix: Data, with key: SymmetricKey, aads: [Data]
    ) throws -> (Data, Bool) {
        let nonce = try PackageFormat.nonce(prefix: prefix, counter: counter)
        counter += 1
        let sealed = try AES.GCM.SealedBox(combined: box)
        guard Data(sealed.nonce) == Data(nonce) else { throw PackageRefusal.altered }
        for (index, aad) in aads.enumerated() {
            if let plaintext = try? AES.GCM.open(sealed, using: key, authenticating: aad) {
                return (plaintext, index == 1)
            }
        }
        throw PackageRefusal.altered
    }
}
