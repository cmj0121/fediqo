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

    @Test("A body inside the ceiling is handed over whole")
    func underTheCeiling() async throws {
        let body = Data(repeating: 0x2e, count: 4096)
        StubURLProtocol.prepare(status: 200, body: body, http: true, declaredLength: body.count)
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session(), byteLimit: body.count)
        let (data, _) = try await client.data(from: URL(string: "https://urlprotocol.test/fits")!)
        #expect(data == body)
    }

    /// The body here is 4 KiB against a 1 MiB ceiling, so a ceiling applied to bytes already
    /// taken would let it through. What refuses it is the 10 MiB the response declared — read,
    /// and answered `.cancel`, before any of the body was asked for.
    @Test("A declared length over the ceiling is refused before the body moves")
    func refusedOnDeclaredLength() async {
        StubURLProtocol.prepare(
            status: 200,
            body: Data(repeating: 0x2e, count: 4096),
            http: true,
            declaredLength: 10 << 20
        )
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session(), byteLimit: 1 << 20)
        await #expect(throws: URLError(.dataLengthExceedsMaximum)) {
            try await client.data(from: URL(string: "https://urlprotocol.test/huge")!)
        }
    }

    @Test("A body that declares nothing is refused where the running total trips")
    func refusedOnRunningTotal() async {
        let body = Data(repeating: 0x2e, count: 2 << 20)
        StubURLProtocol.prepare(status: 200, body: body, http: true, chunk: 32 << 10)
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session(), byteLimit: 64 << 10)
        await #expect(throws: URLError(.dataLengthExceedsMaximum)) {
            try await client.data(from: URL(string: "https://urlprotocol.test/chunked")!)
        }
        #expect(StubURLProtocol.delivered() < body.count)
    }

    @Test("Cancelling the Task cancels the transfer")
    func cancellationStopsTheTransfer() async throws {
        let body = Data(repeating: 0x2e, count: 2 << 20)
        StubURLProtocol.prepare(status: 200, body: body, http: true, chunk: 32 << 10)
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session())
        let fetch = Task {
            try await client.data(from: URL(string: "https://urlprotocol.test/slow")!)
        }
        while StubURLProtocol.delivered() == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        fetch.cancel()

        do {
            let (data, _) = try await fetch.value
            Issue.record("expected a cancelled transfer, got \(data.count) bytes")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
        #expect(StubURLProtocol.delivered() < body.count)
    }

    /// The second wire boundary. `URLSession` follows a 302 on its own, and left to itself it
    /// will follow one down to plain `http` and hand back a body whose `HTTPURLResponse` carries
    /// an `http://` URL that no caller looks at again.
    @Test("A redirect down to http is refused, not followed")
    func redirectDowngradeRefused() async {
        StubURLProtocol.prepare(
            status: 200, body: Data("secret".utf8), http: true, redirect: "http://downgrade.test/x"
        )
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session())
        do {
            let (data, response) = try await client.data(from: URL(string: "https://urlprotocol.test/go")!)
            Issue.record("followed the downgrade: \(data.count) bytes from \(response.url as Any)")
        } catch let error as URLError {
            #expect(error.code == .unsupportedURL)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("A redirect that stays on https is followed")
    func redirectWithinHTTPSFollowed() async throws {
        StubURLProtocol.prepare(
            status: 200, body: Data("moved".utf8), http: true, redirect: "https://urlprotocol.test/there"
        )
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session())
        let (data, response) = try await client.data(from: URL(string: "https://urlprotocol.test/go")!)
        #expect(String(data: data, encoding: .utf8) == "moved")
        #expect(response.url?.path == "/there")
    }

    /// The window where `onCancel` has already fired before the continuation exists. Whichever
    /// path resumes, the answer must be a cancellation and the call must come back at all — the
    /// failure this guards is a caller hung with no error and no timeout.
    @Test("A fetch cancelled before it starts comes back cancelled, not hung")
    func cancelledBeforeItStarts() async {
        StubURLProtocol.prepare(
            status: 200, body: Data(repeating: 0x2e, count: 2 << 20), http: true, chunk: 32 << 10
        )
        defer { StubURLProtocol.reset() }

        let client = URLSessionClient(session: StubURLProtocol.session())
        let fetch = Task {
            try await client.data(from: URL(string: "https://urlprotocol.test/never")!)
        }
        fetch.cancel()

        do {
            let (data, _) = try await fetch.value
            Issue.record("expected a cancellation, got \(data.count) bytes")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var status: Int
        var body: Data
        var http: Bool
        /// Bytes per `didLoad`, paced, or `0` to hand the whole body over at once.
        var chunk: Int
        /// The `Content-Length` to advertise, or `nil` for a response that declares nothing —
        /// which is what `URLSession` reports as `NSURLSessionTransferSizeUnknown`.
        var declaredLength: Int?
        /// Where the first request is sent instead, as a `302`. Only the first: the second one
        /// is served normally, so a test can watch a redirect be followed rather than loop.
        var redirect: String?
    }

    private struct State: Sendable {
        var stub: Stub?
        var lastRequest: URLRequest?
        var delivered = 0
        var redirected = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    static func prepare(
        status: Int,
        body: Data,
        http: Bool,
        chunk: Int = 0,
        declaredLength: Int? = nil,
        redirect: String? = nil
    ) {
        state.withLock {
            $0.stub = Stub(
                status: status,
                body: body,
                http: http,
                chunk: chunk,
                declaredLength: declaredLength,
                redirect: redirect
            )
            $0.lastRequest = nil
            $0.delivered = 0
            $0.redirected = false
        }
    }

    static func lastRequest() -> URLRequest? {
        state.withLock { $0.lastRequest }
    }

    /// Body bytes this stub has actually put on the wire for the current `prepare`.
    static func delivered() -> Int {
        state.withLock { $0.delivered }
    }

    static func reset() {
        state.withLock {
            $0.stub = nil
            $0.lastRequest = nil
            $0.delivered = 0
            $0.redirected = false
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
        if let target = stub.redirect, let moved = URL(string: target), takeRedirect() {
            let found = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: moved), redirectResponse: found)
            // A declined redirect leaves this protocol holding the task: finish it, or the
            // request sits until it times out.
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response: URLResponse
        if stub.http {
            var headers = ["Content-Type": "text/plain"]
            if let declared = stub.declaredLength {
                headers["Content-Length"] = String(declared)
            }
            response = HTTPURLResponse(
                url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: headers
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

        guard stub.chunk > 0 else {
            Self.state.withLock { $0.delivered = stub.body.count }
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        DispatchQueue.global().async { [weak self] in self?.pace(stub) }
    }

    /// Hands the body over a chunk at a time, stopping the moment the task is torn down, so a
    /// refusal part-way through a transfer is the same shape here as it is over a socket.
    private func pace(_ stub: Stub) {
        var sent = 0
        while sent < stub.body.count {
            if stopped.withLock({ $0 }) { return }
            let end = min(sent + stub.chunk, stub.body.count)
            let piece = stub.body[sent..<end]
            Self.state.withLock { $0.delivered += piece.count }
            client?.urlProtocol(self, didLoad: Data(piece))
            sent = end
            Thread.sleep(forTimeInterval: 0.01)
        }
        if !stopped.withLock({ $0 }) {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// True once, for the first request only, so a followed redirect is served rather than bounced
    /// again.
    private func takeRedirect() -> Bool {
        Self.state.withLock { state in
            guard !state.redirected else { return false }
            state.redirected = true
            return true
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}
