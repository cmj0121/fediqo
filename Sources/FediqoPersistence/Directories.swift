import FediqoCore
import Foundation

/// Makes `directory`, parents and all, and marks it excluded from backup: what is kept here is
/// this device's copy of what a server sent, and it comes back from the server, not from a
/// restore. The Persistence spelling of `Guarded.makeFolder`: made at the class everything this
/// app keeps is made at (#344).
func makeExcludedFromBackup(_ directory: URL, on device: Guarded.Device = .this) throws {
    try Guarded.makeFolder(directory, excludedFromBackup: true, on: device)
}
