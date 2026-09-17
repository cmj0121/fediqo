import Foundation
@testable import FediqoCore

enum FixtureHTTPError: Error {
    case unmapped
    case unreachable
}

actor FixtureHTTP: HTTPClient {
    enum Outcome: Sendable {
        case body(Data, status: Int = 200)
        case text(String, status: Int = 200)
        case fail
        /// The reader walked away. `URLError(.cancelled)` and **not** `CancellationError`, because
        /// that is what `URLSessionClient.data(from:)` actually throws — a harness that threw the
        /// tidy one would be testing a translation the app never has to make.
        case cancelled
    }

    private let routes: [String: Outcome]
    private(set) var requested: [URL] = []

    init(_ routes: [String: Outcome] = [:]) {
        self.routes = routes
    }

    var paths: [String] {
        requested.map { url in
            url.path.isEmpty ? "/" : url.path
        }
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        requested.append(url)
        let path = url.path.isEmpty ? "/" : url.path
        guard let outcome = routes[path] ?? routes[url.absoluteString] else {
            throw FixtureHTTPError.unmapped
        }
        switch outcome {
        case .body(let data, let status):
            return (data, Self.response(url, status))
        case .text(let text, let status):
            return (Data(text.utf8), Self.response(url, status))
        case .fail:
            throw FixtureHTTPError.unreachable
        case .cancelled:
            throw URLError(.cancelled)
        }
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
