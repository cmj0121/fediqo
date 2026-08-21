import Foundation

/// A protocol Fediqo can read. Only Mastodon speaks today; the rest are listed so the
/// picker tells the truth about what is coming rather than pretending nothing else exists.
public enum SocialProtocol: String, Codable, Sendable, CaseIterable, Identifiable {
    case mastodon
    case activityPub
    case atProto
    case nostr

    public var id: String { rawValue }

    /// Whether this build can actually read it. Answered by what has a client registered,
    /// so shipping a protocol is registering a client rather than editing this file.
    public var isImplemented: Bool { SourceRegistry.implemented.contains(self) }
}
