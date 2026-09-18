import CryptoKit
import FediqoCore
import Foundation

/// Copies of multimedia already on this device. Same mechanism for pictures, video, and the rest.
///
/// Lives in Caches: every copy here came off a server and can come off it again, so the system
/// may purge it and a backup has no business carrying it. The directory is marked excluded from
/// backup as well, for a caller that puts it somewhere else.
///
/// **A host never names a path.** Each host's copies go in a folder named by a digest of the
/// host, never by the host itself, so no spelling of one — empty, `.`, `..`, or anything with a
/// `/` in it — can reach a file outside `directory`.
public struct MediaCache: MediaCopies {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try makeExcludedFromBackup(directory)
    }

    /// The cache this app keeps, under Caches.
    public static func caches() throws -> MediaCache {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fediqo", isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
        return try MediaCache(directory: root)
    }

    public func store(_ data: Data, host: String, url: URL) throws {
        let folder = folder(for: host)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(Self.digest(url.absoluteString)), options: .atomic)
    }

    public func data(host: String, url: URL) -> Data? {
        try? Data(contentsOf: folder(for: host).appendingPathComponent(Self.digest(url.absoluteString)))
    }

    public func forget(host: String) throws {
        let folder = folder(for: host)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    public func bytes(host: String) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder(for: host), includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// The one folder `host` may touch: a child of `directory` named by the digest of the folded
    /// host, so two spellings of one host share it and no spelling escapes it.
    func folder(for host: String) -> URL {
        directory.appendingPathComponent(Self.digest(host.lowercased()), isDirectory: true)
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
