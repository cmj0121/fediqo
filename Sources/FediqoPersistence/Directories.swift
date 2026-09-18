import Foundation

/// Makes `directory`, parents and all, and marks it excluded from backup: what is kept here is
/// this device's copy of what a server sent, and it comes back from the server, not from a
/// restore.
func makeExcludedFromBackup(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var marked = directory
    try marked.setResourceValues(excluded)
}
