import Foundation

/// What a collection is to be: all of what making sends.
public struct CollectionDraft: Hashable, Sendable {
    public var name: String
    public var words: String
    public var sensitive: Bool
    public var discoverable: Bool

    public init(name: String = "", words: String = "", sensitive: Bool = false, discoverable: Bool = true) {
        self.name = name
        self.words = words
        self.sensitive = sensitive
        self.discoverable = discoverable
    }

    /// What `collection` says now, as a draft of itself. What it does not say is the default.
    public init(_ collection: PersonCollection) {
        self.init(
            name: collection.name, words: collection.words ?? "", sensitive: collection.sensitive ?? false,
            discoverable: collection.discoverable ?? true
        )
    }
}

/// A collection the source did not take, or answered with what could not be read.
public enum MastodonCollectionError: Error, Equatable, Sendable {
    /// Refused before anything was asked: a blank name, nothing changed, an id unfit for a path.
    case invalid
    /// The sign-in does not hold the word this wants. Nothing was asked.
    case locked
    /// The source said the sign-in was not issued with the word.
    case outOfScope
    /// The source would not let this person do this (403): not theirs, not in it, or somebody who
    /// does not let themselves be added. Its sentence is the same for all, so none is carried.
    case notAllowed
    /// The source would not do it (422), in its own sentence made fit for a line.
    case refused(sentence: String)
    /// The person has as many as the source allows them. The source's own sentence for this, on
    /// 4.6.6, is a failure to find one (`MastodonCollectionCaptures.tooManyCollections`).
    case tooMany
    /// The collection, the place or the person is not there.
    case gone
    /// A read that could not be read, or a refusal that could not. Nothing was taken.
    case unreadable
    /// The source took a write (2xx), and what it answered could not be read: it has happened.
    case tookUnreadable
}

/// A sign-in's own collections, and changes to any (#433), `/api/v1/collections`.
///
/// **Asked of a real one first** (`MastodonCollectionCaptures`). Each goes through the one
/// signed-in door and only where the sign-in holds the word: nothing is sent otherwise.
///
/// **Nothing here writes anywhere on this device.** A refusal or a failure throws, and whoever
/// was told the change writes it down, only after this returns. **A lost answer is not a
/// refusal**: what it asked may have landed, so whoever asked reads again and does not resend.
///
/// **The source is the judge of every limit.** How many a person may have comes from their role,
/// and adding one by one was taken past 25 where making was refused it, so no limit is here.
public struct MastodonCollectionWrites: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v1/collections"
    /// As many as a read is told to send: the most the source takes.
    static let longest = "100"

    /// `accountID`'s collections as this sign-in may see them: its own, the ones not to be found
    /// among them. Throws `MastodonHostMoreError.noSuchAddress` where the host has no such address.
    public func of(_ accountID: String) async throws -> [PersonCollection] {
        try Self.segment(accountID)
        let body = try await read("/api/v1/accounts/\(accountID)/collections", query: [URLQueryItem(name: "limit", value: Self.longest)])
        guard let list = CollectionWire.list(body) else { throw MastodonCollectionError.unreadable }
        return list
    }

    /// One whole, as this sign-in may see it: to its owner, those who are pending too.
    public func whole(_ id: String, source: Source) async throws -> CollectionRead {
        try Self.segment(id)
        guard source.host == door.token.host else { throw MastodonRequestError.invalidURL }
        guard let read = CollectionWire.whole(try await read("\(Self.path)/\(id)"), source: source) else {
            throw MastodonCollectionError.unreadable
        }
        return read
    }

    /// Makes one. Both choices are sent: the source wants them.
    public func make(_ draft: CollectionDraft) async throws -> PersonCollection {
        let name = try Self.named(draft.name)
        var form: [(String, String)] = [
            ("name", name), ("sensitive", draft.sensitive ? "true" : "false"), ("discoverable", draft.discoverable ? "true" : "false"),
        ]
        let words = draft.words.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { form.append(("description", words)) }
        return try Self.collection(try await wrote(path: Self.path, method: "POST", form: form))
    }

    /// Sends what differs between `before` and `after`, and only that: a change the source made
    /// meanwhile to anything else stands. Nothing differing is `invalid`, and nothing is asked.
    public func change(_ id: String, from before: CollectionDraft, to after: CollectionDraft) async throws -> PersonCollection {
        try Self.segment(id)
        let name = try Self.named(after.name)
        let words = after.words.trimmingCharacters(in: .whitespacesAndNewlines)
        var form: [(String, String)] = []
        if name != before.name { form.append(("name", name)) }
        if words != before.words { form.append(("description", words)) }
        if after.sensitive != before.sensitive { form.append(("sensitive", after.sensitive ? "true" : "false")) }
        if after.discoverable != before.discoverable { form.append(("discoverable", after.discoverable ? "true" : "false")) }
        guard !form.isEmpty else { throw MastodonCollectionError.invalid }
        return try Self.collection(try await wrote(path: "\(Self.path)/\(id)", method: "PATCH", form: form))
    }

    /// Removes one. The source answers nothing.
    public func remove(_ id: String) async throws {
        try Self.segment(id)
        _ = try await wrote(path: "\(Self.path)/\(id)", method: "DELETE")
    }

    /// Puts `accountID` in `id`, and says how it stands: someone of another server is pending
    /// until they consent.
    public func add(_ accountID: String, to id: String) async throws -> CollectionItem {
        try Self.segment(id)
        try Self.segment(accountID)
        let body = try await wrote(path: "\(Self.path)/\(id)/items", method: "POST", form: [("account_id", accountID)])
        guard let item = CollectionWire.item(body) else { throw MastodonCollectionError.tookUnreadable }
        return item
    }

    /// Takes the place `item` out of `id`, as its owner.
    public func drop(_ item: String, from id: String) async throws {
        try Self.segment(id)
        try Self.segment(item)
        _ = try await wrote(path: "\(Self.path)/\(id)/items/\(item)", method: "DELETE")
    }

    /// Takes the reader out of another's `id`, by their own place `item` in it. Done twice, the
    /// source answers the same; and it does not let them be added back.
    public func leave(_ item: String, from id: String) async throws {
        try Self.segment(id)
        try Self.segment(item)
        _ = try await wrote(path: "\(Self.path)/\(id)/items/\(item)/revoke", method: "POST")
    }

    private func wrote(path: String, method: String, form: [(String, String)]? = nil) async throws -> Data {
        guard MastodonParts.holds(.changing, of: .collections, in: door.token.scopes) else { throw MastodonCollectionError.locked }
        do {
            return try await door.actAtAddressInScope(path: path, method: method, form: form)
        } catch let refused as MastodonUnprocessable {
            throw Self.refusal(from: refused.body)
        } catch {
            throw Self.told(error)
        }
    }

    private func read(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard MastodonParts.holds(.seeing, of: .collections, in: door.token.scopes) else { throw MastodonCollectionError.locked }
        do {
            return try await door.getAtAddressInScope(path: path, query: query)
        } catch {
            throw Self.told(error)
        }
    }

    /// A failure told apart. Anything else is not the source's word on the collection — a
    /// sign-out, a walk away, no such address, an answer lost — and is passed on as it is.
    private static func told(_ error: any Error) -> any Error {
        switch error {
        case is MastodonScopeError: return MastodonCollectionError.outOfScope
        case MastodonAuthError.http(403): return MastodonCollectionError.notAllowed
        case MastodonAuthError.http(404): return MastodonCollectionError.gone
        default: return error
        }
    }

    /// A 422, in either of the two shapes it comes in: a sentence, or a sentence and its details
    /// inside one more `error`. A count the source's own words fail on is said as `tooMany`.
    static func refusal(from body: Data) -> MastodonCollectionError {
        guard body.count <= AccountPartError.refusalLength,
              let said = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return .unreadable }
        let inner = said["error"] as? [String: Any]
        let base = (inner?["details"] as? [String: Any])?["base"] as? [[String: Any]]
        if base?.contains(where: { $0["error"] as? String == "ERR_TOO_MANY" }) == true { return .tooMany }
        guard let raw = (said["error"] as? String) ?? (inner?["error"] as? String) else { return .unreadable }
        let sentence = LineText.oneLine(raw, limit: AccountPartError.sentenceLength).trimmingCharacters(in: .whitespaces)
        return sentence.isEmpty ? .unreadable : .refused(sentence: sentence)
    }

    private static func collection(_ body: Data) throws -> PersonCollection {
        guard let collection = CollectionWire.one(body) else { throw MastodonCollectionError.tookUnreadable }
        return collection
    }

    private static func named(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MastodonCollectionError.invalid }
        return name
    }

    private static func segment(_ id: String) throws {
        guard ListSubscription.isPathSegment(id) else { throw MastodonCollectionError.invalid }
    }
}
