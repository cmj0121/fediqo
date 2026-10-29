import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The servers and the addresses a Mastodon the reader answers for refuses or allows (#383): the
// servers it suspends, limits or allows, and the mail domains and address ranges it refuses to
// let sign up — and the mailboxes it refuses however they are written (#417). Asked of a real
// one first (`MastodonAdminFederationCaptures`); nothing here writes anywhere on this device,
// and every write answers with what the server now holds.

/// How hard a server is refused, in the server's words.
public enum ServerSeverity: String, CaseIterable, Sendable {
    /// Limited: its posts shown only to who follows them.
    case limit = "silence"
    /// Suspended: **cut off** — nothing goes to it or comes from it.
    case suspend
    /// Nothing done but what the block names besides — media, reports.
    case none = "noop"
}

/// A server this one refuses.
public struct ServerBlock: Sendable, Equatable, Identifiable {
    public let id: String
    public let domain: String
    public let severity: ServerSeverity
    /// Its pictures and films are not kept here.
    public let rejectMedia: Bool
    /// Reports from it are not taken.
    public let rejectReports: Bool
    /// Why, as those who answer for the server wrote it for each other — as the server holds it,
    /// lines and all: made one line only where it is drawn.
    public let privateWords: String
    /// Why, as the server says it to anyone — as it holds it, lines and all.
    public let publicWords: String
    /// Its name is shown to others only in part.
    public let obfuscate: Bool
    public let at: Date?

    public init(
        id: String, domain: String, severity: ServerSeverity, rejectMedia: Bool = false, rejectReports: Bool = false,
        privateWords: String = "", publicWords: String = "", obfuscate: Bool = false, at: Date? = nil
    ) {
        self.id = id
        self.domain = domain
        self.severity = severity
        self.rejectMedia = rejectMedia
        self.rejectReports = rejectReports
        self.privateWords = privateWords
        self.publicWords = publicWords
        self.obfuscate = obfuscate
        self.at = at
    }

    /// What a block written to be sent is, of this one: to change it.
    public var draft: ServerBlockDraft {
        ServerBlockDraft(
            domain: domain, severity: severity, rejectMedia: rejectMedia, rejectReports: rejectReports,
            privateWords: privateWords, publicWords: publicWords, obfuscate: obfuscate
        )
    }
}

/// A block as written to be sent: the server, how hard, what besides, and why.
public struct ServerBlockDraft: Sendable, Equatable {
    public var domain: String
    public var severity: ServerSeverity
    public var rejectMedia: Bool
    public var rejectReports: Bool
    public var privateWords: String
    public var publicWords: String
    public var obfuscate: Bool

    public init(
        domain: String = "", severity: ServerSeverity = .limit, rejectMedia: Bool = false, rejectReports: Bool = false,
        privateWords: String = "", publicWords: String = "", obfuscate: Bool = false
    ) {
        self.domain = domain
        self.severity = severity
        self.rejectMedia = rejectMedia
        self.rejectReports = rejectReports
        self.privateWords = privateWords
        self.publicWords = publicWords
        self.obfuscate = obfuscate
    }

    /// Whether it is one this app sends: a server's name — as written, trimmed and in its wire
    /// form (`MastodonAdminFederation.wireDomain`) — and words of no more than the server takes.
    public var sendable: Bool {
        MastodonAdminFederation.wireDomain(domain) != nil && privateWords.unicodeScalars.count <= MastodonAdminFederation.wordsLength
            && publicWords.unicodeScalars.count <= MastodonAdminFederation.wordsLength
    }

    var form: [(String, String)] {
        [
            ("severity", severity.rawValue), ("reject_media", String(rejectMedia)), ("reject_reports", String(rejectReports)),
            ("private_comment", privateWords), ("public_comment", publicWords), ("obfuscate", String(obfuscate)),
        ]
    }
}

/// A server this one lets in, where it federates only with those it names.
public struct ServerAllow: Sendable, Equatable, Identifiable {
    public let id: String
    public let domain: String
    public let at: Date?

    public init(id: String, domain: String, at: Date? = nil) {
        self.id = id
        self.domain = domain
        self.at = at
    }
}

/// A mail domain this server refuses to let anybody sign up with.
public struct RefusedMailDomain: Sendable, Equatable, Identifiable {
    public let id: String
    public let domain: String
    public let at: Date?

    public init(id: String, domain: String, at: Date? = nil) {
        self.id = id
        self.domain = domain
        self.at = at
    }
}

/// How hard an address range is refused, in the server's words.
public enum AddressSeverity: String, CaseIterable, Sendable {
    /// Signing up from it waits for approval.
    case approval = "sign_up_requires_approval"
    /// Nobody signs up from it.
    case signUp = "sign_up_block"
    /// Nothing reaches the server from it.
    case noAccess = "no_access"
}

/// An address range this server refuses.
public struct RefusedAddress: Sendable, Equatable, Identifiable {
    public let id: String
    public let ip: String
    public let severity: AddressSeverity
    public let words: String
    public let at: Date?
    /// When it lapses, where it does.
    public let until: Date?

    public init(id: String, ip: String, severity: AddressSeverity, words: String = "", at: Date? = nil, until: Date? = nil) {
        self.id = id
        self.ip = ip
        self.severity = severity
        self.words = words
        self.at = at
        self.until = until
    }
}

/// A mailbox this server refuses to let anybody sign up with, however it is written (#417). The
/// server keeps only the fingerprint of its one spelling — the address as it counts it, without
/// dots, tags or capitals where its mail domain ignores them — never the address itself.
public struct RefusedMailbox: Sendable, Equatable, Identifiable {
    public let id: String
    /// The server's fingerprint of the address, in hex.
    public let hash: String

    public init(id: String, hash: String) {
        self.id = id
        self.hash = hash
    }
}

/// A stretch of any of the lists, newest first, and where the next begins.
public struct FederationStretch<Item: Sendable & Equatable>: Sendable, Equatable {
    public let items: [Item]
    public let next: String?

    public init(items: [Item], next: String?) {
        self.items = items
        self.next = next
    }
}

/// The servers and addresses a Mastodon refuses or allows, read and changed by those who answer
/// for it (#383). **Only ever as the reader**, through the signed-in door.
public struct MastodonAdminFederation: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let blocksPath = "/api/v1/admin/domain_blocks"
    static let allowsPath = "/api/v1/admin/domain_allows"
    static let mailPath = "/api/v1/admin/email_domain_blocks"
    static let addressesPath = "/api/v1/admin/ip_blocks"
    static let mailboxesPath = "/api/v1/admin/canonical_email_blocks"
    /// How long the words of a block or an address may be.
    public static let wordsLength = 1_000

    /// Whether `domain` is a server's name this app sends: letters, digits, hyphens and dots, as
    /// a name is written on the wire, of no more than a name may run.
    public static func isDomain(_ domain: String) -> Bool {
        let parts = domain.split(separator: ".", omittingEmptySubsequences: false)
        return !domain.isEmpty && domain.utf8.count <= 253 && parts.count >= 2
            && parts.allSatisfy { part in
                !part.isEmpty && part.utf8.count <= 63 && part.first != "-" && part.last != "-"
                    && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            }
    }

    /// A server's name as written — pasted with spaces about it, in capitals, or in letters
    /// beyond ASCII — in the form the wire carries: trimmed, lower case, and an international
    /// name in its ASCII spelling (`xn--…`). Nothing where it is no server's name.
    public static func wireDomain(_ written: String) -> String? {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.count <= 253 else { return nil }
        var wire = trimmed
        if !trimmed.allSatisfy(\.isASCII) {
            var parts = URLComponents()
            parts.host = trimmed
            guard let encoded = parts.encodedHost else { return nil }
            wire = encoded
        }
        wire = wire.lowercased()
        return isDomain(wire) ? wire : nil
    }

    /// An address or a range of them, as written, and how wide it is.
    public struct AddressRange: Sendable, Equatable {
        /// What is sent: the address as written, trimmed, with its prefix where it had one.
        public let wire: String
        public let isV6: Bool
        /// How many leading bits name it: 32 or 128 for one address.
        public let prefix: Int
        /// An IPv6 range that carries IPv4 addresses in its last 32 bits — mapped (`::ffff:a.b.c.d`)
        /// or compatible (`::a.b.c.d`) — whose width is IPv4's, less the 96 bits before them.
        public var carriesV4 = false

        /// Whether it reaches a great many addresses — wider than a /8 of IPv4, or a /16 of
        /// IPv6 — so that refusing it may shut out whole networks. One that carries IPv4 is
        /// judged as IPv4: `::ffff:0.0.0.0/96` is all of it.
        public var isWide: Bool {
            if carriesV4 { return prefix - 96 < 8 }
            return prefix < (isV6 ? 16 : 8)
        }
    }

    /// The address or range `written` names, read as the address families read them — an IPv4
    /// address in four parts, or an IPv6 one — with a prefix, where it has one, of whole digits
    /// no wider than its family's. **Never the whole of either** (`/0`). Nothing where it is not one.
    public static func range(_ written: String) -> AddressRange? {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 else { return nil }
        let halves = trimmed.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard halves.count <= 2 else { return nil }
        let address = String(halves[0])
        // Digits, dots and colons only: no zone (`%en0`), which the families' reader lets by.
        guard address.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == ":") }) else { return nil }
        let isV6: Bool
        var carriesV4 = false
        if address.contains(":") {
            var bytes = in6_addr()
            guard inet_pton(AF_INET6, address, &bytes) == 1 else { return nil }
            isV6 = true
            let octets = withUnsafeBytes(of: &bytes) { Array($0) }
            let zeros = octets.prefix(10).allSatisfy { $0 == 0 }
            let mapped = zeros && octets[10] == 0xff && octets[11] == 0xff
            let compatible = zeros && octets[10] == 0 && octets[11] == 0 && address.contains(".")
            carriesV4 = mapped || compatible
        } else {
            var bytes = in_addr()
            guard address.split(separator: ".", omittingEmptySubsequences: false).count == 4,
                  inet_pton(AF_INET, address, &bytes) == 1
            else { return nil }
            isV6 = false
        }
        let widest = isV6 ? 128 : 32
        var prefix = widest
        if halves.count == 2 {
            let digits = halves[1]
            guard !digits.isEmpty, digits.count <= 3, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let read = Int(digits), read >= 1, read <= widest
            else { return nil }
            prefix = read
        }
        return AddressRange(wire: trimmed, isV6: isV6, prefix: prefix, carriesV4: carriesV4)
    }

    /// Whether `ip` is an address or a range of them this app sends (`range`).
    public static func isAddress(_ ip: String) -> Bool {
        range(ip) != nil
    }

    /// A mail address as written — pasted with spaces about it, its domain in capitals or in
    /// letters beyond ASCII — in the form the wire carries: trimmed, one mailbox of no spaces
    /// before its last `@`, and a server's name after it (`wireDomain` judges that it is one).
    /// **Sent as written**, its domain only lower case: the server fingerprints the address in
    /// the letters it was given, never in a name's ASCII spelling, and is the one that counts
    /// spellings the same. Nothing where it is no address — the server would refuse the
    /// fingerprint of nothing at all.
    public static func wireMailbox(_ written: String) -> String? {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count <= 320, let at = trimmed.lastIndex(of: "@") else { return nil }
        let local = trimmed[..<at], domain = trimmed[trimmed.index(after: at)...].lowercased()
        let unwritten = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !local.isEmpty, local.unicodeScalars.count <= 64, !local.unicodeScalars.contains(where: unwritten.contains),
              wireDomain(domain) != nil
        else { return nil }
        return "\(local)@\(domain)"
    }

    // MARK: - Servers refused

    public func blocks(after next: String? = nil) async throws -> FederationStretch<ServerBlock> {
        try await list(Self.blocksPath, after: next) { (said: BlockDTO) in said.block }
    }

    public func addBlock(_ draft: ServerBlockDraft) async throws -> ServerBlock {
        guard draft.sendable, let domain = Self.wireDomain(draft.domain) else { throw MastodonAdminError.invalid }
        let body = try await write(Self.blocksPath, "POST", form: [("domain", domain)] + draft.form)
        return try read(body) { (said: BlockDTO) in said.block }
    }

    public func changeBlock(_ id: String, to draft: ServerBlockDraft) async throws -> ServerBlock {
        guard ListSubscription.isPathSegment(id), draft.sendable else { throw MastodonAdminError.invalid }
        let body = try await write("\(Self.blocksPath)/\(id)", "PUT", form: draft.form)
        return try read(body) { (said: BlockDTO) in said.block }
    }

    public func removeBlock(_ id: String) async throws {
        try await remove("\(Self.blocksPath)/\(id)", id)
    }

    // MARK: - Servers allowed

    public func allows(after next: String? = nil) async throws -> FederationStretch<ServerAllow> {
        try await list(Self.allowsPath, after: next) { (said: NamedDTO) in said.allow }
    }

    public func addAllow(_ domain: String) async throws -> ServerAllow {
        guard let domain = Self.wireDomain(domain) else { throw MastodonAdminError.invalid }
        return try read(try await write(Self.allowsPath, "POST", form: [("domain", domain)])) { (said: NamedDTO) in said.allow }
    }

    public func removeAllow(_ id: String) async throws {
        try await remove("\(Self.allowsPath)/\(id)", id)
    }

    // MARK: - Mail domains

    public func mailDomains(after next: String? = nil) async throws -> FederationStretch<RefusedMailDomain> {
        try await list(Self.mailPath, after: next) { (said: NamedDTO) in said.mail }
    }

    public func addMailDomain(_ domain: String) async throws -> RefusedMailDomain {
        guard let domain = Self.wireDomain(domain) else { throw MastodonAdminError.invalid }
        return try read(try await write(Self.mailPath, "POST", form: [("domain", domain)])) { (said: NamedDTO) in said.mail }
    }

    public func removeMailDomain(_ id: String) async throws {
        try await remove("\(Self.mailPath)/\(id)", id)
    }

    // MARK: - Addresses

    public func addresses(after next: String? = nil) async throws -> FederationStretch<RefusedAddress> {
        try await list(Self.addressesPath, after: next) { (said: AddressDTO) in said.address }
    }

    public func addAddress(_ ip: String, severity: AddressSeverity, words: String) async throws -> RefusedAddress {
        guard let range = Self.range(ip), words.unicodeScalars.count <= Self.wordsLength else { throw MastodonAdminError.invalid }
        let form = [("ip", range.wire), ("severity", severity.rawValue), ("comment", words)]
        return try read(try await write(Self.addressesPath, "POST", form: form)) { (said: AddressDTO) in said.address }
    }

    public func removeAddress(_ id: String) async throws {
        try await remove("\(Self.addressesPath)/\(id)", id)
    }

    // MARK: - Mailboxes, however written

    public func mailboxes(after next: String? = nil) async throws -> FederationStretch<RefusedMailbox> {
        try await list(Self.mailboxesPath, after: next) { (said: MailboxDTO) in said.mailbox }
    }

    /// The refused mailboxes `address` is, in any spelling the server counts as the same: none
    /// where it would be let sign up. **Adds nothing.**
    public func tryMailbox(_ address: String) async throws -> [RefusedMailbox] {
        guard let address = Self.wireMailbox(address) else { throw MastodonAdminError.invalid }
        let body = try await write("\(Self.mailboxesPath)/test", "POST", form: [("email", address)])
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<MailboxDTO>].self, from: body) else {
            throw MastodonAdminError.unreadable
        }
        return read.compactMap { $0.value?.mailbox }
    }

    public func addMailbox(_ address: String) async throws -> RefusedMailbox {
        guard let address = Self.wireMailbox(address) else { throw MastodonAdminError.invalid }
        return try read(try await write(Self.mailboxesPath, "POST", form: [("email", address)])) { (said: MailboxDTO) in said.mailbox }
    }

    public func removeMailbox(_ id: String) async throws {
        try await remove("\(Self.mailboxesPath)/\(id)", id)
    }

    // MARK: - The wire

    private func list<DTO: Decodable & Sendable, Item: Sendable & Equatable>(
        _ path: String, after next: String?, _ made: (DTO) -> Item?
    ) async throws -> FederationStretch<Item> {
        let (body, link) = try await asked { try await door.getLinked(path: path, query: try MastodonPage.older(than: next)) }
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

    private func read<DTO: Decodable, Item>(_ body: Data, _ made: (DTO) -> Item?) throws -> Item {
        guard let said = try? MastodonJSON.decoder.decode(DTO.self, from: body), let item = made(said) else {
            throw MastodonAdminError.unreadable
        }
        return item
    }

    private func remove(_ path: String, _ id: String) async throws {
        guard ListSubscription.isPathSegment(id) else { throw MastodonAdminError.invalid }
        _ = try await write(path, "DELETE", form: nil)
    }

    private func write(_ path: String, _ method: String, form: [(String, String)]?) async throws -> Data {
        try await asked {
            do {
                return try await door.actAtAddress(path: path, method: method, form: form)
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

    private func asked<T>(_ ask: () async throws -> T) async throws -> T {
        do {
            return try await ask()
        } catch MastodonAuthError.http(403) {
            throw MastodonAdminError.notAllowed
        }
    }

    /// A line of ours of what the server says, or empty.
    private static func line(_ text: String?) -> String {
        LineText.oneLine(String(String.UnicodeScalarView((text ?? "").unicodeScalars.prefix(wordsLength * 4))), limit: wordsLength)
    }

    /// What the server says of a block, **as it holds it** — lines and all — so that a block
    /// changed sends its words back as they were. Made one line only where it is drawn. Kept to
    /// a bound: more than that is not this app's to send back (`ServerBlockDraft.sendable`).
    private static func held(_ text: String?) -> String {
        String(String.UnicodeScalarView((text ?? "").unicodeScalars.prefix(wordsLength * 4)))
    }

    struct BlockDTO: Decodable, Sendable {
        typealias Lenient = StatusDTO.Lenient
        let id: String
        let domain: String
        let severity: Lenient<String>?
        let rejectMedia: Lenient<Bool>?
        let rejectReports: Lenient<Bool>?
        let privateComment: Lenient<String>?
        let publicComment: Lenient<String>?
        let obfuscate: Lenient<Bool>?
        let createdAt: StatusDTO.LenientMoment?

        var block: ServerBlock? {
            guard ListSubscription.isPathSegment(id), let severity = ServerSeverity(rawValue: severity?.value ?? "") else { return nil }
            return ServerBlock(
                id: id, domain: LineText.oneLine(domain, limit: 253), severity: severity, rejectMedia: rejectMedia?.value ?? false,
                rejectReports: rejectReports?.value ?? false, privateWords: MastodonAdminFederation.held(privateComment?.value),
                publicWords: MastodonAdminFederation.held(publicComment?.value), obfuscate: obfuscate?.value ?? false,
                at: createdAt?.value
            )
        }
    }

    struct NamedDTO: Decodable, Sendable {
        let id: String
        let domain: String
        let createdAt: StatusDTO.LenientMoment?

        private var named: (id: String, domain: String)? {
            ListSubscription.isPathSegment(id) ? (id, LineText.oneLine(domain, limit: 253)) : nil
        }

        var allow: ServerAllow? { named.map { ServerAllow(id: $0.id, domain: $0.domain, at: createdAt?.value) } }
        var mail: RefusedMailDomain? { named.map { RefusedMailDomain(id: $0.id, domain: $0.domain, at: createdAt?.value) } }
    }

    struct AddressDTO: Decodable, Sendable {
        typealias Lenient = StatusDTO.Lenient
        let id: String
        let ip: String
        let severity: Lenient<String>?
        let comment: Lenient<String>?
        let createdAt: StatusDTO.LenientMoment?
        let expiresAt: StatusDTO.LenientMoment?

        var address: RefusedAddress? {
            guard ListSubscription.isPathSegment(id), let severity = AddressSeverity(rawValue: severity?.value ?? "") else { return nil }
            return RefusedAddress(
                id: id, ip: LineText.oneLine(ip, limit: 64), severity: severity, words: MastodonAdminFederation.line(comment?.value),
                at: createdAt?.value, until: expiresAt?.value
            )
        }
    }

    struct MailboxDTO: Decodable, Sendable {
        let id: String
        let canonicalEmailHash: String

        var mailbox: RefusedMailbox? {
            let hash = canonicalEmailHash
            guard ListSubscription.isPathSegment(id), !hash.isEmpty, hash.utf8.count <= 128, hash.allSatisfy(\.isHexDigit) else { return nil }
            return RefusedMailbox(id: id, hash: hash.lowercased())
        }
    }
}
