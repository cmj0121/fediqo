import Foundation
import os

// The one line to a signed-in Mastodon, which carries every stream heard from it (#459).
//
// **One socket to the source's own address** (`/api/v1/streaming`), the token in its header as every
// other ask's, and each stream asked for on it by name (`subscribe`) and let go of the same way
// (`unsubscribe`). What it tells comes framed: the streams a message is of, the event's name, and
// what it carried as text — the same text a server-sent line hands over, so it lands the same.
// A message with no event — the source saying an ask on the line was wrong — is no event.

/// What can be heard of a Mastodon on a line.
public enum MastodonStream: Hashable, Sendable {
    /// The reader's own: Home, notices, announcements.
    case user
    /// Their direct posts: `conversation`.
    case direct
    /// One of the reader's lists, by the id the source gives it (#460).
    case list(id: String)
    /// The posts under one hashtag, by its name folded as the source folds it (`hashtag(_:)`).
    case tagged(String)
    /// The source's public timeline, every server it knows of (#460).
    case federated

    /// The stream of the posts under `tag`.
    public static func hashtag(_ tag: PostTag) -> MastodonStream { .tagged(tag.name.lowercased()) }

    /// What the source names it by: the first word is the stream, and the second its list or tag.
    /// A message on a socket names the streams it is of the same way.
    public var named: [String] {
        switch self {
        case .user: ["user"]
        case .direct: ["direct"]
        case .list(let id): ["list", id]
        case .tagged(let name): ["hashtag", name]
        case .federated: ["public"]
        }
    }

    /// The stream `named` names, or nothing for one this does not hear.
    public init?(named: [String]) {
        switch (named.first, named.count) {
        case ("user"?, 1): self = .user
        case ("direct"?, 1): self = .direct
        case ("public"?, 1): self = .federated
        case ("list"?, 2): self = .list(id: named[1])
        case ("hashtag"?, 2): self = .tagged(named[1].lowercased())
        default: return nil
        }
    }

    /// Where it is heard on a server-sent line of its own, and what the address asks of it.
    var path: String {
        switch self {
        case .user, .direct, .list, .federated: "/api/v1/streaming/\(named[0])"
        case .tagged: "/api/v1/streaming/hashtag"
        }
    }

    var query: [URLQueryItem] {
        switch self {
        case .list(let id): [URLQueryItem(name: "list", value: id)]
        case .tagged(let name): [URLQueryItem(name: "tag", value: name)]
        case .user, .direct, .federated: []
        }
    }

    /// The category its posts land in: Home's, a list's, the public timeline's — or none, for a
    /// hashtag's, which lands as a tag's page reads them (#124).
    public var category: Category? {
        switch self {
        case .user: .home
        case .list(let id): .list(id: id)
        case .federated: .public
        case .direct, .tagged: nil
        }
    }
}

/// The one line to a signed-in Mastodon (#459).
public struct MastodonSocket: Sendable {
    public let token: MastodonToken
    private let opener: any SocketOpener

    static let path = "/api/v1/streaming"

    public init(token: MastodonToken, opener: any SocketOpener) {
        self.token = token
        self.opener = opener
    }

    /// Opens the socket and returns once it is open. Throws `SocketRefused` where the source answered
    /// with no upgrade — a source heard line by line, then — and what the network threw where it did
    /// not answer. **A refusal signs nobody out**, as a line's does not (`MastodonLine.open`).
    public func open() async throws -> OpenSocket {
        guard let url = Host.httpsURL(host: token.host, path: Self.path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        return try await opener.open(request)
    }

    /// What asks the socket to carry `stream`.
    public static func subscribe(_ stream: MastodonStream) -> String {
        said("subscribe", stream)
    }

    /// What asks the socket to stop carrying `stream`.
    public static func unsubscribe(_ stream: MastodonStream) -> String {
        said("unsubscribe", stream)
    }

    /// One message heard on the socket: the streams it is of, and the event it tells as a line would
    /// tell it. Nothing for a message that tells no event, or whose words would not read.
    public static func heard(_ message: String) -> (streams: [String], event: LineEvent)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
              let name = object["event"] as? String, !name.isEmpty
        else {
            NetLog.network.notice("\(NetLog.line("socket message", host: "", error: URLError(.cannotParseResponse)), privacy: .public)")
            return nil
        }
        let streams = object["stream"] as? [String] ?? []
        let data: String
        switch object["payload"] {
        case let text as String:
            data = text
        case let carried? where JSONSerialization.isValidJSONObject(carried):
            data = (try? JSONSerialization.data(withJSONObject: carried)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        case let number as NSNumber:
            data = number.stringValue
        default:
            data = ""
        }
        return (streams, LineEvent(name: name, data: data))
    }

    private static func said(_ type: String, _ stream: MastodonStream) -> String {
        var words = ["type": type, "stream": stream.named[0]]
        for item in stream.query { words[item.name] = item.value }
        let data = (try? JSONSerialization.data(withJSONObject: words, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension MastodonLine {
    /// `stream` on a server-sent line of its own: where a source will not carry it on one socket.
    public func open(_ stream: MastodonStream) async throws -> AsyncThrowingStream<LineEvent, any Error> {
        try await open(path: stream.path, query: stream.query)
    }
}
