import FediqoCore
import Foundation
import Observation
import os

/// What this device is asking of a source **right now** (#164): which host, what for, and since
/// when. Preferences draws it; nothing else reads it.
///
/// **Now only.** An entry is made when a piece of work starts reaching a source and dropped when
/// it ends — on success, on failure and on cancellation alike — and nothing of it is kept after.
/// There is no history here and there must not be one: the full record of what this app sends is
/// a later milestone's, and a ledger grown here would be a second one to reconcile with it.
///
/// **Only the host.** An entry holds a host, a purpose from a fixed list, and a start. Never an
/// address past its host, a body, a header or a token — the same line `NetLog` holds, for the
/// same reason: what is on screen can be read over a shoulder or screenshotted into a report.
/// Where the work reads one forum board, it also holds **that board's name** — the name the
/// reader already sees for it in the picker and the tabs, handed in by the caller that knows
/// which board it is reading. Never its number, and never anything read off the request.
///
/// **Where it is fed.** At the one waist every request already goes through — an `HTTPClient` —
/// by wrapping the client where what it is *for* is still known (`WatchedHTTP`). The waist knows
/// the host; only the caller knows the purpose — and the board — so the caller builds the wrapper. A job that is
/// not a request — a forum signing itself in again through its browser — registers itself with
/// `watching(host:for:_:)`.
///
/// **Begun and ended without waiting on the main actor.** A request's way out must not queue
/// behind whatever the main actor is doing: a reload landing while the reader's own press holds
/// it would otherwise sit finished and unreturned until the press let go, and the list's
/// bookkeeping would have changed the order work lands in. So the entries live under a lock that
/// any thread takes for a moment, and what the page draws is copied onto the main actor after —
/// `running`, observed, and read only by the page's own section, so a picture starting and ending
/// wakes that section and nothing else in the app.
@MainActor
@Observable
final class SourceWork {
    /// The one the app feeds and Preferences reads. A test builds its own and hands it in.
    static let shared = SourceWork()

    /// What a piece of work is for, in words a reader knows. A fixed list, so nothing a request
    /// carried can reach the page through here.
    enum Purpose: String, CaseIterable, Sendable {
        case timeline
        case conversation
        case forumPost
        case forumReplies
        case lists
        case joining
        case boards
        case directory
        case serverCheck
        case picture
        case emoji
        case signInCheck
        case signIn
        case signOut
        case write

        var titleKey: String { "work.purpose.\(rawValue)" }

        /// Pictures and emoji come by the dozen as a timeline scrolls; a row each would be a list
        /// nobody could read. They are one line per host, with a count.
        var gathers: Bool { self == .picture || self == .emoji }
    }

    /// One piece of work on the wire.
    struct Running: Equatable, Sendable {
        let host: String
        let purpose: Purpose
        /// The board it reads, by the name the reader knows it by; nil where it reads no one board.
        let board: String?
        let since: Date

        init(host: String, purpose: Purpose, board: String? = nil, since: Date) {
            self.host = host
            self.purpose = purpose
            self.board = board
            self.since = since
        }
    }

    /// What `begin` hands back and `end` takes. Ending one twice, or one already gone, is nothing.
    struct Token: Hashable, Sendable {
        fileprivate let id: Int
    }

    private struct Held: Sendable {
        var running: [Int: Running] = [:]
        var next = 0
        /// Whether a copy onto the main actor is already on its way, so a screenful of pictures
        /// starting at once asks for one and not forty.
        var publishing = false
    }

    @ObservationIgnored private nonisolated let held = OSAllocatedUnfairLock(initialState: Held())

    /// What the page draws: everything running, as of the last copy onto the main actor.
    private(set) var running: [Int: Running] = [:]

    nonisolated init() {}

    nonisolated func begin(host: String, for purpose: Purpose, board: String? = nil) -> Token {
        let entry = Running(
            host: host.lowercased(), purpose: purpose, board: Self.named(board), since: Date()
        )
        let (token, publish) = held.withLock { held -> (Token, Bool) in
            held.next += 1
            held.running[held.next] = entry
            return (Token(id: held.next), Self.claim(&held))
        }
        if publish { schedule() }
        return token
    }

    nonisolated func end(_ token: Token) {
        let publish = held.withLock { held -> Bool in
            guard held.running.removeValue(forKey: token.id) != nil else { return false }
            return Self.claim(&held)
        }
        if publish { schedule() }
    }

    /// Everything running this instant, read under the lock rather than off the last copy.
    nonisolated var now: [Int: Running] {
        held.withLock { $0.running }
    }

    /// `body`, registered while it runs and ended on every way out of it.
    func watching<T>(
        host: String, for purpose: Purpose, board: String? = nil, _ body: () async throws -> T
    ) async rethrows -> T {
        let token = begin(host: host, for: purpose, board: board)
        defer { end(token) }
        return try await body()
    }

    /// What the page lists: one line per piece of work, except pictures and emoji, which are one
    /// line per host with a count. Longest-running first — a stall is what someone opens this
    /// page to find.
    var rows: [SourceWorkRow] { SourceWorkRow.rows(of: Array(running)) }

    /// A board's name as a line can show it: trimmed, and nothing where nothing is left.
    private nonisolated static func named(_ board: String?) -> String? {
        guard let board = board?.trimmingCharacters(in: .whitespacesAndNewlines),
              !board.isEmpty
        else { return nil }
        return board
    }

    private nonisolated static func claim(_ held: inout Held) -> Bool {
        guard !held.publishing else { return false }
        held.publishing = true
        return true
    }

    private nonisolated func schedule() {
        Task { @MainActor [weak self] in self?.publish() }
    }

    /// Copies what is running onto the main actor for the page. Assigned only when it differs:
    /// the section redraws on every assignment.
    private func publish() {
        let now = held.withLock { held -> [Int: Running] in
            held.publishing = false
            return held.running
        }
        if now != running { running = now }
    }
}

/// One line on the page. Built from the registry, never from a request.
struct SourceWorkRow: Identifiable, Equatable {
    let id: String
    let host: String
    let purpose: SourceWork.Purpose
    /// The board it reads, by the name the reader knows it by. Never on a gathered line.
    var board: String? = nil
    /// How many are running under this line: one, except where the purpose gathers.
    let count: Int
    /// When the oldest of them started.
    let since: Date

    static func rows(of running: [(key: Int, value: SourceWork.Running)]) -> [SourceWorkRow] {
        var rows: [SourceWorkRow] = []
        var gathered: [String: SourceWorkRow] = [:]
        for (id, work) in running {
            guard work.purpose.gathers else {
                rows.append(SourceWorkRow(
                    id: "\(id)", host: work.host, purpose: work.purpose, board: work.board, count: 1,
                    since: work.since
                ))
                continue
            }
            let key = "\(work.purpose.rawValue) \(work.host)"
            let held = gathered[key]
            gathered[key] = SourceWorkRow(
                id: key, host: work.host, purpose: work.purpose, count: (held?.count ?? 0) + 1,
                since: min(held?.since ?? work.since, work.since)
            )
        }
        return (rows + gathered.values).sorted {
            ($0.since, $0.host, $0.purpose.rawValue, $0.id) < ($1.since, $1.host, $1.purpose.rawValue, $1.id)
        }
    }

    /// How long it has been running, in whole seconds, in the shell's language.
    static func elapsed(since: Date, now: Date, language: DummyLanguage? = nil) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        guard seconds >= 60 else {
            return String(format: L10n.t("work.elapsed.seconds", language: language), seconds)
        }
        return String(
            format: L10n.t("work.elapsed.minutes", language: language), seconds / 60, seconds % 60
        )
    }

    /// What the line says it is for: then the board it reads, where it reads one, or the count
    /// where it gathers more than one. Drawn after the host, and read by VoiceOver in that order.
    func purposeText(language: DummyLanguage? = nil) -> String {
        let title = L10n.t(purpose.titleKey, language: language)
        guard purpose.gathers else { return board.map { title + " · " + $0 } ?? title }
        return title + " · " + L10n.count("work.count", count, language: language)
    }
}

/// An `HTTPClient` — and a sender — that puts each request on `SourceWork` while it runs: its
/// host, and the purpose — and the board, where it reads one — that the caller that built it
/// knows. Nothing else of the request is read.
///
/// The entry is ended on the way out of every path: an answer, a failure, and a cancellation,
/// which throws like any failure does.
struct WatchedHTTP: HTTPClient, HTTPSender {
    private let get: (@Sendable (URL) async throws -> (Data, HTTPURLResponse))?
    private let sender: (any HTTPSender)?
    let purpose: SourceWork.Purpose
    /// The board its caller is reading through it, by the name the reader knows; nil for none.
    let board: String?
    let work: SourceWork

    init(
        _ inner: any HTTPClient, for purpose: SourceWork.Purpose, board: String? = nil,
        in work: SourceWork
    ) {
        get = { try await inner.data(from: $0) }
        sender = inner as? any HTTPSender
        self.purpose = purpose
        self.board = board
        self.work = work
    }

    init(sender inner: any HTTPSender, for purpose: SourceWork.Purpose, in work: SourceWork) {
        get = nil
        sender = inner
        self.purpose = purpose
        board = nil
        self.work = work
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        guard let get else { return try await send(URLRequest(url: url)) }
        return try await watched(url) { try await get(url) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let sender, let url = request.url else { throw URLError(.unsupportedURL) }
        return try await watched(url) { try await sender.send(request) }
    }

    private func watched(
        _ url: URL, _ body: @Sendable () async throws -> (Data, HTTPURLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        // Synchronous both ways, and so never behind the main actor: see `SourceWork`.
        let token = work.begin(host: url.host() ?? "", for: purpose, board: board)
        defer { work.end(token) }
        return try await body()
    }
}
