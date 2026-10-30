import Foundation

/// The wire every admin part of a Mastodon server is asked over: what a refusal for want of
/// standing reads as, how a stretch is listed, how one is read back, and how one is written.
extension MastodonAuthorized {
    /// A refusal for want of standing (403) told from every other: what an account without the
    /// role is answered, whatever its sign-in holds.
    func adminAsked<T>(_ ask: () async throws -> T) async throws -> T {
        do {
            return try await ask()
        } catch MastodonAuthError.http(403) {
            throw MastodonAdminError.notAllowed
        }
    }

    /// A stretch at `path` older than `next`, each made from what the server says of it.
    func adminList<DTO: Decodable & Sendable, Item: Sendable & Equatable>(
        _ path: String, after next: String?, _ made: (DTO) -> Item?
    ) async throws -> FederationStretch<Item> {
        let (body, link) = try await adminAsked { try await getLinked(path: path, query: try MastodonPage.older(than: next)) }
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<DTO>].self, from: body) else {
            throw MastodonAdminError.unreadable
        }
        let onward: String?
        do {
            onward = try MastodonLink.next(in: link)
        } catch {
            throw MastodonAdminError.unreadable
        }
        guard onward == nil || onward != next else { throw PagingError.notPaging }
        return FederationStretch(items: read.compactMap { $0.value.flatMap(made) }, next: onward)
    }

    /// The one item `body` says, or unreadable.
    func adminRead<DTO: Decodable, Item>(_ body: Data, _ made: (DTO) -> Item?) throws -> Item {
        guard let said = try? MastodonJSON.decoder.decode(DTO.self, from: body), let item = made(said) else {
            throw MastodonAdminError.unreadable
        }
        return item
    }

    /// `form` sent to `path` by `method`: a refusal in words told as such, an address the server
    /// has not as not found.
    func adminWrite(_ path: String, _ method: String, form: [(String, String)]?) async throws -> Data {
        try await adminAsked {
            do {
                return try await actAtAddress(path: path, method: method, form: form)
            } catch let refused as MastodonUnprocessable {
                guard case .refused(let sentence) = AccountPartError.refusal(from: refused.body) else {
                    throw MastodonAdminError.unreadable
                }
                throw MastodonAdminError.refused(sentence: sentence)
            } catch MastodonHostMoreError.noSuchAddress {
                throw MastodonAuthError.http(404)
            }
        }
    }

    /// `form` posted to `path` for figures: an address the server has not as not found, any
    /// other refusal as the server sends it.
    func adminFigures(_ path: String, form: [(String, String)]) async throws -> Data {
        try await adminAsked {
            do {
                return try await actAtAddress(path: path, method: "POST", form: form)
            } catch MastodonHostMoreError.noSuchAddress {
                throw MastodonAuthError.http(404)
            }
        }
    }
}
