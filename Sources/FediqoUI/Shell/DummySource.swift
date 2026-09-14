/// A server this dummy timeline reads. An account is present only after sign-in.
public struct DummyAccount: Hashable, Sendable {
    public let displayName: String
    public let handle: String
}

public struct DummySource: Identifiable, Hashable, Sendable {
    public let id: String
    public let host: String
    public let account: DummyAccount?

    public var isSignedIn: Bool { account != nil }

    public static let unsignedPublic = DummySource(
        id: "first.example",
        host: "first.example",
        account: nil
    )

    public static let signedIn = DummySource(
        id: "second.example",
        host: "second.example",
        account: DummyAccount(displayName: "You", handle: "@you@second.example")
    )
}

extension DummyTimeline {
    public var sources: [DummySource] {
        switch id {
        case "work": [.signedIn]
        default: [.unsignedPublic, .signedIn]
        }
    }
}
