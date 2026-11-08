import Foundation
import Testing
@testable import FediqoCore
@testable import FediqoUI

/// A Misskey answering its local timeline as Misskey pages it: the newest `limit` with no
/// `untilId`, and those below `untilId` where one is given, each newest first. Its ids are
/// fixed-width, so they order as `StatusID.later` reads a Misskey's: by length, then text.
private actor MisskeyServer: HTTPClient, HTTPSender {
    private let host: String
    private var held: [Int]
    /// The `untilId` each timeline ask carried, or `newest` where it carried none.
    private(set) var cursors: [String] = []
    /// A status every timeline ask is answered with, with Misskey's words for a closed door.
    private var refusing: Int?

    init(host: String, _ ids: some Sequence<Int>) {
        self.host = host
        held = Array(ids)
    }

    static func id(_ number: Int) -> String { String(format: "9k%06d", number) }

    func post(_ ids: some Sequence<Int>) { held += ids }
    func refuse(_ status: Int?) { refusing = status }

    /// What a reload asks before it reads — what the server is — answered as no Mastodon would.
    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let respond = { (status: Int) in
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
        guard url.path == "/api/notes/local-timeline" else { return (Data(), respond(404)) }
        let asked = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let until = asked["untilId"] as? String
        cursors.append(until.map { "untilId=\($0)" } ?? "newest")
        if let refusing {
            return (Data(#"{"error":{"code":"LTL_DISABLED"}}"#.utf8), respond(refusing))
        }
        let limit = asked["limit"] as? Int ?? 10
        let below = until.flatMap { Int($0.dropFirst(2)) }
        let page = Array(held.sorted().filter { id in below.map { id < $0 } ?? true }.suffix(limit)).reversed()
        return (Data(("[" + page.map(note).joined(separator: ",") + "]").utf8), respond(200))
    }

    private func note(_ number: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let posted = formatter.string(from: MisskeyReadTests.posted(number))
        return """
            {"id":"\(Self.id(number))","createdAt":"\(posted)",
             "user":{"id":"9aaa","username":"wren","name":"Wren","host":null,"avatarUrl":null},
             "text":"\(number)","cw":null,"files":[],"repliesCount":0,"renoteCount":0,"uri":null,"url":null}
            """
    }
}

/// A Misskey held is read as any source is (#486): `r` lands its local timeline's newest, and
/// scrolling down reads on below the last note it brought with `untilId`, until it says it has
/// no more. A Misskey that keeps its timeline from guests is said not read, and what was held
/// stays.
@MainActor
@Suite("A Misskey reloads its local timeline and reads on below it", .watched)
struct MisskeyReadTests {
    private static let host = "misskey.example"
    private static let source = Source(host: host, kind: .misskey)

    nonisolated static func posted(_ number: Int) -> Date {
        Date(timeIntervalSince1970: 1_704_067_200 + Double(number) * 60)
    }

    private func shell(_ server: MisskeyServer) async -> ShellSession {
        let store = ItemStore()
        await store.add(Self.source)
        let session = ShellSession(http: server, store: store)
        session.deadlinesUnturned()
        session.work = SourceWork()
        await session.reloadFromStore()
        return session
    }

    /// The notes the timeline in front draws, top to bottom, by the number each says.
    private func drawn(_ session: ShellSession) -> [Int] {
        session.timelineItems(latest: nil).compactMap { Int($0.body) }
    }

    @Test("r lands the newest notes, and r again brings no note twice")
    func reloadLands() async {
        let server = MisskeyServer(host: Self.host, 1...10)
        let session = await shell(server)

        await session.reload.timeline(.all, in: session)
        #expect(drawn(session) == Array((1...10).reversed()))
        #expect(session.reload.failed.isEmpty)

        await server.post(11...12)
        await session.reload.timeline(.all, in: session)
        #expect(drawn(session) == Array((1...12).reversed()), "every note once")
        #expect(await server.cursors == ["newest", "newest"])
    }

    @Test("Scrolling down asks below the last note brought, and stops once nothing older comes")
    func readsOn() async {
        let server = MisskeyServer(host: Self.host, 1...100)
        let session = await shell(server)

        await session.reload.timeline(.all, in: session)
        await session.reload.more(.all, in: session)
        await session.reload.more(.all, in: session)
        await session.reload.more(.all, in: session)
        let limit = MisskeyClient.limit
        let firstFloor = 100 - limit + 1, secondFloor = firstFloor - limit
        #expect(await server.cursors == [
            "newest", "untilId=\(MisskeyServer.id(firstFloor))", "untilId=\(MisskeyServer.id(secondFloor))",
            "untilId=\(MisskeyServer.id(1))",
        ])
        #expect(drawn(session) == Array((1...100).reversed()), "no hole, and no note twice")

        await session.reload.more(.all, in: session)
        #expect(await server.cursors.count == 4, "it said it has no more, so it is not asked again until r")
    }

    @Test("A Misskey that refuses a guest its timeline is said not read, and the notes held stay")
    func aRefusalKeepsWhatIsHeld() async {
        let server = MisskeyServer(host: Self.host, 1...5)
        let session = await shell(server)
        await session.reload.timeline(.all, in: session)
        #expect(drawn(session) == Array((1...5).reversed()))

        await server.refuse(400)
        await session.reload.timeline(.all, in: session)
        #expect(session.reload.failed == [Self.host])
        #expect(drawn(session) == Array((1...5).reversed()))
    }
}
