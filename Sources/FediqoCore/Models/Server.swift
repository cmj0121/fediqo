import Foundation

/// A source the timeline reads from. A server is a source, not a tab: it is written down
/// here so the timeline can say who handed a post over, never so it can be switched to.
public struct Server: Codable, Sendable, Hashable, Identifiable {
    public let host: String
    public let socialProtocol: SocialProtocol
    public var title: String
    public var addedAt: Date

    public var id: String { "\(socialProtocol.rawValue)://\(host)" }

    /// The `servers.url` this server is filed under: the scheme-qualified endpoint a client
    /// for its protocol talks to. A post's `source_url` must name the same address, so a client
    /// for another protocol owns its own scheme here and in the posts it hands over.
    public var endpoint: String {
        switch socialProtocol {
        case .mastodon, .activityPub, .atProto: "https://\(host)"
        case .nostr: "wss://\(host)"
        }
    }

    public init(host: String, socialProtocol: SocialProtocol, title: String = "", addedAt: Date = Date()) {
        self.host = Server.normalise(host)
        self.socialProtocol = socialProtocol
        self.title = title.isEmpty ? self.host : title
        self.addedAt = addedAt
    }

    /// Turns whatever the user typed into a bare host: `https://Mastodon.Social/` -> `mastodon.social`.
    public static func normalise(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[value.startIndex..<slash])
        }
        if value.hasPrefix("@") { value.removeFirst() }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

    /// A hostname we are willing to try. Deliberately loose — the instance probe is the real check.
    public static func looksLikeHost(_ raw: String) -> Bool {
        let host = normalise(raw)
        guard host.count >= 4, host.contains("."), !host.hasPrefix("."), !host.contains(" ") else { return false }
        return host.unicodeScalars.allSatisfy { hostCharacters.contains($0) }
    }

    /// The one gate to the network: whatever was typed, normalised, or `badHost` where no
    /// hostname could be read out of it. Every client builds its URLs through here.
    public static func validated(_ raw: String) throws -> String {
        let host = normalise(raw)
        guard looksLikeHost(host) else { throw SourceFailure.badHost(raw) }
        return host
    }
}
