import CryptoKit
import Foundation

/// Copies of multimedia already on this device. Same mechanism for pictures, video, and the rest.
public struct MediaCache: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var directory = directory
        try directory.setResourceValues(excluded)
    }

    public static func applicationSupport() throws -> MediaCache {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fediqo", isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
        return try MediaCache(directory: root)
    }

    public func store(_ data: Data, host: String, url: URL) throws {
        let folder = directory.appendingPathComponent(host.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(Self.name(url)), options: .atomic)
    }

    public func data(host: String, url: URL) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(host.lowercased()).appendingPathComponent(Self.name(url)))
    }

    public func forget(host: String) throws {
        let folder = directory.appendingPathComponent(host.lowercased(), isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    public func bytes(host: String) -> Int {
        let folder = directory.appendingPathComponent(host.lowercased(), isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private static func name(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
