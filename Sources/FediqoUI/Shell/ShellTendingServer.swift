import FediqoCore
import Foundation
import Observation

// The Server tab of tending a server (#384): how it is doing, as a few of its own figures over a
// span the person chooses; what waits to rise on it — hashtags, links, posts — each let rise or
// kept back; and its rules, read, with the way to its own page where they are changed.
//
// **Each part is the role's**: the figures `view_dashboard`'s, what rises `manage_taxonomies'`,
// the rules `manage_rules'`; a part whose flag the role lacks is absent, and the tab with it
// where it lacks all three. Every part the role allows is asked as the tab comes in front; each
// list of what rises reads on by its own foot.
//
// **Every review is the server's, and its answer is the row**, by the rules the other tabs keep:
// numbered as it answers, so a read sent while it was on the wire neither undoes it; written only
// into the page it was pressed on. A refusal says the server's words, or that the standing does
// not allow it, and changes nothing here.
//
// **The figures are the server's, as of when they were read**, and say so. A span chosen asks
// again; a figure for a span chosen before it never lands over it.
//
// **Held for the page alone.** What rises — strangers' posts among it — is let go when the page
// leaves, when who reads changes, and part by part when the role no longer allows it.

/// One part of the Server tab, and the flag of the role it needs.
enum ServerPart: String, CaseIterable, Sendable {
    case measures, rising, rules

    var flag: MastodonStaff {
        switch self {
        case .measures: .viewDashboard
        case .rising: .manageTaxonomies
        case .rules: .manageRules
        }
    }
}

/// What the Server tab is handed: each part the role allows, and nothing of the rest.
struct TendingServerSaid: Equatable {
    struct Measures: Equatable {
        /// The span chosen, in days.
        var days: Int
        /// What the server said of it, where it has answered for this span.
        var said: ServerMeasures?
        var quiet: String?
    }

    struct Rising: Equatable, Identifiable {
        let kind: RisingKind
        var items: [RisingReview] = []
        var more = false
        var quiet: String?
        var id: RisingKind { kind }
    }

    struct Rules: Equatable {
        var rules: [ServerRule] = []
        var quiet: String?
        /// The server's own page of them, where they are changed.
        var page: URL?
    }

    let host: String
    var measures: Measures?
    var rising: [Rising]?
    var rules: Rules?
    /// Whether the sign-in may review what rises: it holds tending's word that changes.
    var acts = false
    /// Rows with a review on the wire, by `rowID`.
    var acting: Set<String> = []
    /// Where the sign-in may not review: tending's lock.
    var lock: PartWords.Place?

    /// The spans a person chooses among, in days.
    static let spans = MastodonAdminServer.spans

    static func rowID(_ kind: RisingKind, _ id: String) -> String { "rising.\(kind.rawValue)\u{1e}\(id)" }
    static func ruleID(_ id: String) -> String { "rule\u{1e}\(id)" }
}

@MainActor
@Observable
final class ShellTendingServer {
    /// One list of what rises as far as it has been read.
    private struct Read: Equatable {
        var rows: [RisingReview] = []
        var next: Int?
        var answered = false
        var failed = false
        var readingOn = false
    }

    private struct Page {
        var under = 0
        var days = TendingServerSaid.spans[0]
        var measures: ServerMeasures?
        var measuresFailed = false
        /// The number of the last ask of the figures: a span asked before it does not land.
        var measuresErrand = 0
        var rising: [RisingKind: Read] = [:]
        var rules: [ServerRule]?
        var rulesFailed = false
        var asking = false
        /// Whether another span's figures are being asked, apart from the tab's whole ask.
        var measuresAsking = false
        var notAllowed: Set<ServerPart> = []
        var awaits = 0
        /// The number of the review that last answered for each row, by `rowID`.
        var acted: [String: Int] = [:]
        var acting: Set<String> = []
    }

    private var pages: [String: Page] = [:]
    private var halted: Set<String> = []
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    /// Another span's figures, asked on their own: stopped as the tab's ask is.
    @ObservationIgnored private var spanAsks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to a server, where a test reaches it by one. Nothing in the app.
    @ObservationIgnored var reaching: ((MastodonAuthorized) -> MastodonAdminServer)?
    /// The moment a figure is said as of. A test fixes it.
    @ObservationIgnored var now: () -> Date = { Date() }

    init(errands: PageErrands) {
        self.errands = errands
    }

    // MARK: - Who may

    /// The parts the role at `host` allows, in the order the tab draws them.
    static func parts(at host: String, in session: ShellSession) -> [ServerPart] {
        guard let staff = session.mastodon.staff(host: host) else { return [] }
        return ServerPart.allCases.filter { staff.allows($0.flag) }
    }

    private func standing(_ host: String, in session: ShellSession) -> Page? {
        pages[host].flatMap { $0.under == ShellPersonPages.signIns(at: host, in: session) ? $0 : nil }
    }

    /// What the role no longer answers for let go, part by part — everything of `host` where it
    /// answers for none: asked at each opening and press.
    private func keepsStanding(at host: String, in session: ShellSession) -> Bool {
        let allowed = Set(Self.parts(at: host, in: session))
        if allowed.isEmpty {
            letGo(at: host)
            return false
        }
        guard pages[host] != nil else { return true }
        if !allowed.contains(.measures) {
            pages[host]?.measures = nil
            pages[host]?.measuresFailed = false
        }
        if !allowed.contains(.rising) { pages[host]?.rising = [:] }
        if !allowed.contains(.rules) {
            pages[host]?.rules = nil
            pages[host]?.rulesFailed = false
        }
        return true
    }

    private func door(at host: String, in session: ShellSession) -> MastodonAdminServer? {
        guard let door = session.mastodon.authorized(host: host, within: deadline, for: .tending) else { return nil }
        return reaching?(door) ?? MastodonAdminServer(door: door)
    }

    // MARK: - What the tab is handed

    func said(of page: Tending, in session: ShellSession, language: DummyLanguage? = nil) -> TendingServerSaid {
        let host = page.host
        let acts = ShellTending.acts(at: host, in: session)
        let allowed = Set(Self.parts(at: host, in: session))
        var said = TendingServerSaid(host: host, acts: acts)
        if !acts { said.lock = session.mastodon.place(.tending, host: host) }
        let held = standing(host, in: session)
        said.acting = held?.acting ?? []
        let notAllowed = String(format: L10n.t("tend.act.notAllowed", language: language), host)
        if allowed.contains(.measures) {
            var measures = TendingServerSaid.Measures(days: held?.days ?? TendingServerSaid.spans[0], said: held?.measures)
            if held?.notAllowed.contains(.measures) == true { measures.quiet = notAllowed }
            said.measures = measures
        }
        if allowed.contains(.rising) {
            said.rising = RisingKind.allCases.map { kind in
                let read = held?.rising[kind]
                var shown = TendingServerSaid.Rising(
                    kind: kind, items: read?.rows ?? [],
                    more: read.map { $0.answered && ($0.next != nil || $0.failed) && !$0.readingOn } ?? false
                )
                if held?.notAllowed.contains(.rising) == true {
                    shown.quiet = notAllowed
                } else if let read, read.answered, read.rows.isEmpty, read.next == nil {
                    shown.quiet = L10n.t("tend.server.rising.none.\(kind.rawValue)", language: language)
                }
                return shown
            }
        }
        if allowed.contains(.rules) {
            var rules = TendingServerSaid.Rules(rules: held?.rules ?? [], page: MastodonAdminServer.rulesPage(host: host))
            if held?.notAllowed.contains(.rules) == true {
                rules.quiet = notAllowed
            } else if held?.rules?.isEmpty == true {
                rules.quiet = String(format: L10n.t("tend.server.rules.none", language: language), host)
            }
            said.rules = rules
        }
        return said
    }

    func walked(_ page: Tending, in session: ShellSession) -> [String] {
        guard let held = standing(page.host, in: session) else { return [] }
        let allowed = Set(Self.parts(at: page.host, in: session))
        var ids: [String] = []
        if allowed.contains(.rising) {
            for kind in RisingKind.allCases {
                ids += (held.rising[kind]?.rows ?? []).map { TendingServerSaid.rowID(kind, $0.id) }
            }
        }
        if allowed.contains(.rules) { ids += (held.rules ?? []).map { TendingServerSaid.ruleID($0.id) } }
        return ids
    }

    /// The row of what rises the lamp is on, where the page holds it.
    func review(_ rowID: String, of page: Tending, in session: ShellSession) -> RisingReview? {
        guard let held = standing(page.host, in: session) else { return nil }
        for kind in RisingKind.allCases {
            if let found = held.rising[kind]?.rows.first(where: { TendingServerSaid.rowID(kind, $0.id) == rowID }) { return found }
        }
        return nil
    }

    func ask(of page: Tending, language: DummyLanguage? = nil) -> PageAsking {
        guard let held = pages[page.host] else { return PageAsking() }
        let readingOn = held.rising.values.contains(where: \.readingOn)
        let failed = held.rising.values.contains(where: \.failed) || held.measuresFailed || held.rulesFailed
        let asking = held.asking || held.measuresAsking
        return PageAsking(
            asking: asking
                ? String(format: L10n.t("tend.server.asking", language: language), page.host)
                : readingOn ? L10n.t("tend.servers.reading", language: language) : nil,
            stoppable: asking,
            failed: failed && !asking && !readingOn ? [page.host] : [],
            stopped: halted.contains(page.host)
        )
    }

    @discardableResult
    func stop(_ page: Tending) -> Bool {
        let host = page.host
        guard pages[host]?.asking == true || pages[host]?.measuresAsking == true else { return false }
        asks[host]?.cancel()
        asks[host] = nil
        spanAsks[host]?.cancel()
        spanAsks[host] = nil
        if pages[host]?.asking == true { pages[host]?.awaits = errands.next() }
        pages[host]?.measuresErrand = errands.next()
        pages[host]?.measuresAsking = false
        pages[host]?.asking = false
        halted.insert(host)
        return true
    }

    // MARK: - Asking

    func opened(_ page: Tending, in session: ShellSession) async {
        guard keepsStanding(at: page.host, in: session) else { return }
        if let held = standing(page.host, in: session) {
            if held.asking {
                await asks[page.host]?.value
                return
            }
            if held.measures != nil || held.rules != nil || !held.rising.isEmpty || !held.notAllowed.isEmpty { return }
        }
        await begin(page, in: session)?.value
    }

    func again(_ page: Tending, in session: ShellSession) async {
        guard keepsStanding(at: page.host, in: session), pages[page.host]?.asking != true else { return }
        await begin(page, in: session)?.value
    }

    /// Every part the role allows asked afresh, at once.
    private func begin(_ page: Tending, in session: ShellSession) -> Task<Void, Never>? {
        let host = page.host
        let allowed = Self.parts(at: host, in: session)
        guard !allowed.isEmpty, ShellTending.drawn(page, in: session), let through = door(at: host, in: session) else { return nil }
        let under = ShellPersonPages.signIns(at: host, in: session)
        if pages[host]?.under != under {
            asks[host]?.cancel()
            pages[host] = Page(under: under)
        }
        let errand = errands.next()
        pages[host]?.awaits = errand
        pages[host]?.asking = true
        pages[host]?.notAllowed = []
        halted.remove(host)
        let days = pages[host]?.days ?? TendingServerSaid.spans[0]
        let measuresErrand = errand
        if allowed.contains(.measures) { pages[host]?.measuresErrand = measuresErrand }
        let task = Task {
            defer { if self.pages[host]?.awaits == errand { self.asks[host] = nil } }
            await withTaskGroup(of: Void.self) { group in
                if allowed.contains(.measures) {
                    group.addTask { await self.readMeasures(days, at: host, through: through, errand: measuresErrand, in: session) }
                }
                if allowed.contains(.rising) {
                    for kind in RisingKind.allCases {
                        group.addTask { await self.read(kind, at: host, from: 0, through: through, errand: errand, in: session) }
                    }
                }
                if allowed.contains(.rules) {
                    group.addTask { await self.readRules(at: host, through: through, errand: errand, in: session) }
                }
            }
            if self.pages[host]?.awaits == errand { self.pages[host]?.asking = false }
        }
        asks[host] = task
        return task
    }

    /// Another span chosen: its figures asked — said as asking, and stoppable, as every ask of
    /// the tab is; a span chosen before, landing after, is not drawn.
    func choose(days: Int, on page: Tending, in session: ShellSession) async {
        let host = page.host
        guard TendingServerSaid.spans.contains(days), keepsStanding(at: host, in: session),
              Self.parts(at: host, in: session).contains(.measures), standing(host, in: session) != nil,
              let through = door(at: host, in: session)
        else { return }
        let errand = errands.next()
        pages[host]?.days = days
        pages[host]?.measures = nil
        pages[host]?.measuresErrand = errand
        pages[host]?.measuresAsking = true
        halted.remove(host)
        spanAsks[host]?.cancel()
        let task = Task {
            await self.readMeasures(days, at: host, through: through, errand: errand, in: session)
            if self.pages[host]?.measuresErrand == errand {
                self.pages[host]?.measuresAsking = false
                self.spanAsks[host] = nil
            }
        }
        spanAsks[host] = task
        await task.value
    }

    private func readMeasures(_ days: Int, at host: String, through: MastodonAdminServer, errand: Int, in session: ShellSession) async {
        do {
            let said = try await through.measures(days: days, now: now())
            guard pages[host]?.measuresErrand == errand else { return }
            pages[host]?.measures = said
            pages[host]?.measuresFailed = false
        } catch {
            guard pages[host]?.measuresErrand == errand else { return }
            failed(error, .measures, at: host, in: session) { pages[host]?.measuresFailed = true }
        }
    }

    private func readRules(at host: String, through: MastodonAdminServer, errand: Int, in session: ShellSession) async {
        do {
            let rules = try await through.rules()
            guard pages[host]?.awaits == errand else { return }
            pages[host]?.rules = rules
            pages[host]?.rulesFailed = false
        } catch {
            guard pages[host]?.awaits == errand else { return }
            failed(error, .rules, at: host, in: session) { pages[host]?.rulesFailed = true }
        }
    }

    /// One list's foot pressed: its next stretch, or again the one that did not come.
    func readOn(_ kind: RisingKind, of page: Tending, in session: ShellSession) async {
        let host = page.host
        guard keepsStanding(at: host, in: session), Self.parts(at: host, in: session).contains(.rising),
              let held = standing(host, in: session), !held.asking, let read = held.rising[kind], !read.readingOn,
              let next = read.next ?? (read.failed ? read.rows.count : nil), let through = door(at: host, in: session)
        else { return }
        pages[host]?.rising[kind]?.readingOn = true
        await self.read(kind, at: host, from: next, through: through, errand: held.awaits, in: session)
        pages[host]?.rising[kind]?.readingOn = false
    }

    private func read(
        _ kind: RisingKind, at host: String, from offset: Int, through: MastodonAdminServer, errand: Int, in session: ShellSession
    ) async {
        do {
            let stretch = try await through.rising(kind, from: offset)
            guard var held = pages[host], held.awaits == errand else { return }
            var read = held.rising[kind] ?? Read()
            // A row a review answered for after this read set out stands as the review left it.
            let current = Dictionary(read.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let landed = stretch.items.map { item in
                (held.acted[TendingServerSaid.rowID(kind, item.id)] ?? 0) > errand ? current[item.id] ?? item : item
            }
            var rows = offset == 0 ? [] : read.rows
            var seen = Set(rows.map(\.id))
            rows += landed.filter { seen.insert($0.id).inserted }
            read.rows = rows
            read.next = stretch.next
            read.answered = true
            read.failed = false
            held.rising[kind] = read
            held.notAllowed.remove(.rising)
            pages[host] = held
        } catch {
            guard pages[host]?.awaits == errand else { return }
            failed(error, .rising, at: host, in: session) {
                if pages[host]?.rising[kind] == nil { pages[host]?.rising[kind] = Read() }
                pages[host]?.rising[kind]?.failed = true
            }
        }
    }

    private func failed(_ error: any Error, _ part: ServerPart, at host: String, in session: ShellSession, _ mark: () -> Void) {
        switch error {
        case MastodonAdminError.notAllowed: pages[host]?.notAllowed.insert(part)
        case MastodonAuthError.signedOut:
            session.mastodon.endedByServer(host: host)
            mark()
        default:
            if !Cancellation.happened(error) { mark() }
        }
    }

    // MARK: - Reviews

    /// `item` let rise — or, with `rise` false, kept back — on `page`'s server: sent once, and its
    /// row the server's answer. A press while it is on the wire sends nothing. Every way this
    /// does not send, and every refusal, says why; nothing here changes by a failure.
    func review(_ item: RisingReview, rise: Bool, on page: Tending, in session: ShellSession) async {
        if let failure = await send(item, rise: rise, on: page, in: session) { session.showToast(failure) }
    }

    private func send(_ item: RisingReview, rise: Bool, on page: Tending, in session: ShellSession) async -> String? {
        let host = page.host
        let kind = item.kind
        let key = TendingServerSaid.rowID(kind, item.id)
        let notAllowed = String(format: L10n.t("tend.act.notAllowed"), host)
        guard keepsStanding(at: host, in: session), Self.parts(at: host, in: session).contains(.rising),
              ShellTending.acts(at: host, in: session)
        else { return notAllowed }
        guard let held = standing(host, in: session) else { return String(format: L10n.t("tend.act.failed"), host) }
        guard !held.acting.contains(key) else { return nil }
        guard let through = door(at: host, in: session) else { return String(format: L10n.t("tend.act.failed"), host) }
        let under = held.under
        pages[host]?.acting.insert(key)
        defer { if pages[host]?.under == under { pages[host]?.acting.remove(key) } }
        do {
            let answered = try await through.review(kind, item.id, rise: rise)
            // **Numbered as it answers**: a read sent while this was on the wire does not undo it.
            let errand = errands.next()
            guard pages[host]?.under == under else { return nil }
            pages[host]?.acted[key] = errand
            if let index = pages[host]?.rising[kind]?.rows.firstIndex(where: { $0.id == item.id }) {
                pages[host]?.rising[kind]?.rows[index] = answered
            }
            return nil
        } catch {
            guard !Cancellation.happened(error) else { return nil }
            switch error {
            case MastodonAdminError.notAllowed: return notAllowed
            case MastodonAdminError.refused(let sentence): return String(format: L10n.t("tend.act.refused"), host, sentence)
            case MastodonAuthError.http(404): return String(format: L10n.t("tend.server.rising.gone"), host)
            case MastodonAuthError.signedOut:
                session.mastodon.endedByServer(host: host)
                return String(format: L10n.t("tend.act.failed"), host)
            default: return String(format: L10n.t("tend.act.failed"), host)
            }
        }
    }

    /// Everything of `host` let go: the page left, who reads it changed, or the role lost.
    func letGo(at host: String) {
        let host = host.lowercased()
        asks[host]?.cancel()
        asks[host] = nil
        spanAsks[host]?.cancel()
        spanAsks[host] = nil
        pages[host] = nil
        halted.remove(host)
    }
}
