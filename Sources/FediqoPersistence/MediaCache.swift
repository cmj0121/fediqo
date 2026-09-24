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
        for folder in hostFolders() where !kept.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    public func removeAll() {
        keepOnly(hosts: [])
    }

    public func bytes(host: String) -> Int {
        Self.files(in: folder(for: host)).reduce(0) { $0 + $1.size }
    }

    /// Oldest written first, by modification date, so what goes is what has been kept longest.
    /// A folder the trim emptied goes too, so `keepOnly` and `bytes` see no husk of a host.
    @discardableResult
    public func trim(toBytes cap: Int) -> Int {
        let files = hostFolders().flatMap(Self.files(in:))
        var total = files.reduce(0) { $0 + $1.size }
        guard total > cap else { return total }
        var touched = Set<URL>()
        for file in files.sorted(by: { $0.written < $1.written }) {
            guard total > cap else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
            touched.insert(file.url.deletingLastPathComponent())
        }
        for folder in touched where Self.files(in: folder).isEmpty {
            try? FileManager.default.removeItem(at: folder)
        }
        return total
    }

    /// Every copy on disk, as a take-away lists them (#247): the host folder's name and the
    /// file's, both digests, and what each weighs. In a stated order, so two walks agree.
    func copies() -> [(folder: String, name: String, url: URL, size: Int)] {
        hostFolders().sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { folder in
            Self.files(in: folder).sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }.map {
                (folder.lastPathComponent, $0.url.lastPathComponent, $0.url, $0.size)
            }
        }
    }

    /// What every copy weighs together.
    func totalBytes() -> Int {
        hostFolders().flatMap(Self.files(in:)).reduce(0) { $0 + $1.size }
    }

    /// Every copy replaced by what is under `staged`, a directory in this cache's own shape, by
    /// two renames: what was here goes aside first and is removed once the new is in place, so a
    /// failure between leaves either the old copies or the new, never a mix.
    func adopt(_ staged: URL) throws {
        let manager = FileManager.default
        let aside = directory.deletingLastPathComponent()
            .appendingPathComponent("media-aside-\(UUID().uuidString)", isDirectory: true)
        let had = manager.fileExists(atPath: directory.path)
        if had { try manager.moveItem(at: directory, to: aside) }
        do {
            try manager.moveItem(at: staged, to: directory)
        } catch {
            if had { try? manager.moveItem(at: aside, to: directory) }
            throw error
        }
        try makeExcludedFromBackup(directory)
        if had { try? manager.removeItem(at: aside) }
    }

    /// Every host's folder under `directory`.
    private func hostFolders() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private static func files(in folder: URL) -> [(url: URL, size: Int, written: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys
        )) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
    }

    /// The one folder `host` may touch: a child of `directory` named by the digest of the folded
    /// host, so two spellings of one host share it and no spelling escapes it.
    func folder(for host: String) -> URL {
        directory.appendingPathComponent(Self.folderName(host), isDirectory: true)
    }

    func file(host: String, url: URL) -> URL {
        folder(for: host).appendingPathComponent(Self.digest(url.absoluteString))
    }

    private static func folderName(_ host: String) -> String { digest(host.lowercased()) }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
