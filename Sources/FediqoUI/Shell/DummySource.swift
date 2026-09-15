/// What kind of source this is. The protocol stays behind; the timeline sees a shape.
public enum DummySourceKind: String, Sendable, Hashable {
    case microblog
    case forum
    case board
}

/// A server this dummy timeline reads. An account is present only after sign-in.
public struct DummyAccount: Hashable, Sendable {
    public let displayName: String
    public let handle: String
}

public struct DummySource: Identifiable, Hashable, Sendable {
    public let id: String
    public let host: String
    public let kind: DummySourceKind
    public let account: DummyAccount?

    public var isSignedIn: Bool { account != nil }

    public static func unsigned(_ host: String, kind: DummySourceKind = .microblog) -> DummySource {
        DummySource(id: host, host: host, kind: kind, account: nil)
    }

    public static let unsignedPublic = DummySource(
        id: "first.example",
        host: "first.example",
        kind: .microblog,
        account: nil
    )

    public static let signedIn = DummySource(
        id: "second.example",
        host: "second.example",
        kind: .microblog,
        account: DummyAccount(displayName: "You", handle: "@you@second.example")
    )

    public static let forum = DummySource(
        id: "forum.example",
        host: "forum.example",
        kind: .forum,
        account: nil
    )

    public static let board = DummySource(
        id: "board.example",
        host: "board.example",
        kind: .board,
        account: nil
    )
}
