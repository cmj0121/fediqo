import Foundation

/// The shell's own source, for the suites that hold a page to how it is written — one reader,
/// so no suite walks up from its own file to find it.
enum ShellSource {
    /// `Sources/FediqoUI`.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/FediqoUI")

    /// `Sources/FediqoUI/Shell`.
    static let shell = root.appendingPathComponent("Shell")

    /// The file `Shell/<name>.swift`, whole.
    static func shell(_ name: String) throws -> String {
        try String(contentsOf: shell.appendingPathComponent("\(name).swift"), encoding: .utf8)
    }
}
