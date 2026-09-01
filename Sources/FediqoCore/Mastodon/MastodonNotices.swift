import Foundation

/// Reading a Mastodon inbox: the catch-up, and the connection that keeps it caught up.
///
/// A file of its own, beside `MastodonWrites.swift`, for the same reason that one is: these
/// are the only endpoints here that cannot be asked as a stranger, and keeping them together
/// makes the rule visible rather than remembered.
public extension MastodonClient {
    /// What happened in this inbox, newest page or everything since `after`.
    ///
    /// The kinds are asked for by name. A server that knows `types[]` hands back only what
    /// this build can draw, so a page is forty events a reader will see rather than forty of
    /// which six are moderation notices meant for somebody else; a server too old to know the
    /// parameter ignores it and sends everything, and `asNotice` drops the rest. Either way
    /// the screen is the same — the newer server just does not make us throw a page away.
    func notices(host rawHost: String, owner: String, after: String?, limit: Int,
                 token: String) async throws -> [Notice] {
        let host = Server.normalise(rawHost)
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        // `min_id` is Mastodon's word for "newer than", and it is spoken here and nowhere
        // else. It pages forward, which is what a catch-up wants: the hour that was missed,
        // oldest first, rather than the newest twenty and a hole where the rest was.
        if let after { query.append(URLQueryItem(name: "min_id", value: after)) }
        for kind in Self.askedFor { query.append(URLQueryItem(name: "types[]", value: kind)) }

        let data = try await get(host: host, path: "/api/v1/notifications", query: query, token: token)
        let arrivedAt = Date()
        return try MastodonClient.decoder
            .decode([MastodonDTO.Notification].self, from: data)
            .compactMap { $0.asNotice(from: host, owner: owner, arrivedAt: arrivedAt) }
    }

    /// The kinds worth asking for, spelled the way Mastodon spells them. Derived from
    /// `NoticeKind` rather than listed twice, so a kind added to the enum is asked for by the
    /// next build and cannot be left out of the request by somebody who edited one list.
    static var askedFor: [String] {
        NoticeKind.allCases.map { $0 == .boost ? "reblog" : $0.rawValue }
    }

    /// The events of one inbox as they happen, over one connection held open.
    ///
    /// **Not polling.** #9's first line asks that replies and mentions arrive while the app is
    /// open without anything being asked for on a timer, and this is the whole of how: one
    /// socket per signed-in server, and the server speaks when there is something to say.
    ///
    /// The token goes in a header and never in the query string, although Mastodon accepts it
    /// both ways. A URL is the one part of a request that is written down by everything it
    /// passes — proxies, server logs, crash reports — and an access token that has reached a
    /// log has reached somewhere it cannot be taken back from.
    ///
    /// Nothing here reconnects. The sequence ends when the connection does, saying why, and
    /// what to do about that belongs to `NoticeLoader`: a client is a way of speaking to one
    /// server, and a policy about how hard to try is not part of speaking.
    func noticeStream(host rawHost: String, owner: String, token: String) -> AsyncThrowingStream<Notice, any Error> {
        AsyncThrowingStream { continuation in
            let host = Server.normalise(rawHost)
            var components = URLComponents()
            components.scheme = "wss"
            components.host = host
            components.path = "/api/v1/streaming"
            components.queryItems = [URLQueryItem(name: "stream", value: "user:notification")]

            guard let url = components.url else {
                continuation.finish(throwing: SourceFailure.badHost(host))
                return
            }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let task = session.webSocketTask(with: request)
            // One connection, counted once. A socket that hands over four hundred events is
            // not four hundred requests, and counting it as though it were would make the
            // statistics screen say this app asks other people's servers for far more than it
            // does — which is the one thing that screen exists not to do.
            ledger.record(endpoint: "https://\(host)", failed: false)

            continuation.onTermination = { _ in task.cancel(with: .goingAway, reason: nil) }
            task.resume()

            Task {
                do {
                    while true {
                        let message = try await task.receive()
                        for notice in Self.notices(in: message, from: host, owner: owner) {
                            continuation.yield(notice)
                        }
                    }
                } catch {
                    continuation.finish(throwing: SourceFailure.of(error))
                }
            }
        }
    }

    /// What one frame is worth, which is usually nothing.
    ///
    /// A Mastodon stream carries every kind of event the subscription asked for and a few it
    /// did not — `notifications_merged` when a server folds several into one, and whatever a
    /// future version adds. Anything that is not a notification is silence here rather than an
    /// error: a frame this build has no use for is not a broken connection.
    ///
    /// `payload` is a JSON document inside a JSON string, which is the streaming API's own
    /// shape and not a mistake to be corrected on the way past.
    static func notices(in message: URLSessionWebSocketTask.Message,
                                from host: String, owner: String) -> [Notice] {
        guard case .string(let text) = message, let frame = text.data(using: .utf8) else { return [] }
        guard let envelope = try? MastodonClient.decoder.decode(Envelope.self, from: frame),
              envelope.event == "notification",
              let payload = envelope.payload.data(using: .utf8),
              let notification = try? MastodonClient.decoder.decode(MastodonDTO.Notification.self, from: payload)
        else { return [] }

        // Now, and not the event's own time: this is the moment the device learned of it, and
        // the difference between the two is what a screen shows when it says how late a notice
        // was. Live, it is a fraction of a second. Woken from a pocket, it is not.
        return [notification.asNotice(from: host, owner: owner, arrivedAt: Date())].compactMap { $0 }
    }

    /// The wrapper every streamed event arrives in.
    struct Envelope: Decodable {
        let event: String
        let payload: String
    }
}
