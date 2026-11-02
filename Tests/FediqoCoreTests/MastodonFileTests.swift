import Foundation
import Testing
@testable import FediqoCore

/// #438, in the half of it Core holds: a file known ready, corrected and taken back, read from
/// what a real 4.6.6 answered (`MastodonFileCaptures`).
@Suite("A file on its way to a post at a Mastodon")
struct MastodonFileTests {
    private typealias Captures = MastodonFileCaptures

    private static let instant = FilePace(rounds: 4) { _ in }

    private func write(_ routes: [String: [FormServer.Answer]]) async throws -> (MastodonWrite, SequenceServer) {
        let server = SequenceServer(routes)
        let token = MastodonToken(host: "m.example", accessToken: "tok", clientID: "c", clientSecret: "s", scopes: "write:media")
        let tokens = MemoryMastodonTokens()
        try tokens.save(token)
        let store = ItemStore()
        await store.add(Source(host: "m.example", kind: .mastodon))
        return (MastodonWrite(door: MastodonAuthorized(token: token, sender: server, store: tokens), store: store), server)
    }

    @Test("A 202 is a file not yet ready, a 200 one that is")
    func accepted() async throws {
        let (slow, _) = try await write(["POST /api/v2/media": [.init(body: Captures.accepted, status: 202)]])
        #expect(try await slow.uploadFile(bytes: Data([1]), name: "v.mp4", type: "video/mp4", description: "").ready == false)
        let (quick, _) = try await write(["POST /api/v2/media": [.init(body: Captures.ready)]])
        #expect(try await quick.uploadFile(bytes: Data([1]), name: "p.png", type: "image/png", description: "").ready)
    }

    @Test("Each answer is its own standing, and anything else is thrown as it came")
    func standings() async throws {
        let at = "GET /api/v1/media/5"
        let (write, _) = try await write([at: [
            .init(body: Captures.accepted, status: 206), .init(body: Captures.ready),
            .init(body: Captures.unprepared, status: 422), .init(body: Captures.notFound, status: 404), .init(body: "down", status: 500),
        ]])
        #expect(try await write.standing(ofFile: "5") == .preparing)
        #expect(try await write.standing(ofFile: "5") == .ready)
        #expect(try await write.standing(ofFile: "5") == .unprepared)
        #expect(try await write.standing(ofFile: "5") == .gone)
        await #expect(throws: (any Error).self) { try await write.standing(ofFile: "5") }
    }

    @Test("A wait ends on ready, on what could not be prepared, at its bound, and at a cancelling")
    func waits() async throws {
        let at = "GET /api/v1/media/5"
        let waiting = FormServer.Answer(body: Captures.accepted, status: 206)
        let (ends, server) = try await write([at: [waiting, waiting, .init(body: Captures.ready)]])
        try await ends.awaitFile("5", pace: Self.instant)
        #expect(await server.count(at) == 3)

        let (fails, _) = try await write([at: [waiting, .init(body: Captures.unprepared, status: 422)]])
        await #expect(throws: MastodonFileError.unprepared) { try await fails.awaitFile("5", pace: Self.instant) }

        let (never, neverServer) = try await write([at: Array(repeating: waiting, count: 9)])
        await #expect(throws: MastodonFileError.stillPreparing) { try await never.awaitFile("5", pace: Self.instant) }
        #expect(await neverServer.count(at) == 4)

        let (stopped, stoppedServer) = try await write([at: Array(repeating: waiting, count: 9)])
        let cancelling = FilePace(rounds: 4) { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await stopped.awaitFile("5", pace: cancelling) }
        #expect(await stoppedServer.count(at) == 1)
    }

    @Test("A description is corrected at the source, and its refusal is thrown")
    func correcting() async throws {
        let at = "PUT /api/v1/media/5"
        let (write, server) = try await write([at: [.init(body: Captures.accepted, status: 206), .init(body: Captures.unprepared, status: 422)]])
        try await write.describeFile("5", as: "a hill")
        let form = try #require(await server.forms(at).first)
        #expect(form.hasPrefix("description=a") && form.hasSuffix("hill"))
        await #expect(throws: MastodonUnprocessable.self) { try await write.describeFile("5", as: "x") }
    }

    @Test("Taking back is done at the source; gone already is what was asked; on a post it is thrown")
    func takingBack() async throws {
        let at = "DELETE /api/v1/media/5"
        let (write, server) = try await write([at: [
            .init(body: "{}"), .init(body: Captures.notFound, status: 404), .init(body: Captures.onAPost, status: 422),
        ]])
        try await write.takeBackFile("5")
        try await write.takeBackFile("5")
        await #expect(throws: (any Error).self) { try await write.takeBackFile("5") }
        #expect(await server.count(at) == 3)
    }
}

/// Answers each `METHOD /path` from its own list, in turn.
private actor SequenceServer: HTTPSender {
    private var routes: [String: [FormServer.Answer]]
    private var asked: [(String, String)] = []

    init(_ routes: [String: [FormServer.Answer]]) { self.routes = routes }

    func count(_ route: String) -> Int { asked.filter { $0.0 == route }.count }
    func forms(_ route: String) -> [String] { asked.filter { $0.0 == route }.map(\.1) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let route = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        asked.append((route, request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
        guard let answer = routes[route]?.first else { throw URLError(.badServerResponse) }
        routes[route]?.removeFirst()
        return (Data(answer.body.utf8), HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!)
    }
}
