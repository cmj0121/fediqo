import Foundation

// The reader's own account at a Mastodon as its owner sees it, and a change to it (#312).
//
// **What is read is the owner's own words**, as the source keeps them for the owner (`source`):
// the plain text the person wrote, never the HTML it is drawn with — sent back, that would be
// the markup as words. Asked of a real one first: a change is answered with the account whole,
// in the same shape as the account check (`MastodonPartsCaptures`), and a refusal of what was
// sent is a 422 whose `details` names each thing refused. **A GoToSocial never says whether an
// account hides its lists**, and a Mastodon says `null` where the person never chose: either is
// "not said", never "no" (`servers/gotosocial/FINDINGS.md` item 5).
//
// **The lock is the held words', never a 403's text.** A GoToSocial's 403 names no missing
// word and is not a Mastodon's sentence (item 2), so a 403 is the part's lock only where the
// sign-in does not hold the part — and the source forbidding it where it does.
//
// **Nothing here writes anywhere on this device**: what is read lands in what it returns.

/// The reader's own account as its owner sees it: what a change starts from.
public struct OwnAccount: Sendable, Hashable {
    /// One of the account's extra fields: a name and its value, as the owner wrote them.
    public struct Field: Sendable, Hashable {
        public var name: String
        public var value: String
        /// When the source checked that the value's link points back. Read, never sent: the
        /// source keeps it while the value stays the same.
        public var verifiedAt: Date?

        public init(name: String, value: String, verifiedAt: Date? = nil) {
            self.name = name
            self.value = value
            self.verifiedAt = verifiedAt
        }
    }

    /// The name drawn for the account; empty where none is set and the handle is drawn.
    public var name: String
    /// The words about the account, as the owner wrote them.
    public var words: String
    /// The extra fields, in the source's order.
    public var fields: [Field]
    /// Whether somebody may follow without being agreed to — the source's `locked`, turned
    /// round. Nothing where the source did not say.
    public var followWithoutAsking: Bool?
    /// Whether the account may be found and suggested. Nothing where the source did not say.
    public var findable: Bool?
    /// Whether others may see the account's lists of followers and followed — the source's
    /// `hide_collections`, turned round. Nothing where the source did not say.
    public var listsShown: Bool?

    public init(
        name: String = "", words: String = "", fields: [Field] = [], followWithoutAsking: Bool? = nil,
        findable: Bool? = nil, listsShown: Bool? = nil
    ) {
        self.name = name
        self.words = words
        self.fields = fields
        self.followWithoutAsking = followWithoutAsking
        self.findable = findable
        self.listsShown = listsShown
    }
}

/// One thing of an own account a change sends and a refusal may name.
public enum OwnRow: String, Sendable, CaseIterable {
    case name, words, fields, followWithoutAsking, findable, listsShown
}

/// How long a source says each thing of an own account may be, and how many fields it may have.
/// **Only what the host states**: nothing is a limit not said, which the source's refusal names
/// if one is passed.
public struct OwnLimits: Sendable, Hashable {
    public var name: Int?
    public var words: Int?
    public var fields: Int?
    public var fieldName: Int?
    public var fieldValue: Int?

    public init(name: Int? = nil, words: Int? = nil, fields: Int? = nil, fieldName: Int? = nil, fieldValue: Int? = nil) {
        self.name = name
        self.words = words
        self.fields = fields
        self.fieldName = fieldName
        self.fieldValue = fieldValue
    }

    public static let none = OwnLimits()
}

/// What the source answered a change with: the account as its owner sees it, the person it is
/// as anyone sees it, and how many people ask to follow it.
public struct OwnAnswer: Sendable, Hashable {
    public let account: OwnAccount
    public let person: Person
    /// How many ask to follow the account (`source.follow_requests_count`). Nothing where the
    /// source did not say, or said a figure below nothing.
    public let asking: Int?

    public init(account: OwnAccount, person: Person, asking: Int?) {
        self.account = account
        self.person = person
        self.asking = asking
    }
}

public enum OwnAccountError: Error, Equatable, Sendable {
    /// The sign-in does not hold the account part (`MastodonPart.account`): asking for it is
    /// what changes this.
    case locked
    /// The source would not take the change (422): its sentence, made fit for a line — empty
    /// where it sent none — and for each thing it named, its first word about it, likewise
    /// (empty where it said nothing of it). Nothing of the account changed there.
    case refused(sentence: String, rows: [OwnRow: String])
    /// The source refused a sign-in that holds the account part (403).
    case forbidden
    /// The source answered, and not with an account its owner sees.
    case unreadable
}

/// A Mastodon asked for the reader's own account and to change it: the account check
/// (`/api/v1/accounts/verify_credentials`), `/api/v1/accounts/update_credentials`, and the
/// limits the host states in `/api/v2/instance` — **through the one signed-in door**.
public struct MastodonOwnAccount: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let changePath = "/api/v1/accounts/update_credentials"
    static let documentPath = "/api/v2/instance"
    /// How much of a refusal is read: a sentence and the names beside it, not a page.
    static let refusalLength = 16_384
    /// How long the source's sentence, and each of its words about a row, is kept.
    static let sentenceLength = 200

    /// The account as its owner sees it now.
    public func read() async throws -> OwnAccount {
        try Self.account(from: try await door.get(path: MastodonAuthorized.accountCheck))
    }

    /// The limits the host states for an own account. Those it does not state are none.
    public func limits() async throws -> OwnLimits {
        Self.limits(from: try await door.get(path: Self.documentPath))
    }

    /// Sends what changed from `before` to `after` and hands back what the source answers.
    /// **Only what changed is sent** — and the fields whole where any of them did, since the
    /// source replaces the set. Where nothing changed nothing is asked: nothing is handed back.
    ///
    /// Throws `.refused` where the source would not take it (422); `.forbidden` for a 403 to a
    /// sign-in that holds the account part, `.locked` for one to a sign-in that does not; and
    /// what the door threw otherwise.
    public func change(from before: OwnAccount, to after: OwnAccount) async throws -> OwnAnswer? {
        let form = Self.form(from: before, to: after)
        guard !form.isEmpty else { return nil }
        let body: Data
        do {
            body = try await door.patch(path: Self.changePath, form: form)
        } catch let refused as MastodonUnprocessable {
            throw Self.refusal(from: refused.body)
        } catch MastodonAuthError.http(403) {
            throw MastodonParts.holds(.account, in: door.token.scopes) ? OwnAccountError.forbidden : .locked
        }
        return try Self.answer(from: body, host: door.token.host)
    }

    /// The form that changes `before` into `after`: each thing that differs, in `OwnRow`'s
    /// order. A switch the change leaves unsaid is not sent.
    static func form(from before: OwnAccount, to after: OwnAccount) -> [(String, String)] {
        var form: [(String, String)] = []
        if after.name != before.name { form.append(("display_name", after.name)) }
        if after.words != before.words { form.append(("note", after.words)) }
        if after.fields.map(\.pair) != before.fields.map(\.pair) {
            // One field with nothing in it is no field: the set the source keeps is emptied.
            let fields = after.fields.isEmpty ? [OwnAccount.Field(name: "", value: "")] : after.fields
            for (place, field) in fields.enumerated() {
                form.append(("fields_attributes[\(place)][name]", field.name))
                form.append(("fields_attributes[\(place)][value]", field.value))
            }
        }
        // The source's words for the two turned round are said the other way.
        for (key, now, was) in [
            ("locked", after.followWithoutAsking.map(!), before.followWithoutAsking.map(!)),
            ("discoverable", after.findable, before.findable),
            ("hide_collections", after.listsShown.map(!), before.listsShown.map(!)),
        ] {
            if let now, now != was { form.append((key, now ? "true" : "false")) }
        }
        return form
    }

    /// A change's answer read: the account as its owner sees it, the person it is, and how many
    /// ask to follow it — all out of the one body. `unreadable` where any of the first two is not.
    static func answer(from body: Data, host: String) throws -> OwnAnswer {
        let account = try account(from: body)
        guard let person = try? MastodonPeople.person(from: body, source: Source(host: host, kind: .mastodon)) else {
            throw OwnAccountError.unreadable
        }
        return OwnAnswer(account: account, person: person, asking: MastodonWho.said(body, at: host).asking)
    }

    /// An account as its owner sees it, read out of an answer. `unreadable` where the answer
    /// is no account, or one with none of the owner's own words (`source`).
    static func account(from body: Data) throws -> OwnAccount {
        typealias L = StatusDTO.Lenient
        struct Field: Decodable, Sendable {
            let name: L<String>?
            let value: L<String>?
            let verifiedAt: L<String>?
        }
        struct Source: Decodable, Sendable {
            let note: L<String>?
            let fields: L<[L<Field>]>?
            let discoverable: L<Bool>?
            let hideCollections: L<Bool>?
        }
        struct Wire: Decodable, Sendable {
            let displayName: L<String>?
            let locked: L<Bool>?
            let discoverable: L<Bool>?
            let hideCollections: L<Bool>?
            let source: Source
        }
        guard let wire = try? MastodonJSON.decoder.decode(Wire.self, from: body) else {
            throw OwnAccountError.unreadable
        }
        let source = wire.source
        let fields = (source.fields?.value ?? []).compactMap(\.value).map {
            OwnAccount.Field(
                name: $0.name?.value ?? "", value: $0.value?.value ?? "",
                verifiedAt: $0.verifiedAt?.value.flatMap(MastodonJSON.date(from:))
            )
        }
        return OwnAccount(
            name: wire.displayName?.value ?? "", words: source.note?.value ?? "", fields: fields,
            followWithoutAsking: wire.locked?.value.map(!),
            findable: source.discoverable?.value ?? wire.discoverable?.value,
            listsShown: (source.hideCollections?.value ?? wire.hideCollections?.value).map(!)
        )
    }

    /// The limits a host's document states for an own account; a document that states none,
    /// or is no document, states none.
    static func limits(from body: Data) -> OwnLimits {
        typealias L = StatusDTO.Lenient
        struct Accounts: Decodable, Sendable {
            let maxDisplayNameLength: L<Int>?
            let maxNoteLength: L<Int>?
            let maxProfileFields: L<Int>?
            let profileFieldNameLimit: L<Int>?
            let profileFieldValueLimit: L<Int>?
        }
        struct Configuration: Decodable, Sendable { let accounts: L<Accounts>? }
        struct Document: Decodable, Sendable { let configuration: L<Configuration>? }
        guard let accounts = (try? MastodonJSON.decoder.decode(Document.self, from: body))?.configuration?.value?.accounts?.value else {
            return .none
        }
        // A limit of nothing or less is a host that said something useless, not one.
        func stated(_ limit: L<Int>?) -> Int? { limit?.value.flatMap { $0 > 0 ? $0 : nil } }
        return OwnLimits(
            name: stated(accounts.maxDisplayNameLength), words: stated(accounts.maxNoteLength),
            fields: stated(accounts.maxProfileFields), fieldName: stated(accounts.profileFieldNameLimit),
            fieldValue: stated(accounts.profileFieldValueLimit)
        )
    }

    /// What a 422 says was refused: its sentence, and each row its `details` names with the
    /// first `description` given of it. A name of the source's this app does not send is in
    /// the sentence alone.
    static func refusal(from body: Data) -> OwnAccountError {
        guard body.count <= refusalLength,
              let said = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return .refused(sentence: "", rows: [:]) }
        func line(_ raw: Any?) -> String {
            guard let raw = raw as? String else { return "" }
            return LineText.oneLine(raw, limit: sentenceLength).trimmingCharacters(in: .whitespaces)
        }
        var rows: [OwnRow: String] = [:]
        for (name, about) in (said["details"] as? [String: Any]) ?? [:] {
            guard let row = row(name) else { continue }
            let first = line(((about as? [Any])?.first as? [String: Any])?["description"])
            // Two names for one row — the fields are named either way — keep the one that says something.
            if rows[row]?.isEmpty ?? true { rows[row] = first }
        }
        return .refused(sentence: line(said["error"]), rows: rows)
    }

    /// The row a source's name for a thing of the account is, by the names it is sent under.
    private static func row(_ name: String) -> OwnRow? {
        switch name {
        case "display_name": .name
        case "note": .words
        case "locked": .followWithoutAsking
        case "discoverable": .findable
        case "hide_collections": .listsShown
        default: name.hasPrefix("fields") ? .fields : nil
        }
    }
}

extension OwnAccount.Field {
    /// What a change sends of a field: when it was verified is the source's.
    fileprivate var pair: [String] { [name, value] }
}
