import FediqoCore
import Foundation
import Observation
import os

/// What this device is asking of a source **right now** (#164): which host, what for, and since
/// when. Preferences draws it; nothing else reads it.
///
/// **Now, and this run's record beside it** (#218). An entry is made when a piece of work starts
/// reaching a source and dropped when it ends — on success, on failure and on cancellation alike.
/// Every start is also written to `log`, the one record of what this run sent: which source,
/// when, and what for. That record lives in this object's memory and nowhere else — never a
/// file, a default or a store — so quitting the app is the whole of forgetting it (#219).
///
/// **Only the host.** An entry holds a host, a purpose from a fixed list, and a start. Never an
/// address past its host, a body, a header or a token — the same line `NetLog` holds, for the
/// same reason: what is on screen can be read over a shoulder or screenshotted into a report.
/// Where the work reads one timeline or one forum board, it also holds **its name** — the name
/// the reader already sees for it: Home, Public, Trends, a list's title, a board's name in the
/// picker and the tabs — handed in by the caller that knows what it is reading (#164, #170).
/// Never a list's id or a board's number, and never anything read off the request.
///
/// **Where it is fed.** At the one waist every request already goes through — an `HTTPClient` —
/// by wrapping the client where what it is *for* is still known (`WatchedHTTP`). The waist knows
/// the host; only the caller knows the purpose — and the name — so the caller builds the
/// wrapper. A job that is not a request — a forum signing itself in again through its browser —
/// registers itself with `watching(host:for:_:)`.
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
        case search
        /// A page a post links to, opened in the app's own reader.
        case page
        /// A video, played. Fetched by the system's player rather than through an `HTTPClient`.
        case video
        /// A page the person followed inside a forum's sign-in, listed under that forum (#220).
        case signInPage
        /// The check a forum's sign-in shows to prove a person is there — a frame of another
        /// site's, let in only while the person signs in, and listed under that forum (#220).
        case personCheck

        var titleKey: String { "work.purpose.\(rawValue)" }

        /// Pictures and emoji come by the dozen as a timeline scrolls; a row each would be a list
        /// nobody could read. They are one line per host, with a count.
        var gathers: Bool { self == .picture || self == .emoji }
    }

    /// What one piece of work reads, by the name the reader knows it by. The built-ins are held
    /// as themselves and worded when drawn, so a line reads in the shell's language of the
    /// moment; a list's or a board's own name is the reader's, and is drawn as it is.
    enum Name: Equatable, Hashable, Sendable {
        case home
        case `public`
        case trends
        /// A list's title or a board's name, as the reader sees it. Never an id or a number.
        case called(String)

        func text(language: DummyLanguage? = nil) -> String {
            switch self {
            case .home: L10n.t("rule.category.home", language: language)
            case .public: L10n.t("rule.category.public", language: language)
            case .trends: L10n.t("timeline.tab.trends", language: language)
            case .called(let name): name
            }
        }
    }

    /// One piece of work on the wire.
    struct Running: Equatable, Sendable {
        let host: String
        let purpose: Purpose
        /// The timeline or board it reads, by the name the reader knows it by; nil where it reads
        /// no one of them.
        let name: Name?
        let since: Date

        init(host: String, purpose: Purpose, name: Name? = nil, since: Date) {
            self.host = host
            self.purpose = purpose
            self.name = name
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
        /// Acts written since the last copy onto the main actor, oldest first. Only these: the
        /// record itself is the main actor's (`log`), so nothing under this lock grows with the
        /// run and a request's way out never copies it.
        var pending: [SourceAct] = []
        /// Whether a copy onto the main actor is already on its way, so a screenful of pictures
        /// starting at once asks for one and not forty.
        var publishing = false
        /// The sources the person added, folded (#220). Nil until the app says which they are —
        /// see `govern(sources:)`.
        var added: Set<String>?
        /// The hosts the person named to add this run, folded: a look at one, its preview, its
        /// boards and its sign-in are asked before it is a source.
        var named: Set<String> = []
    }

    @ObservationIgnored private nonisolated let held = OSAllocatedUnfairLock(initialState: Held())

    /// What the page draws: everything running, as of the last copy onto the main actor.
    private(set) var running: [Int: Running] = [:]

    /// This run's record as the activity page draws it (#218), as of the last copy onto the main
    /// actor. An object of its own and not a property here, so it grows in place — a value would
    /// be copied whole on every change — and so what observes it is the page that reads it and
    /// not Preferences' section, which reads `running`.
    @ObservationIgnored let log = SourceRecord()

    nonisolated init() {}

    /// Starts a piece of work on `host` and writes it to the run's record under `source` — the
    /// source that pointed there, where the host is not that source's own (a picture, an emoji on
    /// another host). Nil where the host is the source.
    nonisolated func begin(
        host: String, for purpose: Purpose, name: Name? = nil, source: String? = nil,
        allowedBy: Allowance.ID? = nil
    ) -> Token {
        let now = Date()
        let entry = Running(host: host.lowercased(), purpose: purpose, name: Self.named(name), since: now)
        let (token, publish) = held.withLock { held -> (Token, Bool) in
            held.next += 1
            held.running[held.next] = entry
            Self.write(&held, reached: host, source: source, purpose: purpose, at: now, allowedBy: allowedBy)
            return (Token(id: held.next), Self.claim(&held))
        }
        if publish { schedule() }
        return token
    }

    /// Writes one act to the run's record that is not a request through an `HTTPClient` — a page
    /// opened in the reader, a video handed to the player — and so is never on the running list.
    nonisolated func note(
        host: String, for purpose: Purpose, source: String? = nil, allowedBy: Allowance.ID? = nil
    ) {
        let publish = held.withLock { held -> Bool in
            held.next += 1
            Self.write(
                &held, reached: host, source: source, purpose: purpose, at: Date(), allowedBy: allowedBy
            )
            return Self.claim(&held)
        }
        if publish { schedule() }
    }

    // MARK: - Whose it is (#220)

    /// From now on, an act that belongs to none of `hosts` — or to a host the person names to add
    /// later — is refused (`admits`). The app says this once, at launch, before anything is
    /// asked; a `SourceWork` never told governs nothing, which is what a test that is not about
    /// the gate builds.
    nonisolated func govern(sources hosts: some Sequence<String>) {
        let folded = Set(hosts.map(Self.fold))
        held.withLock { $0.added = folded }
    }

    /// The sources the person has now. A source let go takes back what naming it let through.
    /// Nothing, where nobody said `govern`.
    nonisolated func sourcesChanged(_ hosts: some Sequence<String>) {
        let folded = Set(hosts.map(Self.fold))
        held.withLock { held in
            guard let added = held.added else { return }
            held.named.subtract(added.subtracting(folded))
            held.added = folded
        }
    }

    /// The person named `host` to add: what is asked of it before it is a source is theirs.
    nonisolated func named(_ host: String) {
        let folded = Self.fold(host)
        held.withLock { _ = $0.named.insert(folded) }
    }

    /// Whether an act that reaches `reached`, pointed there by `source`, belongs to a source the
    /// person added or named — the source that pointed to it where one did, and otherwise the
    /// host itself (`SourceAct.attributed`). Always, where nothing governs.
    ///
    /// **One act reaches past every source, and only as itself** (#220): the directory of servers,
    /// read `for: .directory` while a source is being added. It is its own host and its own row,
    /// and no other purpose reaches it.
    nonisolated func admits(
        reached: String, source: String?, for purpose: Purpose? = nil
    ) -> Bool {
        admission(reached: reached, source: source, for: purpose) != nil
    }

    /// Why an act may leave: it is a source's, or an entry of `Allowance` lets it through — and
    /// which, so the record can say. Nil where neither.
    enum Admission: Equatable, Sendable {
        case source
        case allowed(Allowance.ID)

        var allowedBy: Allowance.ID? {
            if case .allowed(let id) = self { id } else { nil }
        }
    }

    nonisolated func admission(
        reached: String, source: String?, for purpose: Purpose? = nil,
        allowing list: [Allowance] = Allowance.standing
    ) -> Admission? {
        let owner = Self.fold(SourceAct.attributed(reached: reached, pointedBy: source))
        let ours = held.withLock { held -> Bool in
            guard let added = held.added else { return true }
            return !owner.isEmpty && (added.contains(owner) || held.named.contains(owner))
        }
        if ours { return .source }
        // A request an entry names by its purpose, to one of its hosts, asked of nobody's pointing.
        guard let purpose, source == nil, let url = URL(string: "https://\(owner)/") else { return nil }
        let entry = list.first { $0.reach == .request(purpose) && $0.allows(url) }
        return entry.map { .allowed($0.id) }
    }

    /// A host as the gate compares it: lower case, no port, and `www.` the same site as without.
    ///
    /// **One spelling of a name that is not ASCII**: its punycode, `xn--…`, whichever way it came
    /// — typed in Unicode, written so by a server, or percent-encoded as `URL.host()` hands it
    /// back — so a source added as `bücher.example` owns what is asked of `xn--bcher-kva.example`.
    nonisolated static func fold(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let ascii = URL(string: "https://" + decoded)?.host(percentEncoded: false) ?? decoded
        return ForumWebEngine.bare(ascii.lowercased())
    }

    /// This run's record this instant, oldest first: whatever is still on its way is copied over
    /// first.
    var record: [SourceAct] {
        publish()
        return log.acts
    }

    /// An act with no host reached nowhere — a `file:` address, a malformed one — and is not
    /// written.
    private nonisolated static func write(
        _ held: inout Held, reached: String, source: String?, purpose: Purpose, at: Date,
        allowedBy: Allowance.ID?
    ) {
        guard !reached.isEmpty else { return }
        held.pending.append(SourceAct(
            id: held.next, reached: reached, pointedBy: source, purpose: purpose, at: at,
            allowedBy: allowedBy
        ))
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
        host: String, for purpose: Purpose, name: Name? = nil, _ body: () async throws -> T
    ) async rethrows -> T {
        let token = begin(host: host, for: purpose, name: name, source: nil)
        defer { end(token) }
        return try await body()
    }

    /// What the page lists: one line per piece of work, except pictures and emoji, which are one
    /// line per host with a count. Longest-running first — a stall is what someone opens this
    /// page to find.
    var rows: [SourceWorkRow] { SourceWorkRow.rows(of: Array(running)) }

    /// A name as a line can show it: a reader's own trimmed, and nothing where nothing is left.
    private nonisolated static func named(_ name: Name?) -> Name? {
        guard case .called(let called) = name else { return name }
        let trimmed = called.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : .called(trimmed)
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
        let (now, fresh) = held.withLock { held in
            held.publishing = false
            let fresh = held.pending
            held.pending = []
            return (held.running, fresh)
        }
        if now != running { running = now }
        if !fresh.isEmpty { log.append(fresh) }
    }
}

/// One line on the page. Built from the registry, never from a request.
struct SourceWorkRow: Identifiable, Equatable {
    let id: String
    let host: String
    let purpose: SourceWork.Purpose
    /// The timeline or board it reads, by the name the reader knows it. Never on a gathered line.
    var name: SourceWork.Name? = nil
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
                    id: "\(id)", host: work.host, purpose: work.purpose, name: work.name, count: 1,
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

    /// What the line says it is for: then the timeline or board it reads, where it names one, or
    /// the count where it gathers more than one. Drawn after the host, and read by VoiceOver in that order.
    func purposeText(language: DummyLanguage? = nil) -> String {
        let title = L10n.t(purpose.titleKey, language: language)
        guard purpose.gathers else {
            return name.map { title + " · " + $0.text(language: language) } ?? title
        }
        return title + " · " + L10n.count("work.count", count, language: language)
    }
}

/// An `HTTPClient` — and a sender — that puts each request on `SourceWork` while it runs: its
/// host, and the purpose — and the name, where it reads one timeline or board — that the caller
/// that built it knows. Nothing else of the request is read.
///
/// The entry is ended on the way out of every path: an answer, a failure, and a cancellation,
/// which throws like any failure does.
struct WatchedHTTP: HTTPClient, HTTPSender {
    private let get: (@Sendable (URL) async throws -> (Data, HTTPURLResponse))?
    private let sender: (any HTTPSender)?
    let purpose: SourceWork.Purpose
    /// What its caller is reading through it, by the name the reader knows; nil for none.
    let name: SourceWork.Name?
    /// The source whose post pointed at what this client fetches, where that is not the host a
    /// request goes to: a picture or an emoji kept on another server (#218). Nil where every
    /// request through it goes to its source's own host.
    let source: String?
    let work: SourceWork

    init(
        _ inner: any HTTPClient, for purpose: SourceWork.Purpose, name: SourceWork.Name? = nil,
        source: String? = nil, in work: SourceWork
    ) {
        get = { try await inner.data(from: $0) }
        sender = inner as? any HTTPSender
        self.purpose = purpose
        self.name = name
        self.source = source
        self.work = work
    }

    init(
        sender inner: any HTTPSender, for purpose: SourceWork.Purpose, name: SourceWork.Name? = nil,
        in work: SourceWork
    ) {
        get = nil
        sender = inner
        self.purpose = purpose
        self.name = name
        source = nil
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
        let host = url.host() ?? ""
        // **The gate** (#220): an act that belongs to no source the person added never leaves,
        // and is not written to the record as though it had.
        guard let admission = work.admission(reached: host, source: source, for: purpose) else {
            NetLog.network.notice(
                "\(NetLog.line("refused", host: host, error: OutwardRefusal.noSource), privacy: .public)"
            )
            throw OutwardRefusal.noSource
        }
        // Synchronous both ways, and so never behind the main actor: see `SourceWork`.
        let token = work.begin(
            host: host, for: purpose, name: name, source: source, allowedBy: admission.allowedBy
        )
        defer { work.end(token) }
        return try await Outward.$admitted.withValue(true) { try await body() }
    }
}

/// One outward act of this run, as the activity page lists it (#218): the source it was for, what
/// for, and when it left. **Built from a host and a word from a fixed list, never from an
/// address**, so nothing past a host — no path, no query, no body, no header, no token — can
/// reach the page through here: the rule `NetLog` holds, for its reason.
///
/// **Who it is listed under.** A source's own traffic goes to the source's own host. A picture, an
/// emoji or a page a source pointed to may be kept somewhere else — a media server, another
/// instance, the page a post links to — and is listed under the source that pointed to it, which
/// the caller that knows it says (`pointedBy`). Both hosts are held: `source` is what the page
/// lists and narrows by, and `reached` is where the request actually went — not drawn, and held
/// so a later check of where a request may go (#220) can ask who sent it there.
struct SourceAct: Identifiable, Equatable, Sendable {
    let id: Int
    /// The source it is listed under, folded as every host here is.
    let source: String
    /// Where it went. The same as `source` except where a source pointed somewhere else.
    let reached: String
    let purpose: SourceWork.Purpose
    let at: Date
    /// The entry of `Allowance` that let it through, where it was not a source's own (#220).
    let allowedBy: Allowance.ID?

    init(
        id: Int, reached: String, pointedBy: String? = nil, purpose: SourceWork.Purpose, at: Date,
        allowedBy: Allowance.ID? = nil
    ) {
        self.id = id
        self.reached = reached.lowercased()
        source = Self.attributed(reached: reached, pointedBy: pointedBy)
        self.purpose = purpose
        self.at = at
        self.allowedBy = allowedBy
    }

    /// The source an act is listed under: the one that pointed to it where one did, and
    /// otherwise the host it went to. An empty pointer is no pointer.
    static func attributed(reached: String, pointedBy: String?) -> String {
        let pointer = pointedBy?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return pointer.isEmpty ? reached.lowercased() : pointer
    }


    /// When it left, as a clock reads it, in the shell's language.
    func time(language: DummyLanguage? = nil) -> String {
        at.formatted(
            Date.FormatStyle(date: .omitted, time: .standard).locale(L10n.locale(language))
        )
    }

    /// What it was for, in the shell's language.
    func purposeText(language: DummyLanguage? = nil) -> String {
        L10n.t(purpose.titleKey, language: language)
    }

    /// The row as VoiceOver reads it: the source, what for, and when — one sentence, in that
    /// order.
    func spoken(language: DummyLanguage? = nil) -> String {
        String(
            format: L10n.t("activity.row.spoken", language: language),
            source, purposeText(language: language), time(language: language)
        )
    }
}

/// This run's record, on the main actor (#218): every act, oldest first, bounded, and indexed by
/// source as it grows — so what the page draws is read off it and never computed from the whole
/// record on a redraw.
///
/// **Bounded in chunks.** Past `kept` the oldest are let go down to `trimmedTo` in one cut, so the
/// shift and the reindex are paid once per thousand acts rather than on every one; `dropped`
/// counts every act let go.
@MainActor
@Observable
final class SourceRecord {
    /// How many acts are held at most. A bound and not a working size: a long day's reading is
    /// some thousands of acts, and nothing held here may grow without end.
    nonisolated static let kept = 10_000
    /// What a cut past `kept` leaves.
    nonisolated static let trimmedTo = 9_000

    private(set) var acts: [SourceAct] = []
    /// How many of the oldest acts were let go.
    private(set) var dropped = 0
    /// The sources the record holds acts for, in the order a picker lists them.
    private(set) var sources: [String] = []
    /// Observed, and that is load-bearing: a page narrowed to one source reads only this, and has
    /// to be woken when a line of that source arrives.
    private var bySource: [String: [SourceAct]] = [:]

    nonisolated init() {}

    func append(_ fresh: [SourceAct]) {
        acts.append(contentsOf: fresh)
        for act in fresh {
            if bySource[act.source] == nil {
                let at = sources.firstIndex { $0 > act.source } ?? sources.endIndex
                sources.insert(act.source, at: at)
            }
            bySource[act.source, default: []].append(act)
        }
        guard acts.count > Self.kept else { return }
        let cut = acts.count - Self.trimmedTo
        acts.removeFirst(cut)
        dropped += cut
        bySource = Dictionary(grouping: acts, by: \.source)
        sources = bySource.keys.sorted()
    }

    /// Newest first, and only `source`'s where one is chosen.
    func listed(from source: String? = nil) -> ReversedCollection<[SourceAct]> {
        guard let source else { return acts.reversed() }
        return (bySource[source.lowercased()] ?? []).reversed()
    }
}
