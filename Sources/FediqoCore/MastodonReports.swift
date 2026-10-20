import Foundation

/// What a report says something is (#339), in the four words a Mastodon files one under.
public enum ReportCategory: String, CaseIterable, Sendable {
    /// Something made only to sell, or to be seen.
    case spam
    /// Something against the law where the person or the server is.
    case legal
    /// Against one or more of the server's own rules, which a report of this kind names.
    case violation
    /// Anything else.
    case other
}

/// One of a server's own rules, **as the server words it**: its words and the hint beside them,
/// made fit for a line and bounded, and nothing of this app's put in their place.
public struct ServerRule: Hashable, Sendable, Identifiable {
    public let id: String
    public let text: String
    /// What the server says beside the rule, where it says anything.
    public let hint: String?

    public init(id: String, text: String, hint: String? = nil) {
        self.id = id
        self.text = text
        self.hint = hint
    }
}

/// A report as it is sent (#339): whom, which posts of theirs show it, what kind it is and which
/// of the server's rules it names, the reader's few words, and whether the server they live on
/// is told as well.
public struct ReportToSend: Hashable, Sendable {
    public var accountID: String
    public var postIDs: [String]
    public var category: ReportCategory
    /// The rules it names: **sent only with `violation`**, since a server files a report of any
    /// other kind that names one as a violation (asked of a real one).
    public var ruleIDs: [String]
    public var words: String
    /// Whether the server the person lives on is told too. **Only ever what the person chose**.
    public var forward: Bool

    public init(
        accountID: String, postIDs: [String] = [], category: ReportCategory, ruleIDs: [String] = [], words: String = "",
        forward: Bool = false
    ) {
        self.accountID = accountID
        self.postIDs = postIDs
        self.category = category
        self.ruleIDs = ruleIDs
        self.words = words
        self.forward = forward
    }

    /// The form it is sent as, in the order a check reads it.
    var form: [(String, String)] {
        var form = [("account_id", accountID)]
        form += postIDs.map { ("status_ids[]", $0) }
        form.append(("comment", words))
        form.append(("forward", String(forward)))
        form.append(("category", category.rawValue))
        if category == .violation { form += ruleIDs.map { ("rule_ids[]", $0) } }
        return form
    }
}

/// What the source said of a report it took.
public struct ReportTaken: Hashable, Sendable {
    public let id: String
    public let category: String
    /// Whether it was passed on to the server the person lives on.
    public let forwarded: Bool
    public let postIDs: [String]
    public let ruleIDs: [String]
}

/// A report the source did not take, or answered with what this device could not read.
public enum MastodonReportError: Error, Equatable, Sendable {
    /// Refused before anything was asked: a report naming nobody, a post or a rule that is no
    /// one segment, a violation naming no rule, or words longer than a server takes.
    case invalid
    /// The source would not take it (422), in its own sentence made fit for a line.
    case refused(sentence: String)
    /// The source answered, and not with the report asked for.
    case unreadable
}

/// A Mastodon told of a post or a person (#339): `/api/v1/reports`, and the server's own rules
/// a report names, `/api/v1/instance/rules`.
///
/// **Asked of a real one first** (`MastodonReportCaptures`). A report is the reader's own word,
/// sent **through the one signed-in door**, to the source's own host and nowhere else; whether
/// the server the person lives on is told as well is the source's to do, and only where the
/// report says `forward` — which nothing here sets but whoever was told the person chose it.
///
/// **What becomes of a report is the server's.** Nothing here asks after one, and nothing here
/// writes anywhere on this device: a report that is refused or fails throws and changes nothing.
public struct MastodonReports: Sendable {
    private let door: MastodonAuthorized

    public init(door: MastodonAuthorized) {
        self.door = door
    }

    static let path = "/api/v1/reports"
    static let rulesPath = "/api/v1/instance/rules"
    /// The most words a server takes with a report of somebody of its own (asked of a real one).
    public static let wordsLength = 1_000
    /// How many rules are kept of a server, and how long the words of one may run.
    static let ruleCount = 64
    static let ruleLength = 1_000

    /// The server's own rules, in its own order, as it words them. A rule this build cannot read
    /// is that one rule not listed; a body that is no list is `unreadable`.
    public func rules() async throws -> [ServerRule] {
        let body = try await door.get(path: Self.rulesPath)
        guard let read = try? MastodonJSON.decoder.decode([StatusDTO.Lenient<RuleDTO>].self, from: body) else {
            throw MastodonReportError.unreadable
        }
        var seen = Set<String>()
        return read.compactMap { $0.value?.rule }.filter { seen.insert($0.id).inserted }.prefix(Self.ruleCount).map { $0 }
    }

    /// Sends `report`, and hands back what the source said it took. **Refused before anything is
    /// asked** where it names nobody, a post or a rule that could not stand in a query as an id,
    /// a violation with no rule, or more words than a server takes.
    public func send(_ report: ReportToSend) async throws -> ReportTaken {
        let ids = [report.accountID] + report.postIDs + (report.category == .violation ? report.ruleIDs : [])
        guard ids.allSatisfy(ListSubscription.isPathSegment), report.category != .violation || !report.ruleIDs.isEmpty,
              report.words.unicodeScalars.count <= Self.wordsLength
        else { throw MastodonReportError.invalid }
        let body: Data
        do {
            body = try await door.actAtAddress(path: Self.path, method: "POST", form: report.form)
        } catch let refused as MastodonUnprocessable {
            guard case .refused(let sentence) = AccountPartError.refusal(from: refused.body) else { throw MastodonReportError.unreadable }
            throw MastodonReportError.refused(sentence: sentence)
        }
        guard let said = try? MastodonJSON.decoder.decode(TakenDTO.self, from: body), said.targetAccount?.id == report.accountID
        else { throw MastodonReportError.unreadable }
        return ReportTaken(
            id: said.id, category: said.category ?? "", forwarded: said.forwarded ?? false, postIDs: said.statusIds ?? [],
            ruleIDs: said.ruleIds ?? []
        )
    }

    private struct RuleDTO: Decodable, Sendable {
        let id: String
        let text: String
        let hint: StatusDTO.Lenient<String>?

        var rule: ServerRule? {
            let words = LineText.oneLine(text, limit: MastodonReports.ruleLength)
            guard !id.isEmpty, !words.isEmpty else { return nil }
            let hinted = hint?.value.map { LineText.oneLine($0, limit: MastodonReports.ruleLength) }
            return ServerRule(id: id, text: words, hint: hinted?.isEmpty == false ? hinted : nil)
        }
    }

    private struct TakenDTO: Decodable, Sendable {
        struct Account: Decodable, Sendable { let id: String }
        let id: String
        let category: String?
        let forwarded: Bool?
        let statusIds: [String]?
        let ruleIds: [String]?
        let targetAccount: Account?
    }
}
