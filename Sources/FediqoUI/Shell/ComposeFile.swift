import FediqoCore
import Foundation
import UniformTypeIdentifiers

/// The ceilings one host stated for a post, remembered for this run beside the post's length.
struct ComposeRoom: Equatable, Sendable {
    var limit: Int
    var media: MastodonMediaLimits
    /// How large a poll the source takes (#331), from the same answer.
    var polls: MastodonPollLimits = .unstated
}

/// A file the person picked for a post, read once through the sandbox's leave for that file.
///
/// Its size is asked before any of it is read. One over a ceiling the source stated is refused
/// without loading it, and one whose size the file does not say is refused as unreadable.
/// A kind the source listed, and did not list this file's, is refused the same way.
enum ComposeFile {
    struct Taken: Equatable, Sendable {
        var bytes: Data
        var name: String
        var type: String
    }

    enum Outcome: Equatable, Sendable {
        case taken(Taken)
        case refused(String)
    }

    static func read(_ url: URL, host: String, limits: MastodonMediaLimits) -> Outcome {
        let reached = url.startAccessingSecurityScopedResource()
        defer { if reached { url.stopAccessingSecurityScopedResource() } }
        let said = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        guard let size = said?.fileSize else {
            return .refused(L10n.t("compose.media.unreadable"))
        }
        let mime: String
        if let type = said?.contentType?.preferredMIMEType {
            mime = type
        } else if limits.mimeTypes.isEmpty {
            mime = "application/octet-stream"
        } else {
            return .refused(ComposeWords.refusalLine(.kind, host: host))
        }
        if !limits.allows(mime) {
            return .refused(ComposeWords.refusalLine(.kind, host: host))
        }
        if let ceiling = limits.byteLimit(for: mime), size > ceiling {
            return .refused(ComposeWords.refusalLine(.tooLarge(limit: ceiling), host: host))
        }
        guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .refused(L10n.t("compose.media.unreadable"))
        }
        let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        return .taken(Taken(bytes: bytes, name: name, type: mime))
    }
}
