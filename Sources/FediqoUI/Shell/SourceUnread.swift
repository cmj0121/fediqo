import FediqoCore
import Foundation
import Synchronization

// A source whose reads keep failing says so where the person reads (#371).
//
// Every round that reads the sources — `r` on a timeline, and the wait's round over all of them —
// counts, for each source it read, which of that source's divisions did not come back: Home, a
// list, the public timeline, Trends, a board, the reader's marks, or the source's own read where
// it has no divisions (a forum's front page). A division that fails round after round, past
// `UnreadRuns.rounds`, is said: on the source's row (its `…` warns, and its head and the source's
// detail say the line) and on every timeline drawn from that division. The first round that reads
// it takes the word away, and only the same run of failures brings it back.
//
// **Kept for the run, not on this device.** The count starts again at a launch: a source that was
// failing is asked at once, and three more rounds say it again. Nothing of it is written anywhere.
//
// **What a round counts as read is what the reload already counts as read** (`ShellReload.read`):
// a Mastodon with no Trends whose public timeline came is read, as is a forum whose ranking lists
// are switched off. Those failures are said in the log and nowhere else, as before.

/// Why a source's reads did not come back, in one of three words.
enum UnreadWhy: Hashable, Sendable {
    /// The source said no: a sign-in it no longer takes, a scope, a filter or the forum's notice.
    case refused
    /// It did not answer, or not in time, or answered that it could not now: the network, a
    /// deadline passing, a 5xx, a 429.
    case outOfReach
    /// It answered, and the answer was not something this app reads.
    case notUnderstood

    /// The word for `error`, a failure that was not the reader walking away. **Anything not
    /// named is out of reach**: what this app cannot tell apart is most often the wire.
    static func of(_ error: any Error) -> UnreadWhy {
        switch error {
        case MastodonAuthError.signedOut, MastodonScopeError.outside, is MastodonUnprocessable:
            return .refused
        case MastodonAuthError.http(let status), MastodonRequestError.http(let status),
             DiscourseRequestError.http(let status), DiscuzRequestError.http(let status):
            return of(status: status)
        case DiscuzRequestError.refused(let status), DiscourseRequestError.refused(let status):
            // A filter's refusal, by its status: a busy server says 429 or 503.
            return of(status: status) == .outOfReach ? .outOfReach : .refused
        case DiscuzRequestError.challenged, DiscuzRequestError.restricted, DiscuzRequestError.noBoards,
             DiscuzRequestError.refusal:
            return .refused
        case DiscuzRequestError.undecodable, DiscuzRequestError.noThreads, DiscuzRequestError.noPosts,
             DiscuzRequestError.invalidURL, DiscourseRequestError.invalidURL, MastodonRequestError.invalidURL:
            return .notUnderstood
        case ForumTransportError.wall:
            return .refused
        case ForumTransportError.unreadable, ForumTransportError.unfetchable, ForumTransportError.wrongHost:
            return .notUnderstood
        case ForumTransportError.timedOut, ForumTransportError.unreachable:
            return .outOfReach
        case is DecodingError:
            return .notUnderstood
        case is URLError:
            return .outOfReach
        default:
            return .outOfReach
        }
    }

    /// The word for an answer's status: a refusal of who is asking, the server unable to answer
    /// now, or an answer to something else.
    static func of(status: Int) -> UnreadWhy {
        switch status {
        case 401, 403, 407, 422, 451: .refused
        case 408, 429, 500...599: .outOfReach
        default: .notUnderstood
        }
    }

    var key: String {
        switch self {
        case .refused: "source.unread.refused"
        case .outOfReach: "source.unread.reach"
        case .notUnderstood: "source.unread.understood"
        }
    }
}

/// One part of a source that is read on its own: a category of it, or the whole of what it
/// reads where the failure names no category.
enum UnreadDivision: Hashable, Sendable {
    case whole
    case of(FediqoCore.Category)
    /// The names of a signed-in source's lists, read before its lists are: no timeline draws on
    /// them, so only the source says it, and only its usual reads read them again.
    case listNames

    init(_ category: FediqoCore.Category?) {
        self = category.map(UnreadDivision.of) ?? .whole
    }

    /// Whether a read of `asked` — nil for a source's usual reads — reads this division.
    func read(by asked: Set<FediqoCore.Category>?) -> Bool {
        guard let asked else { return true }
        switch self {
        case .whole, .listNames: return false
        case .of(let category): return asked.contains(category)
        }
    }

    /// Whether a timeline drawing `asked` of its source draws on this division: the whole of a
    /// source is drawn on by every timeline of it, and the names of its lists by none.
    func drawn(by asked: Set<FediqoCore.Category>?) -> Bool {
        switch self {
        case .whole: true
        case .listNames: false
        case .of(let category): asked?.contains(category) ?? true
        }
    }

    /// Whether the reader's sign-in is what reads it: what a sign-out takes off the count.
    var readAsYou: Bool {
        switch self {
        case .listNames, .of(.home), .of(.list), .of(.bookmarks), .of(.favourites), .of(.conversations): true
        case .whole, .of: false
        }
    }
}

/// What one round says of one source: what failed and why, what the reload does not count as a
/// failure, and whether a read of it was stopped before it ended.
struct UnreadRoundWord: Equatable, Sendable {
    var failed: [UnreadDivision: UnreadWhy] = [:]
    var excused: Set<UnreadDivision> = []
    var stopped = false
}

/// What one round of reads found failing, by source and division, as the reads say it — from
/// the main actor and from the reads as the reader in the core alike, so under a lock.
final class ReadRound: Sendable {
    /// The round the reads of this task belong to: nothing outside a round of `r` or the wait.
    @TaskLocal static var current: ReadRound?

    private let words = Mutex<[String: UnreadRoundWord]>([:])

    /// `category` of `host` did not come back, for `error`. The last word said of it stands.
    func failed(_ host: String, _ category: FediqoCore.Category?, _ error: any Error) {
        failed(host, UnreadDivision(category), error)
    }

    func failed(_ host: String, _ division: UnreadDivision, _ error: any Error) {
        let why = UnreadWhy.of(error)
        words.withLock { $0[host.lowercased(), default: UnreadRoundWord()].failed[division] = why }
    }

    /// A failure the reload does not count as one: a Trends a server does not have where its
    /// timeline came, a forum's ranking lists switched off. **Neither a failure nor a read**: a
    /// run it was part of is left as it stands.
    func excuse(_ host: String, _ category: FediqoCore.Category?) {
        let division = UnreadDivision(category)
        words.withLock {
            $0[host.lowercased(), default: UnreadRoundWord()].failed[division] = nil
            $0[host.lowercased(), default: UnreadRoundWord()].excused.insert(division)
        }
    }

    /// A read of `host` stopped before it ended — a sign-out, a Clear: this round says nothing of it.
    func stopped(_ host: String) {
        words.withLock { $0[host.lowercased(), default: UnreadRoundWord()].stopped = true }
    }

    /// What this round says of `host`.
    func word(of host: String) -> UnreadRoundWord {
        words.withLock { $0[host.lowercased()] ?? UnreadRoundWord() }
    }

    /// What failed of `host` this round.
    func failures(of host: String) -> [UnreadDivision: UnreadWhy] {
        word(of: host).failed
    }
}

/// Each source's runs of failed rounds, by division, for this run of the app.
struct UnreadRuns: Equatable, Sendable {
    /// **How many rounds in a row a division must fail before it is said.** Three: one failure is
    /// a server busy for a moment or a network dropped as a phone moved, and says nothing more
    /// than the reload's own toast does; three rounds of the wait is minutes without a read.
    static let rounds = 3

    struct Run: Equatable, Sendable {
        /// Rounds in a row it has failed.
        var rounds: Int
        /// When the first of them failed.
        let since: Date
        /// Why the last of them did.
        var why: UnreadWhy
    }

    private(set) var runs: [String: [UnreadDivision: Run]] = [:]

    /// One round's word on `host`: `read` is whether the reload counts it read, `asked` what was
    /// asked of it (nil its usual reads), and `failed` what of it the reads said failed.
    ///
    /// A read that went through takes every division it asked off the count. One that did not
    /// counts each division that failed, once this round, and takes off the rest it asked; a
    /// failure that named no division counts against the whole source. What was `excused` is
    /// left as it stands, neither counted nor taken off.
    mutating func round(
        _ host: String, asked: Set<FediqoCore.Category>?, read: Bool,
        failed: [UnreadDivision: UnreadWhy], excused: Set<UnreadDivision> = [], at moment: Date
    ) {
        let host = host.lowercased()
        var held = runs[host] ?? [:]
        var failed = read ? [:] : failed.filter { !excused.contains($0.key) }
        if !read, failed.isEmpty { failed[.whole] = .outOfReach }
        for division in held.keys
        where failed[division] == nil && !excused.contains(division) && division.read(by: asked) {
            held[division] = nil
        }
        for (division, why) in failed {
            if var run = held[division] {
                run.rounds += 1
                run.why = why
                held[division] = run
            } else {
                held[division] = Run(rounds: 1, since: moment, why: why)
            }
        }
        runs[host] = held.isEmpty ? nil : held
    }

    /// A source let go of: nothing of it is said.
    mutating func forget(_ host: String) {
        runs[host.lowercased()] = nil
    }

    /// A sign-in let go of: what it read is no longer asked, so nothing of it is said.
    mutating func forgetAsYou(_ host: String) {
        let host = host.lowercased()
        runs[host] = runs[host]?.filter { !$0.key.readAsYou }
        if runs[host]?.isEmpty == true { runs[host] = nil }
    }

    /// Whether anything at all is said.
    var saysAny: Bool {
        runs.values.contains { $0.values.contains { $0.rounds >= Self.rounds } }
    }

    /// What is said of `host` on its own row and detail: every division failed past the count.
    func said(_ host: String) -> [UnreadDivision: Run] {
        (runs[host.lowercased()] ?? [:]).filter { $0.value.rounds >= Self.rounds }
    }

    /// What is said of `host` on a timeline drawing `asked` of it: of the divisions it draws on.
    func said(_ host: String, drawnBy asked: Set<FediqoCore.Category>?) -> [UnreadDivision: Run] {
        said(host).filter { $0.key.drawn(by: asked) }
    }

    /// The line said of `host`'s divisions in `said`, or nothing: which of it, since when the
    /// longest run began, and why that one failed last.
    @MainActor
    static func line(
        _ host: String, _ said: [UnreadDivision: Run], sources: [Source], language: DummyLanguage? = nil
    ) -> String? {
        guard let first = said.values.min(by: { $0.since < $1.since }) else { return nil }
        let since = first.since.formatted(
            .dateTime.month(.abbreviated).day().hour().minute().locale(L10n.locale(language))
        )
        let why = L10n.t(first.why.key, language: language)
        let names = said.keys.compactMap { division -> String? in
            switch division {
            case .whole: nil
            case .listNames: L10n.t("source.unread.lists", language: language)
            case .of(let category): RuleText.categoryName(category, host: host, sources: sources, language: language)
            }
        }.sorted()
        guard !said.keys.contains(.whole), !names.isEmpty else {
            return String(format: L10n.t("source.unread.whole", language: language), host, since, why)
        }
        let parts = names.formatted(.list(type: .and).locale(L10n.locale(language)))
        return String(format: L10n.t("source.unread.parts", language: language), parts, host, since, why)
    }
}

extension ShellReload {
    /// `category` of `host` was not read, for `error`, in the round running — nothing outside one.
    func noteUnread(_ category: FediqoCore.Category?, of host: String, _ error: any Error) {
        ReadRound.current?.failed(host, category, error)
    }

    /// A read of `host` was stopped before it ended, in the round running: the round says nothing of it.
    func noteStopped(_ host: String) {
        ReadRound.current?.stopped(host)
    }

    /// `category` of `host` was not read because its server ended the sign-in, in the round running.
    func noteSignedOut(_ category: FediqoCore.Category?, of host: String) {
        ReadRound.current?.failed(host, category, MastodonAuthError.signedOut)
    }

    /// The line `host`'s row and detail say while its reads keep failing, or nothing.
    func unreadLine(host: String, sources: [Source], language: DummyLanguage? = nil) -> String? {
        UnreadRuns.line(host, unreadRuns.said(host), sources: sources, language: language)
    }

    /// What the timeline `query` says of its sources whose reads keep failing — of the divisions
    /// it draws on, and nothing of the rest — a line a source, or none.
    func unreadLines(of query: TimelineQuery, in session: ShellSession, language: DummyLanguage? = nil) -> [String] {
        guard unreadRuns.saysAny else { return [] }
        let sources = session.sources
        let asks = CompiledTimeline(query.definition(among: session.written), sources: sources).sourcesToAsk()
        return asks.compactMap { ask in
            UnreadRuns.line(ask.host, unreadRuns.said(ask.host, drawnBy: ask.categories), sources: sources, language: language)
        }
    }

    /// The whole of what a timeline's head says of `lines`, or nothing where there are none.
    static func unreadHead(_ lines: [String], language: DummyLanguage? = nil) -> String? {
        guard !lines.isEmpty else { return nil }
        let lead = L10n.t(lines.count == 1 ? "timeline.unread.one" : "timeline.unread.many", language: language)
        return ([lead] + lines).joined(separator: " ")
    }
}
