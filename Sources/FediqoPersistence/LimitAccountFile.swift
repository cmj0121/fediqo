import FediqoCore
import Foundation

/// The limits' account on disk (#251): one JSON file beside the index, in Application Support.
///
/// **Beside the index and not in the preferences**, because the lines are about the store —
/// what its limits let go of — and belong with what they describe: they go where the index goes,
/// an export of the store's folder carries them, and like the index they are this device's and
/// excluded from backup. One small file rather than a table, because nothing ever queries it: it
/// is read whole once a launch and written whole each time a limit acts.
///
/// A file that cannot be read — none yet, or one a newer build wrote in a shape this one does
/// not know — reads as no lines; the next write replaces it.
public struct LimitAccountFile: LimitAccountStore {
    let url: URL

    static let name = "limits.json"

    public init(directory: URL) throws {
        try makeExcludedFromBackup(directory)
        url = directory.appendingPathComponent(Self.name)
    }

    public func read() -> [LimitAct] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return LimitAccount.lines(from: data)
    }

    public func write(_ lines: [LimitAct]) throws {
        try LimitAccount.data(lines).write(to: url, options: .atomic)
    }
}
