import Foundation
import Testing
@testable import FediqoCore

/// What is said on the one line to a Mastodon, and how what it says is read (#459).
@Suite("The one line to a Mastodon")
struct MastodonSocketTests {
    private static let token = MastodonToken(
        host: "mastodon.localhost", accessToken: "tok-socket", clientID: "c", clientSecret: "s", scopes: MastodonOAuth.reading
    )

    /// The socket asked for, refused or opened as the check says.
    private final class Asked: SocketOpener, @unchecked Sendable {
        var requests: [URLRequest] = []
        func open(_ request: URLRequest) async throws -> OpenSocket {
            requests.append(request)
            let (messages, _) = AsyncThrowingStream<String, any Error>.makeStream()
            return OpenSocket(messages: messages, send: { _ in })
        }
    }

    @Test("It is asked of the source's own address, with the token in its header")
    func asked() async throws {
        let opener = Asked()
        _ = try await MastodonSocket(token: Self.token, opener: opener).open()
        let request = try #require(opener.requests.first)
        #expect(request.url?.absoluteString == "https://mastodon.localhost/api/v1/streaming")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-socket")
    }

    @Test("Each stream is asked for, and let go of, by name")
    func words() {
        #expect(MastodonSocket.subscribe(.user) == #"{"stream":"user","type":"subscribe"}"#)
        #expect(MastodonSocket.unsubscribe(.direct) == #"{"stream":"direct","type":"unsubscribe"}"#)
    }

    @Test("A message tells its streams and its event, with the text it carried, as a line would")
    func heard() throws {
        let update = try #require(MastodonSocket.heard(#"{"stream":["user"],"event":"update","payload":"{\"id\":\"1\"}"}"#))
        #expect(update.streams == ["user"])
        #expect(update.event == LineEvent(name: "update", data: #"{"id":"1"}"#))
        let gone = try #require(MastodonSocket.heard(#"{"stream":["user"],"event":"delete","payload":"117"}"#))
        #expect(gone.event == LineEvent(name: "delete", data: "117"))
        let filters = try #require(MastodonSocket.heard(#"{"stream":["user"],"event":"filters_changed"}"#))
        #expect(filters.event == LineEvent(name: "filters_changed", data: ""))
        let direct = try #require(MastodonSocket.heard(#"{"stream":["direct"],"event":"conversation","payload":"{}"}"#))
        #expect(direct.streams == ["direct"])
    }

    @Test("What tells no event, or will not read, is nothing", arguments: [
        #"{"error":"Missing access token","status":401}"#, "not json", #"{"stream":["user"],"event":""}"#,
    ])
    func nothing(message: String) {
        #expect(MastodonSocket.heard(message) == nil)
    }
}
