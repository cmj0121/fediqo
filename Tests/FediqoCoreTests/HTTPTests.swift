import Foundation
import Testing
import os
@testable import FediqoCore

@Suite("HTTP", .serialized)
struct HTTPTests {
    @Test("URLSessionClient GETs HTTPS with User-Agent Fediqo, never DNS")
    func urlSessionClientGET() async throws {
        StubURLProtocol.prepare(status: 200, body: Data("ok".utf8), http: true)
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session())
        let url = URL(string: "https://urlprotocol.test/hello")!
        let (data, response) = try await client.data(from: url)
        #expect(String(data: data, encoding: .utf8) == "ok")
        #expect(response.statusCode == 200)

        let request = StubURLProtocol.lastRequest()
        #expect(request?.url == url)
        #expect(request?.httpMethod == "GET")
        #expect(request?.value(forHTTPHeaderField: "User-Agent") == "Fediqo")
    }

    @Test("URLSessionClient refuses HTTP without touching the network")
    func urlSessionClientHTTPSOnly() async {
        _ = URLSessionClient()
        StubURLProtocol.reset()
        let client = URLSessionClient(session: StubURLProtocol.session())
        await #expect(throws: URLError.self) {
            try await client.data(from: URL(string: "http://example.test/")!)
        }
        #expect(StubURLProtocol.lastRequest() == nil)
    }

    @Test("A non-HTTP response is a bad server response")
    func nonHTTPResponse() async {
        StubURLProtocol.prepare(status: 200, body: Data(), http: false)
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session())
        await #expect(throws: URLError.self) {
            try await client.data(from: URL(string: "https://urlprotocol.test/")!)
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int
        var body: Data
        var http: Bool
    }

    private struct State: Sendable {
        var stub: Stub?
        var lastRequest: URLRequest?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    static func prepare(status: Int, body: Data, http: Bool) {
        state.withLock {
            $0.stub = Stub(status: status, body: body, http: http)
            $0.lastRequest = nil
        }
    }

    static func lastRequest() -> URLRequest? {
        state.withLock { $0.lastRequest }
    }

    static func reset() {
        state.withLock {
            $0.stub = nil
            $0.lastRequest = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let captured = Self.state.withLock { state -> (Stub?, URLRequest) in
            state.lastRequest = request
            return (state.stub, request)
        }

        guard let stub = captured.0, let url = captured.1.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response: URLResponse
        if stub.http {
            response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"]
            )!
        } else {
            response = URLResponse(
                url: url,
                mimeType: "text/plain",
                expectedContentLength: stub.body.count,
                textEncodingName: "utf-8"
            )
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
