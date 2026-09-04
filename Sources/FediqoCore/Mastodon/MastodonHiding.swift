import Foundation

/// What a server says it is hiding for this account, and how to stop it (#114).
extension MastodonClient {
    /// `GET /api/v1/{mutes,blocks,domain_blocks}`, as the account and about nobody else.
    ///
    /// **The server's answer and not this device's record.** A mute made on a phone is a mute
    /// this app has never heard of, and a list built from what this device asked for would leave
    /// the reader unable to undo most of what is standing — which is the trap #114 is about,
    /// with a window in it.
    ///
    /// The two shapes are two decodings: accounts for the first two, bare hostnames for the
    /// third, which Mastodon answers with an array of strings.
    public func hidden(_ which: Hiding, as account: ActingAccount) async throws -> [Hidden.Subject] {
        let data = try await get(host: account.host, path: "/api/v1/\(which.path)",
                                 query: [URLQueryItem(name: "limit", value: "80")],
                                 token: account.token)
        guard which.isAboutPeople else {
            return try Self.decoder.decode([String].self, from: data).map(Hidden.Subject.server)
        }
        return try Self.decoder.decode([MastodonDTO.Account].self, from: data)
            .map { .person($0.asProfile(on: account.host)) }
    }

    /// Stop hiding one of them — `unmute`, `unblock`, or a `DELETE` of the domain block.
    ///
    /// The account is looked up by handle rather than sent as a URI, because these endpoints
    /// want the id on the server being told — the same lookup a mute already needs, and the
    /// same reason.
    public func stopHiding(_ which: Hiding, _ subject: Hidden.Subject,
                           as account: ActingAccount) async throws {
        switch (which, subject) {
        case (.blockedServers, .server(let host)):
            _ = try await write("DELETE", "/api/v1/domain_blocks",
                                fields: ["domain": host], as: account)
        case (.muted, .person(let profile)), (.blocked, .person(let profile)):
            guard let id = try await searchAccount(profile.handle, as: account) else {
                throw SourceFailure.notItsPost(profile.handle)
            }
            let verb = which == .muted ? "unmute" : "unblock"
            _ = try await write("POST", "/api/v1/accounts/\(id)/\(verb)", as: account)
        // A person on the list of servers, or a server on a list of people, is a pairing this
        // app cannot make — and refusing it out loud beats sending a request shaped from a
        // guess about which the caller meant.
        default:
            throw SourceFailure.notItsPost(subject.id)
        }
    }
}
