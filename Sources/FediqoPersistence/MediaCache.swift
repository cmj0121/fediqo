import CryptoKit
import FediqoCore
import Foundation

/// Copies of pictures already on this device, filed by the host they were read through.
///
/// Lives in Caches: every copy here came off a server and can come off it again, so the system
/// may purge it and a backup has no business carrying it. The directory is marked excluded from
/// backup as well, for a caller that puts it somewhere else.
///
/// **A host never names a path.** Each host's copies go in a folder named by a digest of the
/// folded host, never by the host itself, so no spelling of one — empty, `.`, `..`, or anything
/// with a `/` in it — can reach a file outside `directory`. The fold happens here and only here.
public struct MediaCache: MediaCopies {
    let directory: URL

    /// The largest copy `data` will read back. A file bigger than this was not written by
    /// `store` for any picture the shell accepts, and is not worth reading into memory.
    static let maxBytes = 20 * 1024 * 1024

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
        try FileManager.default.createDirectory(at: folder(for: host), withIntermediateDirectories: true)
        try data.write(to: file(host: host, url: url), options: .atomic)
    }

    public func data(host: String, url: URL) -> Data? {
        let file = file(host: host, url: url)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maxBytes
        else { return nil }
        return try? Data(contentsOf: file)
    }

    public func remove(host: String, url: URL) {
        try? FileManager.default.removeItem(at: file(host: host, url: url))
    }

    public func forget(host: String) {
        try? FileManager.default.removeItem(at: folder(for: host))
    }

    /// Drops the copies of every host not in `hosts` — what a server removed in a run that ended
    /// before its Clear reached the disk, or one no build ever cleared, leaves behind.
    public func keepOnly(hosts: some Sequence<String>) {
        let kept = Set(hosts.map(Self.folderName))
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for folder in folders where !kept.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    func bytes(host: String) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder(for: host), includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// The one folder `host` may touch: a child of `directory` named by the digest of the folded
    /// host, so two spellings of one host share it and no spelling escapes it.
    func folder(for host: String) -> URL {
        directory.appendingPathComponent(Self.folderName(host), isDirectory: true)
    }

    private func file(host: String, url: URL) -> URL {
        folder(for: host).appendingPathComponent(Self.digest(url.absoluteString))
    }

    private static func folderName(_ host: String) -> String { digest(host.lowercased()) }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
