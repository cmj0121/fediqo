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

/// A list, a hashtag and the public timeline, named and asked for as the source names them (#460).
@Suite("What else is heard of a Mastodon")
struct MastodonStreamTests {
    @Test("Each is named as a message names it, and read back from that name", arguments: [
        (MastodonStream.list(id: "5"), ["list", "5"]), (.tagged("fediqo"), ["hashtag", "fediqo"]), (.federated, ["public"]),
        (.user, ["user"]), (.direct, ["direct"]),
    ])
    func named(stream: MastodonStream, name: [String]) {
        #expect(stream.named == name)
        #expect(MastodonStream(named: name) == stream)
    }

    @Test("A hashtag is folded as the source folds it, wherever it is named")
    func folded() {
        #expect(MastodonStream.hashtag(PostTag("#Fediqo")!) == .tagged("fediqo"))
        #expect(MastodonStream(named: ["hashtag", "FEDIQO"]) == .tagged("fediqo"))
        #expect(MastodonStream(named: ["public:local"]) == nil, "one this does not hear")
    }

    @Test("Each is asked for by its word and its list or tag")
    func asked() {
        #expect(MastodonSocket.subscribe(.list(id: "5")) == #"{"list":"5","stream":"list","type":"subscribe"}"#)
        #expect(MastodonSocket.unsubscribe(.tagged("fediqo")) == #"{"stream":"hashtag","tag":"fediqo","type":"unsubscribe"}"#)
        #expect(MastodonSocket.subscribe(.federated) == #"{"stream":"public","type":"subscribe"}"#)
    }

    @Test("On a line of its own, each has its address", arguments: [
        (MastodonStream.list(id: "5"), "https://mastodon.localhost/api/v1/streaming/list?list=5"),
        (.tagged("fediqo"), "https://mastodon.localhost/api/v1/streaming/hashtag?tag=fediqo"),
        (.federated, "https://mastodon.localhost/api/v1/streaming/public"),
    ])
    func address(stream: MastodonStream, url: String) async throws {
        let held = HeldLines()
        _ = try await MastodonLine(
            token: MastodonToken(host: "mastodon.localhost", accessToken: "t", clientID: "c", clientSecret: "s", scopes: MastodonOAuth.reading),
            opener: held
        ).open(stream)
        #expect(held.requests.first?.url?.absoluteString == url)
    }

    @Test("A post told on a list lands in that list, and on a hashtag through no category")
    func lands() async throws {
        let store = ItemStore()
        let source = Source(host: "mastodon.localhost", kind: .mastodon)
        await store.add(source)
        let status = #"{"id":"9","uri":"https://mastodon.localhost/users/a/statuses/9","created_at":"2026-11-02T00:00:00.000Z","content":"<p>hi</p>","account":{"username":"a","acct":"a","display_name":"A"}}"#
        let landed = await MastodonLine.land([LineEvent(name: "update", data: status)], of: source, as: .list(id: "5"), in: store)
        guard case .arrived(let key, true)? = landed.first else {
            Issue.record("not landed: \(landed)")
            return
        }
        #expect(await store.note(key)?.listed[.list(id: "5")] == "9")
        let tagged = ItemStore()
        await tagged.add(source)
        let under = await MastodonLine.land([LineEvent(name: "update", data: status)], of: source, as: nil, in: tagged)
        guard case .arrived(let tagKey, true)? = under.first else {
            Issue.record("not landed: \(under)")
            return
        }
        #expect(await tagged.note(tagKey)?.categories.isEmpty == true)
    }
}
