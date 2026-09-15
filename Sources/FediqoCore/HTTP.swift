import Foundation

public protocol HTTPClient: Sendable {
    func data(from url: URL) async throws -> (Data, HTTPURLResponse)
}

/// GET over HTTPS. Tests inject a client; the live one is a URLSession.
public struct URLSessionClient: HTTPClient, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        guard Host.isFetchable(url) else {
            throw URLError(.unsupportedURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Fediqo", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
