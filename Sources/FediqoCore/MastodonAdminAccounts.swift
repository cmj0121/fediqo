import Foundation

// The accounts of a Mastodon the reader answers for (#382): who asks to join, found by name,
// address or state, and each warned, limited, marked sensitive, frozen or suspended — and taken
// back. Asked of a real one first (`MastodonAdminCaptures`); nothing here writes anywhere on
// this device.

/// One account as the server keeps it for those who answer for it (#382): the person, and what
/// only staff see of them — where they signed up from, what they wrote asking to join, and the
/// states the server holds them in.
public struct AdminAccount: Sendable, Equatable, Identifiable {
    /// The id its server gives the account: the person's own.
    public let id: String
    /// The account as anyone sees it, where the server gave one that reads.
    public let person: Person?
    /// The address their mail goes to, for a person of this server.
    public let email: String?
    /// The address they last signed in from.
    public let ip: String?
    /// What they wrote asking to join, fit for lines of ours. Empty where they wrote nothing.
    public let reason: String
    public let at: Date?
    /// Whether they live on this server.
    public let local: Bool
    public let confirmed: Bool
    public let approved: Bool
    /// Frozen: they cannot sign in.
    public let disabled: Bool
    /// Limited: what they post is shown only to who follows them.
    public let silenced: Bool
    public let suspended: Bool
    /// Their pictures and films are marked sensitive.
    public let sensitized: Bool

    public init(
        id: String, person: Person? = nil, email: String? = nil, ip: String? = nil, reason: String = "", at: Date? = nil,
        local: Bool = true, confirmed: Bool = true, approved: Bool = true, disabled: Bool = false, silenced: Bool = false,
        suspended: Bool = false, sensitized: Bool = false
    ) {
        self.id = id
        self.person = person
        self.email = email
        self.ip = ip
        self.reason = reason
        self.at = at
        self.local = local
        self.confirmed = confirmed
        self.approved = approved
        self.disabled = disabled
        self.silenced = silenced
        self.suspended = suspended
        self.sensitized = sensitized
    }

    /// Whether they wait to be let in: a person of this server not yet approved.
    public var waiting: Bool { local && !approved }

    /// Whether the account is held in what `act` does — what its undo would take back.
    public func holds(_ act: AccountAct) -> Bool {
        switch act {
        case .warn: false
        case .sensitive: sensitized
        case .freeze: disabled
        case .limit: silenced
        case .suspend: suspended
        }
    }

    /// How much of what they wrote is kept.
    public static let reasonLength = 1_000
}

/// Which accounts a stretch is asked for, by the state the server holds them in.
public enum AdminAccountState: String, CaseIterable, Sendable {
    /// Waiting to be let in.
    case pending
    case active
    /// Frozen.
    case disabled
    /// Limited.
    case silenced
    case suspended
    case sensitized
}

/// What a list of accounts is asked by: a state, and — where any — a name or an address.
public struct AdminAccountFilter: Hashable, Sendable {
    public var state: AdminAccountState
    /// A name, `name@server`, or nothing: matched as the server matches a username.
    public var words: String

    public init(state: AdminAccountState = .pending, words: String = "") {
        self.state = state
        self.words = words
    }

    /// How long what is asked by may be.
    public static let wordsLength = 100

    /// The server's own words for it: `status`, and a username and its server where named.
    var query: [URLQueryItem] {
        var items = [URLQueryItem(name: "status", value: state.rawValue)]
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = String(trimmed.drop { $0 == "@" }.prefix(Self.wordsLength))
        guard !written.isEmpty else { return items }
        let parts = written.split(separator: "@", maxSplits: 1).map(String.init)
        items.append(URLQueryItem(name: "username", value: parts[0]))
        if parts.count == 2, !parts[1].isEmpty { items.append(URLQueryItem(name: "by_domain", value: parts[1])) }
        return items
    }
}

/// A stretch of accounts, newest first, and where the next begins.
public struct AdminAccountStretch: Sendable, Equatable {
    public let accounts: [AdminAccount]
    public let next: String?

    public init(accounts: [AdminAccount], next: String?) {
        self.accounts = accounts
        self.next = next
    }
}

/// An act on an account, as the server words it (`Admin::AccountAction`).
public enum AccountAct: String, CaseIterable, Sendable {
    /// A warning, and nothing done: **it cannot be taken back**.
    case warn = "none"
    /// Their pictures and films marked sensitive.
    case sensitive
    /// Frozen: they cannot sign in.
    case freeze = "disable"
    /// Limited: shown only to who follows them.
    case limit = "silence"
    case suspend

    /// The address that takes it back, or nothing for one that cannot be.
    var undoWord: String? {
        switch self {
        case .warn: nil
        case .sensitive: "unsensitive"
        case .freeze: "enable"
        case .limit: "unsilence"
        case .suspend: "unsuspend"
        }
    }

    /// Whether it can be taken back.
    public var undoes: Bool { undoWord != nil }
}

/// The server's accounts, read and acted on by those who answer for it (#382): the v2 list, and
/// the v1 acts. **Only ever as the reader**, through the signed-in door.
public struct MastodonAdminAccounts: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let listPath = "/api/v2/admin/accounts"
    static let path = "/api/v1/admin/accounts"

    /// The newest stretch of the accounts `filter` asks for, or with `next` the stretch older
    /// than the one that handed it back. **Entry by entry**: an account this build cannot read
    /// is that one not listed.
    public func stretch(_ filter: AdminAccountFilter, after next: String? = nil) async throws -> AdminAccountStretch {
        let query = filter.query + (try MastodonPage.older(than: next))
        let (body, link) = try await door.adminAsked { try await door.getLinked(path: Self.listPath, query: query) }
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<AdminDTO>].self, from: body) else {
            throw MastodonAdminError.unreadable
        }
        let onward: String?
        do {
            onward = try MastodonLink.next(in: link)
        } catch {
            throw MastodonAdminError.unreadable
        }
        guard onward == nil || onward != next else { throw PagingError.notPaging }
        let source = Source(host: door.token.host, kind: .mastodon)
        return AdminAccountStretch(accounts: read.compactMap { $0.value?.account(source: source) }, next: onward)
    }

    /// One account, as the server holds it now.
    public func account(_ id: String) async throws -> AdminAccount {
        guard ListSubscription.isPathSegment(id) else { throw MastodonAdminError.invalid }
        return try read(try await door.adminAsked { try await door.get(path: "\(Self.path)/\(id)") }, id: id)
    }

    /// Somebody waiting let in: the account as it now stands.
    public func approve(_ id: String) async throws -> AdminAccount {
        try read(try await send("approve", on: id), id: id)
    }

    /// Somebody waiting turned away. **The server deletes the account**: nothing to read after.
    public func reject(_ id: String) async throws {
        _ = try await send("reject", on: id)
    }

    /// `act` done to the account `id`, with the words the server sends them, whether it tells
    /// them by mail, and the report it answers, where one. The server answers with nothing; the
    /// account is read again by whoever needs it.
    public func act(_ act: AccountAct, on id: String, words: String, tell: Bool, report: String? = nil) async throws {
        guard ListSubscription.isPathSegment(id), report.map(ListSubscription.isPathSegment) ?? true,
              words.unicodeScalars.count <= MastodonReports.wordsLength
        else { throw MastodonAdminError.invalid }
        var form = [("type", act.rawValue), ("text", words), ("send_email_notification", String(tell))]
        if let report { form.append(("report_id", report)) }
        _ = try await refusable { try await door.postRefusable(path: "\(Self.path)/\(id)/action", form: form) }
    }

    /// `act` taken back from the account `id`: the account as it now stands. A warning cannot be.
    public func undo(_ act: AccountAct, on id: String) async throws -> AdminAccount {
        guard let word = act.undoWord else { throw MastodonAdminError.invalid }
        return try read(try await send(word, on: id), id: id)
    }

    private func send(_ word: String, on id: String) async throws -> Data {
        guard ListSubscription.isPathSegment(id) else { throw MastodonAdminError.invalid }
        return try await refusable { try await door.postRefusable(path: "\(Self.path)/\(id)/\(word)", form: []) }
    }

    private func refusable(_ ask: () async throws -> Data) async throws -> Data {
        try await door.adminAsked {
            do {
                return try await ask()
            } catch let refused as MastodonUnprocessable {
                guard case .refused(let sentence) = AccountPartError.refusal(from: refused.body) else {
                    throw MastodonAdminError.unreadable
                }
                throw MastodonAdminError.refused(sentence: sentence)
            }
        }
    }

    private func read(_ body: Data, id: String) throws -> AdminAccount {
        let source = Source(host: door.token.host, kind: .mastodon)
        guard let account = (try? MastodonJSON.decoder.decode(AdminDTO.self, from: body))?.account(source: source), account.id == id
        else { throw MastodonAdminError.unreadable }
        return account
    }

    struct AdminDTO: Decodable, Sendable {
        typealias Lenient = StatusDTO.Lenient

        let id: String
        let domain: Lenient<String>?
        let createdAt: StatusDTO.LenientMoment?
        let email: Lenient<String>?
        let ip: Lenient<String>?
        let confirmed: Lenient<Bool>?
        let approved: Lenient<Bool>?
        let disabled: Lenient<Bool>?
        let silenced: Lenient<Bool>?
        let suspended: Lenient<Bool>?
        let sensitized: Lenient<Bool>?
        let inviteRequest: Lenient<String>?
        let account: Lenient<AccountDTO>?

        /// A line of ours, or nothing where there is none.
        private static func line(_ text: String?) -> String? {
            text.map { LineText.oneLine($0, limit: 320) }.flatMap { $0.isEmpty ? nil : $0 }
        }

        func account(source: Source) -> AdminAccount? {
            guard ListSubscription.isPathSegment(id) else { return nil }
            let said = String(String.UnicodeScalarView((inviteRequest?.value ?? "").unicodeScalars.prefix(AdminAccount.reasonLength * 4)))
            return AdminAccount(
                id: id, person: account?.value?.asPerson(source: source), email: Self.line(email?.value), ip: Self.line(ip?.value),
                reason: LineText.oneLine(said, limit: AdminAccount.reasonLength), at: createdAt?.value,
                local: (domain?.value ?? "").isEmpty, confirmed: confirmed?.value ?? false, approved: approved?.value ?? true,
                disabled: disabled?.value ?? false, silenced: silenced?.value ?? false, suspended: suspended?.value ?? false,
                sensitized: sensitized?.value ?? false
            )
        }
    }
}
