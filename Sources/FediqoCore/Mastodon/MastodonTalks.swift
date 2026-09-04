import Foundation

/// The conversations an account is in (#109).
extension MastodonClient {
    /// `GET /api/v1/conversations`, as the account and about nobody else.
    ///
    /// **What comes back is not a page of posts**, so it is not stored as one. A private
    /// conversation has the sharpest edges in this app — a post drawn in the wrong list is a
    /// post shown to somebody it was not for — and the surest way for one not to leak into a
    /// reading it is not for is for it never to be written where a reading can find it. The last
    /// post of each is drawn from this answer and nowhere else; opening one is `thread`, which
    /// asks the server about that post and is already built.
    ///
    /// Not paged. Mastodon pages this endpoint, and a first page is what a reader is looking at
    /// when they ask who they are talking to; walking back through old conversations is a
    /// different question and this app is not asking it yet.
    public func conversations(as account: ActingAccount) async throws -> [Talk] {
        let data = try await get(host: account.host, path: "/api/v1/conversations",
                                 query: [URLQueryItem(name: "limit", value: "40")],
                                 token: account.token)
        return try Self.decoder.decode([MastodonDTO.Conversation].self, from: data)
            .map { $0.asTalk(on: account.host) }
    }
}

extension MastodonDTO {
    /// One conversation, as `/api/v1/conversations` gives it.
    struct Conversation: Decodable, Sendable {
        let id: String
        let unread: Bool
        let accounts: [Account]
        let lastStatus: Status?

        func asTalk(on host: String) -> Talk {
            Talk(id: id, host: host,
                 people: accounts.map { $0.asProfile(on: host) },
                 last: lastStatus?.asPost(from: host),
                 unread: unread)
        }
    }
}
