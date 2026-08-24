import Foundation
@testable import FediqoCore

/// A transport that answers from a table instead of the network.
///
/// Routes are keyed by host, and every suite using this picks hostnames of its own, so the
/// suites stay independent without having to run one at a time.
final class StubRoutes: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (status: Int, body: Data)] = [:]
    /// Every request in the order it arrived — the one log both views below read from.
    private var log: [(key: String, request: CapturedRequest)] = []

    func on(_ host: String, _ path: String, status: Int, body: String = "[]") {
        lock.withLock { routes["\(host)|\(path)"] = (status, Data(body.utf8)) }
    }

    func answer(for url: URL, method: String, body: Data, authorization: String?) -> (status: Int, body: Data) {
        let key = "\(url.host() ?? "")|\(url.path())"
        return lock.withLock {
            log.append((key, CapturedRequest(method: method, body: String(decoding: body, as: UTF8.self), authorization: authorization)))
            return routes[key] ?? (404, Data("{}".utf8))
        }
    }

    /// The paths asked of one host, in the order they were asked.
    func paths(for host: String) -> [String] {
        lock.withLock {
            log.map(\.key).filter { $0.hasPrefix("\(host)|") }.map { String($0.dropFirst(host.count + 1)) }
        }
    }

    /// What was actually sent to one endpoint, in the order it was sent.
    func requests(for host: String, _ path: String) -> [CapturedRequest] {
        lock.withLock { log.filter { $0.key == "\(host)|\(path)" }.map(\.request) }
    }
}

/// One request as the stub saw it, body and all.
struct CapturedRequest: Sendable {
    let method: String
    let body: String
    let authorization: String?

    /// The form body read back into fields, for asserting on what a POST said.
    var fields: [String: String] {
        Dictionary(uniqueKeysWithValues: body.split(separator: "&").compactMap { pair in
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.count == 2,
                  let name = halves[0].removingPercentEncoding,
                  let value = halves[1].removingPercentEncoding else { return nil }
            return (name, value)
        })
    }
}

let stubRoutes = StubRoutes()

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let answer = stubRoutes.answer(
            for: url,
            method: request.httpMethod ?? "GET",
            body: requestBody(),
            authorization: request.value(forHTTPHeaderField: "Authorization")
        )
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a POST's body to a protocol as a stream, not as `httpBody`.
    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let capacity = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: capacity)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// A Mastodon server the stub answers for.
func makeServer(_ host: String) -> Server {
    Server(host: host, socialProtocol: .mastodon, title: host)
}

/// A loader that only speaks Mastodon, through the stub.
func stubbedLoader(store: LocalStore? = nil) -> TimelineLoader {
    TimelineLoader(registry: SourceRegistry(clients: [.mastodon: MastodonClient(session: stubbedSession())]), store: store)
}

/// One status, enough to prove a list came back.
let oneStatusJSON = """
[{
  "id": "1",
  "uri": "https://example/users/a/statuses/1",
  "url": "https://example/@a/1",
  "created_at": "2026-08-21T10:00:00.000Z",
  "content": "<p>hello</p>",
  "account": { "id": "10", "url": "https://example/@a", "username": "a", "acct": "a", "display_name": "Ada", "avatar": null },
  "media_attachments": [],
  "tags": []
}]
"""
