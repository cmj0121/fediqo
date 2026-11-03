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
public enum MastodonStream: String, Hashable, Sendable, CaseIterable {
    /// The reader's own: Home, notices, announcements.
    case user
    /// Their direct posts: `conversation`.
    case direct

    /// Where it is heard on a server-sent line of its own.
    var path: String { "/api/v1/streaming/\(rawValue)" }
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
        said(["type": "subscribe", "stream": stream.rawValue])
    }

    /// What asks the socket to stop carrying `stream`.
    public static func unsubscribe(_ stream: MastodonStream) -> String {
        said(["type": "unsubscribe", "stream": stream.rawValue])
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

    private static func said(_ words: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: words, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

extension MastodonLine {
    /// `stream` on a server-sent line of its own: where a source will not carry it on one socket.
    public func open(_ stream: MastodonStream) async throws -> AsyncThrowingStream<LineEvent, any Error> {
        switch stream {
        case .user: try await open()
        case .direct: try await openDirect()
        }
    }
}
