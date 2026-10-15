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
// sign-in does not hold the part — and a refusal where it does.
//
// **Nothing here writes anywhere on this device**: what is read lands in what it returns.

/// The reader's own account as its owner sees it: what a change starts from and is answered with.
public struct OwnAccount: Sendable, Hashable {
    /// One of the account's extra fields: a name and its value, as the owner wrote them.
    public struct Field: Sendable, Hashable {
        public var name: String
        public var value: String
        /// Whether the source has checked that the value's link points back. Read, never sent:
        /// the source keeps it while the value stays the same.
        public var verified: Bool

        public init(name: String, value: String, verified: Bool = false) {
            self.name = name
            self.value = value
            self.verified = verified
        }
    }

    /// The name drawn for the account; empty where none is set and the handle is drawn.
    public var name: String
    /// The words about the account, as the owner wrote them.
    public var words: String
    /// The extra fields, in the source's order.
    public var fields: [Field]
    /// Whether somebody must be agreed to before they follow. Nothing where the source did not say.
    public var locked: Bool?
    /// Whether the account may be found and suggested. Nothing where the source did not say.
    public var discoverable: Bool?
    /// Whether others are kept from the account's lists of followers and followed. Nothing where
    /// the source did not say.
    public var hidesLists: Bool?

    public init(
        name: String = "", words: String = "", fields: [Field] = [], locked: Bool? = nil,
        discoverable: Bool? = nil, hidesLists: Bool? = nil
    ) {
        self.name = name
        self.words = words
        self.fields = fields
        self.locked = locked
        self.discoverable = discoverable
        self.hidesLists = hidesLists
    }
}

/// One thing of an own account a change sends and a refusal may name.
public enum OwnAccountItem: String, Sendable, CaseIterable {
    case name, words, fields, locked, discoverable, hidesLists
}

/// How long a source says each thing of an own account may be, and how many fields it may have.
/// **Only what the host states**: nothing is a limit not said, which the source's refusal names
/// if one is passed.
public struct OwnAccountLimits: Sendable, Hashable {
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

    public static let none = OwnAccountLimits()
}

/// What the source would not take of a change: the things it named, and its sentence.
public struct OwnAccountRefusal: Sendable, Hashable {
    /// What was refused, in `OwnAccountItem`'s order. Nothing where the source named nothing.
    public let what: [OwnAccountItem]
    /// The source's own sentence, made fit for a line. Nothing where it sent none.
    public let said: String?

    public init(what: [OwnAccountItem] = [], said: String? = nil) {
        self.what = what
        self.said = said
    }
}

public enum OwnAccountError: Error, Equatable, Sendable {
    /// The sign-in does not hold the account part (`MastodonPart.account`): asking for it is
    /// what changes this.
    case locked
    /// The source would not take the change. Nothing of the account changed there.
    case refused(OwnAccountRefusal)
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
    /// How long the source's sentence is kept.
    static let sentenceLength = 200

    /// The account as its owner sees it now.
    public func read() async throws -> OwnAccount {
        try Self.account(from: try await door.get(path: MastodonAuthorized.accountCheck))
    }

    /// The limits the host states for an own account. Those it does not state are none.
    public func limits() async throws -> OwnAccountLimits {
        Self.limits(from: try await door.get(path: Self.documentPath))
    }

    /// Sends what changed from `before` to `after` and hands back the account as the source
    /// answers it. **Only what changed is sent** — and the fields whole where any of them
    /// did, since the source replaces the set. Where nothing changed nothing is asked, and
    /// `before` is handed back.
    ///
    /// Throws `.refused` where the source would not take it (422), or refused a sign-in that
    /// holds the account part (403); `.locked` for a 403 to a sign-in that does not hold it;
    /// and what the door threw otherwise.
    public func change(from before: OwnAccount, to after: OwnAccount) async throws -> OwnAccount {
        let form = Self.form(from: before, to: after)
        guard !form.isEmpty else { return before }
        let body: Data
        do {
            body = try await door.patch(path: Self.changePath, form: form)
        } catch let refused as MastodonUnprocessable {
            throw OwnAccountError.refused(Self.refusal(from: refused.body))
        } catch MastodonAuthError.http(403) {
            guard MastodonParts.holds(.account, in: door.token.scopes) else { throw OwnAccountError.locked }
            throw OwnAccountError.refused(OwnAccountRefusal())
        }
        return try Self.account(from: body)
    }

    /// The form that changes `before` into `after`: each thing that differs, in
    /// `OwnAccountItem`'s order. A switch the change leaves unsaid is not sent.
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
        for (key, now, was) in [
            ("locked", after.locked, before.locked),
            ("discoverable", after.discoverable, before.discoverable),
            ("hide_collections", after.hidesLists, before.hidesLists),
        ] {
            if let now, now != was { form.append((key, now ? "true" : "false")) }
        }
        return form
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
            OwnAccount.Field(name: $0.name?.value ?? "", value: $0.value?.value ?? "", verified: $0.verifiedAt?.value != nil)
        }
        return OwnAccount(
            name: wire.displayName?.value ?? "", words: source.note?.value ?? "", fields: fields,
            locked: wire.locked?.value,
            discoverable: source.discoverable?.value ?? wire.discoverable?.value,
            hidesLists: source.hideCollections?.value ?? wire.hideCollections?.value
        )
    }

    /// The limits a host's document states for an own account; a document that states none,
    /// or is no document, states none.
    static func limits(from body: Data) -> OwnAccountLimits {
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
        return OwnAccountLimits(
            name: stated(accounts.maxDisplayNameLength), words: stated(accounts.maxNoteLength),
            fields: stated(accounts.maxProfileFields), fieldName: stated(accounts.profileFieldNameLimit),
            fieldValue: stated(accounts.profileFieldValueLimit)
        )
    }

    /// What a 422 says was refused: each thing its `details` names that this app sent, and its
    /// sentence. A name of the source's this app does not send is in the sentence alone.
    static func refusal(from body: Data) -> OwnAccountRefusal {
        guard body.count <= refusalLength,
              let said = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return OwnAccountRefusal() }
        let named = Set(((said["details"] as? [String: Any]) ?? [:]).keys.compactMap(item))
        let sentence = (said["error"] as? String).map { LineText.oneLine($0, limit: sentenceLength) }
        return OwnAccountRefusal(
            what: OwnAccountItem.allCases.filter(named.contains),
            said: sentence.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        )
    }

    /// The item a source's name for a thing of the account is, by the names it is sent under.
    private static func item(_ name: String) -> OwnAccountItem? {
        switch name {
        case "display_name": .name
        case "note": .words
        case "locked": .locked
        case "discoverable": .discoverable
        case "hide_collections": .hidesLists
        default: name.hasPrefix("fields") ? .fields : nil
        }
    }
}

extension OwnAccount.Field {
    /// What a change sends of a field: its verified mark is the source's.
    fileprivate var pair: [String] { [name, value] }
}
