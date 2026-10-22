import Foundation

// Tending a Mastodon the reader answers for (#380): the standing its own account check says
// they hold, and — for #381 — what was reported to it.
//
// **The standing is the server's word, and only it draws anything.** A sign-in may be granted
// tending's words by anyone who asks for them; what the server lets that account do is its
// role, read off the account check (`MastodonWho.staff`). So nothing of tending is offered to
// an account whose role grants none of it, whatever its sign-in holds, and an account whose
// role grants it is still asked for the words, on their own (D9).
//
// **Asked of a real one first** (`MastodonAdminCaptures`). Everything here goes through the one
// signed-in door, read a stretch at a time by the server's own next, and nothing here writes
// anywhere on this device: every act returns the report as the server now holds it.

/// What a server's role lets an account do there, as its own account check said (#380): the
/// flags of Mastodon's `UserRole`, as the decimal string the check sends.
///
/// **Administrator grants every one** — the server's own rule — so whether a task is allowed is
/// asked through `allows`, never by a flag alone.
public struct MastodonStaff: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let administrator = MastodonStaff(rawValue: 1 << 0)
    public static let viewDashboard = MastodonStaff(rawValue: 1 << 3)
    public static let manageReports = MastodonStaff(rawValue: 1 << 4)
    public static let manageFederation = MastodonStaff(rawValue: 1 << 5)
    public static let manageBlocks = MastodonStaff(rawValue: 1 << 7)
    public static let manageTaxonomies = MastodonStaff(rawValue: 1 << 8)
    public static let manageUsers = MastodonStaff(rawValue: 1 << 10)
    public static let manageRules = MastodonStaff(rawValue: 1 << 12)

    /// Whether the role lets the account do what `flag` names: it holds the flag, or is the
    /// administrator.
    public func allows(_ flag: MastodonStaff) -> Bool {
        contains(.administrator) || contains(flag)
    }

    /// The standing a check's `role.permissions` says, read leniently: a decimal string — or a
    /// number, as a fork may send — of no more digits than the flags need. Nothing where it is
    /// neither, which is no standing.
    static func said(_ permissions: StatusDTO.Lenient<String>?, number: StatusDTO.Lenient<UInt64>?) -> MastodonStaff? {
        if let number = number?.value { return MastodonStaff(rawValue: number) }
        guard let text = permissions?.value, text.count <= 20, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = UInt64(text)
        else { return nil }
        return MastodonStaff(rawValue: value)
    }
}

/// Why something of tending could not be read or done.
public enum MastodonAdminError: Error, Equatable, Sendable {
    /// What was to be sent is not something this app sends: an id that cannot stand in a path.
    case invalid
    /// The server would not do it for this account's standing (its 403): the role lacks it.
    case notAllowed
    /// The server refused what was sent, in its own words (its 422).
    case refused(sentence: String)
    /// The server answered, and not with what was asked for.
    case unreadable
}

/// One report as the server keeps it for those who answer for it (#381).
public struct AdminReport: Sendable, Equatable, Identifiable {
    /// The id its server gives it.
    public let id: String
    /// Whether it is closed: the server's own word for a report acted on or put aside.
    public let closed: Bool
    /// What the reporter said it was about, as the server's word; an unknown word is drawn as `other`.
    public let category: String
    /// What the reporter wrote, fit for lines of ours.
    public let words: String
    /// Whether the report came from another server.
    public let forwarded: Bool
    public let at: Date?
    /// Who reported, where the server names somebody: a server reporting on its own has none.
    public let reporter: Person?
    /// Whom it is about.
    public let target: Person?
    /// Who has taken it on, by handle, where anybody has.
    public let takenBy: String?
    /// The posts it names, as posts of this source, and what those boost.
    public let posts: [Note]
    public let carried: [Note]
    /// The server's rules it names, by their words.
    public let rules: [String]

    public init(
        id: String, closed: Bool, category: String, words: String = "", forwarded: Bool = false, at: Date? = nil,
        reporter: Person? = nil, target: Person? = nil, takenBy: String? = nil, posts: [Note] = [], carried: [Note] = [],
        rules: [String] = []
    ) {
        self.id = id
        self.closed = closed
        self.category = category
        self.words = words
        self.forwarded = forwarded
        self.at = at
        self.reporter = reporter
        self.target = target
        self.takenBy = takenBy
        self.posts = posts
        self.carried = carried
        self.rules = rules
    }

    /// How much of what a reporter wrote is kept, and of a rule.
    public static let wordsLength = 1_000
    static let ruleCount = 64
}

/// A stretch of reports, newest first, and where the next begins.
public struct AdminReportStretch: Sendable, Equatable {
    public let reports: [AdminReport]
    public let next: String?

    public init(reports: [AdminReport], next: String?) {
        self.reports = reports
        self.next = next
    }
}

/// What was reported to a Mastodon, read and acted on by those who answer for it (#381):
/// `/api/v1/admin/reports`. **Only ever as the reader**, through the signed-in door: none of it
/// is given to anyone else.
public struct MastodonAdminReports: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v1/admin/reports"

    /// The acts on a report, each the server's word for it, as its address names it.
    public enum Act: String, CaseIterable, Sendable {
        /// Taken on by the reader.
        case take = "assign_to_self"
        /// Handed back: nobody's again.
        case handBack = "unassign"
        /// Closed, with nothing done to the account.
        case close = "resolve"
        /// Opened again.
        case reopen
    }

    /// The newest stretch of the open reports — or with `resolved` the closed ones — or with
    /// `next` the stretch older than the one that handed it back. **Entry by entry**: a report
    /// this build cannot read is that one report not listed, never the stretch.
    public func stretch(resolved: Bool, after next: String? = nil) async throws -> AdminReportStretch {
        let query = [URLQueryItem(name: "resolved", value: String(resolved))] + (try MastodonPage.older(than: next))
        let (body, link) = try await asked { try await door.getLinked(path: Self.path, query: query) }
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<ReportDTO>].self, from: body) else {
            throw MastodonAdminError.unreadable
        }
        let onward: String?
        do {
            onward = try MastodonLink.next(in: link)
        } catch {
            throw MastodonAdminError.unreadable
        }
        guard onward == nil || onward != next else { throw PagingError.notPaging }
        let sent = ReadMoment.now()
        let source = Source(host: door.token.host, kind: .mastodon)
        return AdminReportStretch(reports: read.compactMap { $0.value?.report(source: source, sent: sent) }, next: onward)
    }

    /// One report, as the server holds it now.
    public func report(_ id: String) async throws -> AdminReport {
        guard ListSubscription.isPathSegment(id) else { throw MastodonAdminError.invalid }
        return try read(try await asked { try await door.get(path: "\(Self.path)/\(id)") }, id: id)
    }

    /// `act` done to the report `id`: the report as the server holds it after.
    public func act(_ act: Act, on id: String) async throws -> AdminReport {
        guard ListSubscription.isPathSegment(id) else { throw MastodonAdminError.invalid }
        let body = try await asked {
            do {
                return try await door.postRefusable(path: "\(Self.path)/\(id)/\(act.rawValue)", form: [])
            } catch let refused as MastodonUnprocessable {
                guard case .refused(let sentence) = AccountPartError.refusal(from: refused.body) else {
                    throw MastodonAdminError.unreadable
                }
                throw MastodonAdminError.refused(sentence: sentence)
            }
        }
        return try read(body, id: id)
    }

    /// The address of the report on the server's own pages, where what this app does not carry
    /// — a note, an act on the account — is done.
    public static func page(of id: String, host: String) -> URL? {
        guard ListSubscription.isPathSegment(id) else { return nil }
        return Host.httpsURL(host: host, path: "/admin/reports/\(id)")
    }

    private func read(_ body: Data, id: String) throws -> AdminReport {
        let source = Source(host: door.token.host, kind: .mastodon)
        guard let report = (try? MastodonJSON.decoder.decode(ReportDTO.self, from: body))?.report(source: source, sent: .now()),
              report.id == id
        else { throw MastodonAdminError.unreadable }
        return report
    }

    /// A refusal for want of standing (403) told from every other: what an account without the
    /// role is answered, whatever its sign-in holds.
    private func asked<T>(_ ask: () async throws -> T) async throws -> T {
        do {
            return try await ask()
        } catch MastodonAuthError.http(403) {
            throw MastodonAdminError.notAllowed
        }
    }

    struct ReportDTO: Decodable, Sendable {
        typealias Lenient = StatusDTO.Lenient
        struct Staffed: Decodable, Sendable {
            let account: Lenient<AccountDTO>?
        }
        struct Rule: Decodable, Sendable {
            let text: String
        }

        let id: String
        let actionTaken: Lenient<Bool>?
        let category: Lenient<String>?
        let comment: Lenient<String>?
        let forwarded: Lenient<Bool>?
        let createdAt: StatusDTO.LenientMoment?
        let account: Lenient<Staffed>?
        let targetAccount: Lenient<Staffed>?
        let assignedAccount: Lenient<Staffed>?
        let statuses: Lenient<[Lenient<StatusDTO>]>?
        let rules: Lenient<[Lenient<Rule>]>?

        func report(source: Source, sent: ReadMoment) -> AdminReport? {
            guard ListSubscription.isPathSegment(id) else { return nil }
            let arrived = (statuses?.value ?? []).compactMap(\.value).map { $0.arrival(source: source, categories: [], sent: sent) }
            let words = String(String.UnicodeScalarView((comment?.value ?? "").unicodeScalars.prefix(AdminReport.wordsLength * 4)))
            return AdminReport(
                id: id, closed: actionTaken?.value ?? false, category: category?.value ?? "other",
                words: LineText.oneLine(words, limit: AdminReport.wordsLength), forwarded: forwarded?.value ?? false,
                at: createdAt?.value,
                reporter: account?.value?.account?.value?.asPerson(source: source),
                target: targetAccount?.value?.account?.value?.asPerson(source: source),
                takenBy: assignedAccount?.value?.account?.value?.asPerson(source: source)?.handle,
                posts: arrived.map(\.item), carried: arrived.compactMap(\.reblogged),
                rules: (rules?.value ?? []).compactMap { $0.value.map { LineText.oneLine($0.text, limit: MastodonReports.ruleLength) } }
                    .filter { !$0.isEmpty }.prefix(AdminReport.ruleCount).map { $0 }
            )
        }
    }
}
