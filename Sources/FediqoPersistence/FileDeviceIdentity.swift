import FediqoCore
import Foundation

/// This device's id (D1), kept in a small file beside the store and made fresh only when the
/// file is missing. **Excluded from backup**, so a device restored from another's backup never
/// shares its id; and no Keychain is asked at launch, which on an ad-hoc-signed Mac can prompt
/// after every rebuild.
public struct FileDeviceIdentity: DeviceIdentityStore {
    public static let name = "device-id"

    /// Where the id is kept.
    public let url: URL

    /// The id kept in `directory`, the store's folder.
    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.name)
    }

    /// What the file holds where it is not one id.
    public struct Unreadable: Error {}

    public func deviceID() throws -> String {
        let id = try keptOrMade()
        // Every time, not only when made: a file whose marking failed once is marked now. A
        // marking that fails costs no id: the one read or made is still this device's.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = url
        try? marked.setResourceValues(values)
        return id
    }

    private func keptOrMade() throws -> String {
        if FileManager.default.fileExists(atPath: url.path) { return try kept() }
        let id = UUID().uuidString
        // Through the one place every file is written (`Guarded`), at the store's class.
        try Guarded.write(Data(id.utf8), to: url)
        return id
    }

    private func kept() throws -> String {
        let data = try Data(contentsOf: url)
        guard let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil else { throw Unreadable() }
        return id
    }
}
