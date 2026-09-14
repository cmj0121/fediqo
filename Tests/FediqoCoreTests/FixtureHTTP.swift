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
        }
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

enum Fixtures {
    static func html(_ name: String) -> Data {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: name, withExtension: "html", subdirectory: "html")
            ?? bundle.url(forResource: name, withExtension: "html", subdirectory: "Fixtures/html")
            ?? bundle.url(forResource: name, withExtension: "html")
        {
            return try! Data(contentsOf: url)
        }
        let found = bundle.urls(forResourcesWithExtension: "html", subdirectory: nil) ?? []
        fatalError("missing \(name).html in \(bundle.bundlePath); have \(found)")
    }
}
