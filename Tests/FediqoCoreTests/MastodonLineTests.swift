import Foundation
import Synchronization
import Testing
@testable import FediqoCore

/// A line held by the check (#325): it answers with `status`, records what was asked, and hands
/// over whatever the check yields on `told`.
final class HeldLines: LineOpener, Sendable {
    let status: Int
    let events: AsyncThrowingStream<LineEvent, any Error>
    let told: AsyncThrowingStream<LineEvent, any Error>.Continuation
    private let asked = Mutex<[URLRequest]>([])

    init(status: Int = 200) {
        self.status = status
        (events, told) = AsyncThrowingStream<LineEvent, any Error>.makeStream()
    }

    var requests: [URLRequest] { asked.withLock { $0 } }

    func open(_ request: URLRequest) async throws -> OpenLine {
        asked.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!
        if !(200..<300).contains(status) { told.finish() }
        return OpenLine(response: response, events: events)
    }
}

@Suite("Server-sent events are read off bytes as they come")
struct ServerSentEventsTests {
    /// A capture as the line sent it: written up to its last line, the line break that ends the
    /// last event being the literal's own, which Swift leaves out.
    static func closed(_ capture: String) -> String {
        capture.hasSuffix("\n\n") ? capture : capture + "\n"
    }

    private static func events(_ text: String, chunk: Int = .max) throws -> [LineEvent] {
        var reader = ServerSentEvents()
        let bytes = Data(Self.closed(text).utf8)
        var events: [LineEvent] = []
        var at = bytes.startIndex
        while at < bytes.endIndex {
            let end = bytes.index(at, offsetBy: min(chunk, bytes.endIndex - at))
            events += try reader.feed(bytes[at..<end])
            at = end
        }
        return events
    }

    @Test("Mastodon's own line reads as its six events, its `:)` and its beat said nothing, whole however the bytes are cut")
    func capturedLine() throws {
        let whole = try Self.events(MastodonLineCaptures.user)
        #expect(whole.map(\.name) == ["update", "status.update", "update", "delete", "delete", "delete"])
        #expect(whole[3].data == "117510102024468580")
        #expect(whole[0].data.hasPrefix(#"{"id":"117510102024468580""#) && whole[0].data.hasSuffix("}"))
        for chunk in [1, 7, 1000] {
            #expect(try Self.events(MastodonLineCaptures.user, chunk: chunk) == whole)
        }
    }

    @Test("Lines of data join with a line break; a line break of two bytes is one; an event with no data, a comment and a field it does not know say nothing; with no name it is a message")
    func theFormat() throws {
        let text = "event: a\r\ndata: one\r\ndata:two\r\n\r\nevent: empty\n\n: a comment\nretry: 5\nid: 9\ndata\n\n"
        #expect(try Self.events(text) == [
            LineEvent(name: "a", data: "one\ntwo"),
            LineEvent(name: "message", data: ""),
        ])
    }

    @Test("A line that runs past the ceiling is refused, and what came whole before it was read")
    func tooLong() throws {
        var reader = ServerSentEvents(longestLine: 16)
        #expect(try reader.feed(Data("data: x\n\ndata: ".utf8)) == [LineEvent(name: "message", data: "x")])
        #expect(throws: URLError(.dataLengthExceedsMaximum)) {
            _ = try reader.feed(Data(String(repeating: "y", count: 32).utf8))
        }
    }
}

@Suite("The reader's own Mastodon line")
struct MastodonLineTests {
    private static let host = LocalServers.mastodon
    private static let token = MastodonToken(host: host, accessToken: "tok-line", clientID: "cid", clientSecret: "cs")
    private static let source = Source(host: host, kind: .mastodon)

    private static func told(_ text: String) throws -> [LineEvent] {
        var reader = ServerSentEvents()
        return try reader.feed(Data(ServerSentEventsTests.closed(text).utf8))
    }

    private func store() async -> ItemStore {
        let store = ItemStore()
        await store.add(Self.source)
        return store
    }

    @Test("Asked of the token's own host, at the reader's own line, the token in its header; what it tells is handed over as it comes")
    func opens() async throws {
        let held = HeldLines()
        let events = try await MastodonLine(token: Self.token, opener: held).open()
        let request = try #require(held.requests.first)
        #expect(request.url?.absoluteString == "https://mastodon.localhost/api/v1/streaming/user")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-line")
        held.told.yield(LineEvent(name: "delete", data: "1"))
        held.told.finish()
        var heard: [LineEvent] = []
        for try await event in events { heard.append(event) }
        #expect(heard == [LineEvent(name: "delete", data: "1")])
    }

    @Test("An answer that is no 2xx is a refusal, a 401 among them, and opens nothing", arguments: [401, 400, 404, 502, 302])
    func refused(status: Int) async throws {
        await #expect(throws: MastodonLineRefused(status: status)) {
            _ = try await MastodonLine(token: Self.token, opener: HeldLines(status: status)).open()
        }
    }

    @Test("A post told lands in Home under the id Home lists it by, and told again is the same one row")
    func aPost() async throws {
        let store = await store()
        let update = try #require(try Self.told(MastodonLineCaptures.user).first)
        let landed = await MastodonLine.land(update, of: Self.source, in: store)
        guard case .arrived(let key, true) = landed else {
            Issue.record("not landed: \(landed)")
            return
        }
        let note = try #require(await store.note(key))
        #expect(note.categories == [.home])
        #expect(note.listed[.home] == "117510102024468580")
        #expect(note.body.contains("a line test"))
        #expect(await store.newestListedID(host: Self.host, category: .home) == "117510102024468580")
        #expect(await MastodonLine.land(update, of: Self.source, in: store) == .arrived(key, fresh: false))
        #expect(await store.all().count == 1)
    }

    @Test("A reblog told lands as the reblog, in Home under its own id, with the post it reblogs beside it through no timeline; taken back, the reblog is marked gone")
    func aReblog() async throws {
        let store = await store()
        let told = try Self.told(MastodonLineCaptures.reblog)
        #expect(told.map(\.name) == ["update", "delete"])
        guard case .arrived(let key, true) = await MastodonLine.land(told[0], of: Self.source, in: store) else {
            Issue.record("not landed")
            return
        }
        let reblog = try #require(await store.note(key))
        #expect(reblog.isReblog)
        #expect(reblog.listed[.home] == "117510105361746313")
        let post = try #require(await store.all().first { $0.key != key })
        #expect(post.categories.isEmpty)
        #expect(await MastodonLine.land(told[1], of: Self.source, in: store) == .gone([key]))
        #expect(await store.note(post.key)?.goneSince == nil, "the post it reblogged is still there")
    }

    @Test("A change lands over the row held, and only a row held; a deletion marks it gone once, however often it is told")
    func changedAndGone() async throws {
        let store = await store()
        let told = try Self.told(MastodonLineCaptures.user)
        #expect(await MastodonLine.land(told[1], of: Self.source, in: store) == .passed, "not held, so nothing")
        #expect(await store.all().isEmpty)
        guard case .arrived(let key, true) = await MastodonLine.land(told[0], of: Self.source, in: store) else {
            Issue.record("not landed")
            return
        }
        #expect(await MastodonLine.land(told[1], of: Self.source, in: store) == .changed(key))
        #expect(await store.note(key)?.body.contains("changed") == true)
        #expect(await MastodonLine.land(told[3], of: Self.source, in: store) == .gone([key]))
        #expect(await store.note(key)?.goneSince != nil)
        #expect(await MastodonLine.land(told[3], of: Self.source, in: store) == .gone([]))
    }

    @Test("A notice, an event it does not know, and words that will not read change nothing")
    func passes() async throws {
        let store = await store()
        let notice = try #require(try Self.told(MastodonLineCaptures.notice).first)
        #expect(notice.name == "notification")
        #expect(await MastodonLine.land(notice, of: Self.source, in: store) == .passed)
        #expect(await MastodonLine.land(LineEvent(name: "announcement", data: "{}"), of: Self.source, in: store) == .passed)
        #expect(await MastodonLine.land(LineEvent(name: "update", data: "{not json"), of: Self.source, in: store) == .unreadable)
        #expect(await MastodonLine.land(LineEvent(name: "delete", data: "../1"), of: Self.source, in: store) == .unreadable)
        #expect(await store.all().isEmpty)
    }

    @Test("What a source told after it was removed lands nowhere")
    func sourceGone() async throws {
        let store = ItemStore()
        let update = try #require(try Self.told(MastodonLineCaptures.user).first)
        _ = await MastodonLine.land(update, of: Self.source, in: store)
        #expect(await store.all().isEmpty)
    }
}
