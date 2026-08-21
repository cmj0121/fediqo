import Foundation
@testable import FediqoCore

/// A transport that answers from a table instead of the network.
///
/// Routes are keyed by host, and every suite using this picks hostnames of its own, so the
/// suites stay independent without having to run one at a time.
final class StubRoutes: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (status: Int, body: Data)] = [:]
    private var asked: [String] = []

    func on(_ host: String, _ path: String, status: Int, body: String = "[]") {
        lock.withLock { routes["\(host)|\(path)"] = (status, Data(body.utf8)) }
    }

    func answer(for url: URL) -> (status: Int, body: Data) {
        let key = "\(url.host() ?? "")|\(url.path())"
        return lock.withLock {
            asked.append(key)
            return routes[key] ?? (404, Data("{}".utf8))
        }
    }

    /// The paths asked of one host, in the order they were asked.
    func paths(for host: String) -> [String] {
        lock.withLock {
            asked.filter { $0.hasPrefix("\(host)|") }.map { String($0.dropFirst(host.count + 1)) }
        }
    }
}

let stubRoutes = StubRoutes()

final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let answer = stubRoutes.answer(for: url)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// One status, enough to prove a list came back.
let oneStatusJSON = """
[{
  "id": "1",
  "uri": "https://example/users/a/statuses/1",
  "url": "https://example/@a/1",
  "created_at": "2026-08-21T10:00:00.000Z",
  "content": "<p>hello</p>",
  "account": { "username": "a", "acct": "a", "display_name": "Ada", "avatar": null },
  "media_attachments": []
}]
"""
