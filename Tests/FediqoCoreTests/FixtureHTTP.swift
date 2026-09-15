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
    static func html(_ name: String) -> Data { resource(name, ext: "html", folder: "html") }
    static func json(_ name: String) -> Data { resource(name, ext: "json", folder: "json") }

    private static func resource(_ name: String, ext: String, folder: String) -> Data {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: folder)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/\(folder)")
            ?? bundle.url(forResource: name, withExtension: ext)
        {
            return try! Data(contentsOf: url)
        }
        let found = bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        fatalError("missing \(name).\(ext) in \(bundle.bundlePath); have \(found)")
    }
}
