import Foundation

/// The posts an account has written and not sent yet (#110).
extension MastodonClient {
    /// `GET /api/v1/scheduled_statuses`, as the account and about nobody else.
    ///
    /// **What comes back is not a status.** It is the parameters a post will be made from and
    /// when — no address, no counts, nobody has replied to it — so it is read into
    /// `ScheduledPost` rather than into `Post`. A row that drew it as a post would be answering
    /// questions nobody has an answer to yet.
    ///
    /// In the order they will go out, which is the order that means anything here: a list of
    /// unsent posts newest-first would put the one going out last at the top.
    public func scheduled(as account: ActingAccount) async throws -> [ScheduledPost] {
        let data = try await get(host: account.host, path: "/api/v1/scheduled_statuses",
                                 query: [], token: account.token)
        return try Self.decoder.decode([MastodonDTO.Scheduled].self, from: data)
            .compactMap { $0.asScheduledPost(on: account.host) }
            .sorted { $0.when < $1.when }
    }

    /// `DELETE /api/v1/scheduled_statuses/:id` — the one thing that can be done to a post that
    /// has not happened.
    public func cancelScheduled(_ id: String, as account: ActingAccount) async throws {
        _ = try await write("DELETE", "/api/v1/scheduled_statuses/\(id)", as: account)
    }
}

extension MastodonDTO {
    /// One unsent post, as `/api/v1/scheduled_statuses` gives it.
    struct Scheduled: Decodable, Sendable {
        struct Parameters: Decodable, Sendable {
            let text: String?
            let visibility: String?
        }

        let id: String
        let scheduledAt: String
        let params: Parameters
        let mediaAttachments: [MediaAttachment]?

        /// Nothing where the server gave a time nobody can read. A post that will go out at an
        /// unknown moment is not a thing to draw a time against, and inventing one would be the
        /// row saying something the server did not.
        func asScheduledPost(on host: String) -> ScheduledPost? {
            guard let when = MastodonClient.date(from: scheduledAt) else { return nil }
            return ScheduledPost(id: id, host: host,
                                 text: params.text ?? "",
                                 when: when,
                                 audience: params.visibility.flatMap(Audience.init(rawValue:)),
                                 attachments: mediaAttachments?.count ?? 0)
        }
    }
}
