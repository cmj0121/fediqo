import FediqoCore
import Foundation
import Observation

// The Dashboard, Trends and Rules tabs of a host's page (#384, #416): how it is doing, as a few
// of its own figures over a span the person chooses — and, over the same span, who stays, month
// by month, and what it holds by language, by server and by software (#418); every hashtag it
// knows, let rise or kept back and let be used or not, and the sites its links come from, each
// let rise or kept back for all its links (#419); what waits to rise on it — hashtags, links,
// posts — each let rise or kept back; and its rules, read, with the way to its own page where
// they are changed.
//
// **Each part is its own tab, and its flag's**: the figures `view_dashboard`'s, what rises
// `manage_taxonomies'`, the rules `manage_rules'`; a tab whose flag the role lacks is absent, and
// **asks nothing** — a role holding one flag never asks another tab's part. Each tab's part is
// asked as the tab comes in front, in a state of its own; each list of what rises reads on by
// its own foot.
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

/// One part of a server's figures, what rises and its rules, the tab it is, and so the flag of the
/// role it needs.
enum ServerPart: String, CaseIterable, Sendable {
    case measures, rising, rules

    var tab: AdminTab {
        switch self {
        case .measures: .dashboard
        case .rising: .rising
        case .rules: .rules
        }
    }

    var flag: MastodonStaff { tab.flag }
}

/// The two lists of the Trends tab beside what waits to rise (#419): every hashtag the server
/// knows, and the sites its links come from.
enum KnownList: String, CaseIterable, Sendable {
    case tags, sites
}

/// What the Dashboard, Trends or Rules tab is handed: its own part, where the role allows it, and
/// nothing of the rest.
struct TendingServerSaid: Equatable {
    struct Measures: Equatable {
        /// The span chosen, in days.
        var days: Int
        /// What the server said of it, where it has answered for this span.
        var said: ServerMeasures?
        var quiet: String?
        /// What it holds, broken down over the span (#418), where it has answered for it.
        var breakdowns: ServerBreakdowns?
        /// What stands where the breakdowns would: that they could not be read.
        var breakdownsQuiet: String?
        /// Who stayed, month by month over the span (#418), where it has answered for it.
        var retention: ServerRetention?
        var retentionQuiet: String?
    }

    /// The breakdowns asked of a server (#418): by language, by server, by software and version.
    static let breakdownKeys: [ServerBreakdown.Key] = [.languages, .servers, .software]

    /// The months of who stays a span of `days` covers: the month it ends in and each one it
    /// reaches back into, at most the year the server counts.
    static func months(days: Int) -> Int {
        min(MastodonAdminDashboard.mostMonths, days / 30 + 1)
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
    /// Every hashtag the server knows (#419), beside what waits to rise.
    var tags: ServerListSaid<AdminTag>?
    /// The sites its links come from (#419).
    var sites: ServerListSaid<LinkSite>?
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
    static func knownID(_ list: KnownList, _ id: String) -> String { "known.\(list.rawValue)\u{1e}\(id)" }

    /// A change to a hashtag the server knows (#419): let rise or kept back, let be used or not.
    enum TagChange: Equatable {
        case rises(Bool)
        case usable(Bool)
    }
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

    /// One list of what the server knows as far as it has been read, by the server's own next.
    private struct Known<Item: Equatable>: Equatable {
        var rows: [Item] = []
        var next: String?
        var answered = false
        var failed = false
        var readingOn = false
    }

    private struct Page {
        var under = 0
        var days = TendingServerSaid.spans[0]
        var measures: ServerMeasures?
        var measuresFailed = false
        var breakdowns: ServerBreakdowns?
        var breakdownsFailed = false
        var retention: ServerRetention?
        var retentionFailed = false
        /// The number of the last ask of the figures: a span asked before it does not land.
        var measuresErrand = 0
        var rising: [RisingKind: Read] = [:]
        var tags = Known<AdminTag>()
        var sites = Known<LinkSite>()
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

    /// Each tab's part, by `key`: a tab's ask is its own.
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

    /// The part of `page`'s tab, where the role allows it: none on any other tab.
    static func parts(of page: Tending, in session: ShellSession) -> [ServerPart] {
        parts(at: page.host, in: session).filter { $0.tab == page.tab }
    }

    private static func key(_ host: String, _ part: ServerPart) -> String { host + "\u{1e}" + part.tab.rawValue }
    private static func key(_ page: Tending) -> String { page.host + "\u{1e}" + page.tab.rawValue }

    private func standing(_ page: Tending, in session: ShellSession) -> Page? {
        pages[Self.key(page)].flatMap { $0.under == ShellPersonPages.signIns(at: page.host, in: session) ? $0 : nil }
    }

    private func standing(_ host: String, _ part: ServerPart, in session: ShellSession) -> Page? {
        standing(Tending(host: host, tab: part.tab), in: session)
    }

    /// What the role no longer answers for let go, part by part — everything of `host` where it
    /// answers for none: asked at each opening and press.
    private func keepsStanding(at host: String, in session: ShellSession) -> Bool {
        let allowed = Set(Self.parts(at: host, in: session))
        if allowed.isEmpty {
            letGo(at: host)
            return false
        }
        for part in ServerPart.allCases where !allowed.contains(part) {
            let key = Self.key(host, part)
            asks[key]?.cancel()
            asks[key] = nil
            spanAsks[key]?.cancel()
            spanAsks[key] = nil
            pages[key] = nil
            halted.remove(key)
        }
        return true
    }

    /// The way to the hashtags the server knows and the sites its links come from (#419).
    private func taxonomies(at host: String, in session: ShellSession) -> MastodonAdminTaxonomies? {
        session.mastodon.authorized(host: host, within: deadline, for: .tending).map(MastodonAdminTaxonomies.init(door:))
    }

    /// The way to how the server is doing beyond its own figures (#418).
    private func dashboard(at host: String, in session: ShellSession) -> MastodonAdminDashboard? {
        session.mastodon.authorized(host: host, within: deadline, for: .tending).map(MastodonAdminDashboard.init(door:))
    }

    private func door(at host: String, in session: ShellSession) -> MastodonAdminServer? {
        guard let door = session.mastodon.authorized(host: host, within: deadline, for: .tending) else { return nil }
        return reaching?(door) ?? MastodonAdminServer(door: door)
    }

    // MARK: - What the tab is handed

    func said(of page: Tending, in session: ShellSession, language: DummyLanguage? = nil) -> TendingServerSaid {
        let host = page.host
        let acts = ShellTending.acts(at: host, in: session)
        let allowed = Set(Self.parts(of: page, in: session))
        var said = TendingServerSaid(host: host, acts: acts)
        if !acts { said.lock = session.mastodon.place(.tending, host: host) }
        let held = standing(page, in: session)
        said.acting = held?.acting ?? []
        let notAllowed = String(format: L10n.t("tend.act.notAllowed", language: language), host)
        if allowed.contains(.measures) {
            var measures = TendingServerSaid.Measures(
                days: held?.days ?? TendingServerSaid.spans[0], said: held?.measures, breakdowns: held?.breakdowns,
                retention: held?.retention
            )
            if held?.notAllowed.contains(.measures) == true { measures.quiet = notAllowed }
            let unread = String(format: L10n.t("tend.server.dashboard.failed", language: language), host)
            if held?.breakdownsFailed == true { measures.breakdownsQuiet = unread }
            if held?.retentionFailed == true { measures.retentionQuiet = unread }
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
        if allowed.contains(.rising) {
            func known<Item: Equatable>(_ list: KnownList, _ read: Known<Item>?) -> ServerListSaid<Item> {
                var shown = ServerListSaid(items: read?.rows ?? [], more: read.map { $0.answered && ($0.next != nil || $0.failed) && !$0.readingOn } ?? false)
                if held?.notAllowed.contains(.rising) == true {
                    shown.quiet = notAllowed
                } else if let read, read.answered, read.rows.isEmpty, read.next == nil {
                    shown.quiet = L10n.t("tend.server.known.none.\(list.rawValue)", language: language)
                }
                return shown
            }
            said.tags = known(.tags, held?.tags)
            said.sites = known(.sites, held?.sites)
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
        guard let held = standing(page, in: session) else { return [] }
        let allowed = Set(Self.parts(of: page, in: session))
        var ids: [String] = []
        if allowed.contains(.rising) {
            for kind in RisingKind.allCases {
                ids += (held.rising[kind]?.rows ?? []).map { TendingServerSaid.rowID(kind, $0.id) }
            }
            ids += held.tags.rows.map { TendingServerSaid.knownID(.tags, $0.id) }
            ids += held.sites.rows.map { TendingServerSaid.knownID(.sites, $0.id) }
        }
        if allowed.contains(.rules) { ids += (held.rules ?? []).map { TendingServerSaid.ruleID($0.id) } }
        return ids
    }

    /// The row of what rises the lamp is on, where the page holds it.
    func review(_ rowID: String, of page: Tending, in session: ShellSession) -> RisingReview? {
        guard let held = standing(page.host, .rising, in: session) else { return nil }
        for kind in RisingKind.allCases {
            if let found = held.rising[kind]?.rows.first(where: { TendingServerSaid.rowID(kind, $0.id) == rowID }) { return found }
        }
        return nil
    }

    func ask(of page: Tending, language: DummyLanguage? = nil) -> PageAsking {
        let key = Self.key(page)
        guard let held = pages[key] else { return PageAsking() }
        let readingOn = held.rising.values.contains(where: \.readingOn) || held.tags.readingOn || held.sites.readingOn
        let failed = held.rising.values.contains(where: \.failed) || held.tags.failed || held.sites.failed || held.measuresFailed || held.breakdownsFailed || held.retentionFailed
            || held.rulesFailed
        let asking = held.asking || held.measuresAsking
        return PageAsking(
            asking: asking
                ? String(format: L10n.t("tend.server.asking", language: language), page.host)
                : readingOn ? L10n.t("tend.servers.reading", language: language) : nil,
            stoppable: asking,
            failed: failed && !asking && !readingOn ? [page.host] : [],
            stopped: halted.contains(key)
        )
    }

    @discardableResult
    func stop(_ page: Tending) -> Bool {
        let key = Self.key(page)
        guard pages[key]?.asking == true || pages[key]?.measuresAsking == true else { return false }
        asks[key]?.cancel()
        asks[key] = nil
        spanAsks[key]?.cancel()
        spanAsks[key] = nil
        if pages[key]?.asking == true { pages[key]?.awaits = errands.next() }
        pages[key]?.measuresErrand = errands.next()
        pages[key]?.measuresAsking = false
        pages[key]?.asking = false
        halted.insert(key)
        return true
    }

    // MARK: - Asking

    func opened(_ page: Tending, in session: ShellSession) async {
        guard keepsStanding(at: page.host, in: session) else { return }
        if let held = standing(page, in: session) {
            if held.asking {
                await asks[Self.key(page)]?.value
                return
            }
            if held.measures != nil || held.rules != nil || !held.rising.isEmpty || held.tags.answered || !held.notAllowed.isEmpty {
                return
            }
        }
        await begin(page, in: session)?.value
    }

    func again(_ page: Tending, in session: ShellSession) async {
        guard keepsStanding(at: page.host, in: session), pages[Self.key(page)]?.asking != true else { return }
        await begin(page, in: session)?.value
    }

    /// The tab's part asked afresh, where the role allows it — and nothing of another tab's.
    private func begin(_ page: Tending, in session: ShellSession) -> Task<Void, Never>? {
        let host = page.host
        let key = Self.key(page)
        let allowed = Self.parts(of: page, in: session)
        guard !allowed.isEmpty, ShellTending.drawn(page, in: session), let through = door(at: host, in: session) else { return nil }
        let under = ShellPersonPages.signIns(at: host, in: session)
        if pages[key]?.under != under {
            asks[key]?.cancel()
            pages[key] = Page(under: under)
        }
        let errand = errands.next()
        pages[key]?.awaits = errand
        pages[key]?.asking = true
        pages[key]?.notAllowed = []
        halted.remove(key)
        let days = pages[key]?.days ?? TendingServerSaid.spans[0]
        let measuresErrand = errand
        if allowed.contains(.measures) { pages[key]?.measuresErrand = measuresErrand }
        let task = Task {
            defer { if self.pages[key]?.awaits == errand { self.asks[key] = nil } }
            await withTaskGroup(of: Void.self) { group in
                if allowed.contains(.measures), let dashboard = self.dashboard(at: host, in: session) {
                    group.addTask {
                        await self.readMeasures(days, at: host, through: through, dashboard: dashboard, errand: measuresErrand, in: session)
                    }
                }
                if allowed.contains(.rising) {
                    for kind in RisingKind.allCases {
                        group.addTask { await self.read(kind, at: host, from: 0, through: through, errand: errand, in: session) }
                    }
                    if let known = self.taxonomies(at: host, in: session) {
                        for list in KnownList.allCases {
                            group.addTask { await self.read(list, at: host, after: nil, through: known, errand: errand, in: session) }
                        }
                    }
                }
                if allowed.contains(.rules) {
                    group.addTask { await self.readRules(at: host, through: through, errand: errand, in: session) }
                }
            }
            if self.pages[key]?.awaits == errand { self.pages[key]?.asking = false }
        }
        asks[key] = task
        return task
    }

    /// Another span chosen: its figures asked — said as asking, and stoppable, as every ask of
    /// the tab is; a span chosen before, landing after, is not drawn.
    func choose(days: Int, on page: Tending, in session: ShellSession) async {
        let host = page.host
        let key = Self.key(host, .measures)
        guard TendingServerSaid.spans.contains(days), keepsStanding(at: host, in: session),
              Self.parts(at: host, in: session).contains(.measures), standing(host, .measures, in: session) != nil,
              let through = door(at: host, in: session), let dashboard = dashboard(at: host, in: session)
        else { return }
        let errand = errands.next()
        pages[key]?.days = days
        pages[key]?.measures = nil
        pages[key]?.breakdowns = nil
        pages[key]?.retention = nil
        pages[key]?.measuresErrand = errand
        pages[key]?.measuresAsking = true
        halted.remove(key)
        spanAsks[key]?.cancel()
        let task = Task {
            await self.readMeasures(days, at: host, through: through, dashboard: dashboard, errand: errand, in: session)
            if self.pages[key]?.measuresErrand == errand {
                self.pages[key]?.measuresAsking = false
                self.spanAsks[key] = nil
            }
        }
        spanAsks[key] = task
        await task.value
    }

    /// The span's figures, and over the same span what the server holds broken down and who
    /// stayed (#418), each asked at once and landing on its own: one not read says so on its
    /// own, and keeps nothing it did not say. A span chosen since lands none of them.
    private func readMeasures(
        _ days: Int, at host: String, through: MastodonAdminServer, dashboard: MastodonAdminDashboard, errand: Int,
        in session: ShellSession
    ) async {
        let now = now()
        async let figures: Void = readFigures(days, now: now, at: host, through: through, errand: errand, in: session)
        async let broken: Void = readBreakdowns(days, now: now, at: host, through: dashboard, errand: errand, in: session)
        async let stayed: Void = readRetention(days, now: now, at: host, through: dashboard, errand: errand, in: session)
        _ = await (figures, broken, stayed)
    }

    private func readFigures(
        _ days: Int, now: Date, at host: String, through: MastodonAdminServer, errand: Int, in session: ShellSession
    ) async {
        let key = Self.key(host, .measures)
        do {
            let said = try await through.measures(days: days, now: now)
            guard pages[key]?.measuresErrand == errand else { return }
            pages[key]?.measures = said
            pages[key]?.measuresFailed = false
        } catch {
            guard pages[key]?.measuresErrand == errand else { return }
            failed(error, .measures, at: host, in: session) { pages[key]?.measuresFailed = true }
        }
    }

    private func readBreakdowns(
        _ days: Int, now: Date, at host: String, through: MastodonAdminDashboard, errand: Int, in session: ShellSession
    ) async {
        let key = Self.key(host, .measures)
        do {
            let said = try await through.breakdowns(TendingServerSaid.breakdownKeys, days: days, now: now)
            guard pages[key]?.measuresErrand == errand else { return }
            pages[key]?.breakdowns = said
            pages[key]?.breakdownsFailed = false
        } catch {
            guard pages[key]?.measuresErrand == errand else { return }
            failed(error, .measures, at: host, in: session) { pages[key]?.breakdownsFailed = true }
        }
    }

    private func readRetention(
        _ days: Int, now: Date, at host: String, through: MastodonAdminDashboard, errand: Int, in session: ShellSession
    ) async {
        let key = Self.key(host, .measures)
        do {
            let said = try await through.retention(months: TendingServerSaid.months(days: days), now: now)
            guard pages[key]?.measuresErrand == errand else { return }
            pages[key]?.retention = said
            pages[key]?.retentionFailed = false
        } catch {
            guard pages[key]?.measuresErrand == errand else { return }
            failed(error, .measures, at: host, in: session) { pages[key]?.retentionFailed = true }
        }
    }

    private func readRules(at host: String, through: MastodonAdminServer, errand: Int, in session: ShellSession) async {
        let key = Self.key(host, .rules)
        do {
            let rules = try await through.rules()
            guard pages[key]?.awaits == errand else { return }
            pages[key]?.rules = rules
            pages[key]?.rulesFailed = false
        } catch {
            guard pages[key]?.awaits == errand else { return }
            failed(error, .rules, at: host, in: session) { pages[key]?.rulesFailed = true }
        }
    }

    /// One list's foot pressed: its next stretch, or again the one that did not come.
    func readOn(_ kind: RisingKind, of page: Tending, in session: ShellSession) async {
        let host = page.host
        let key = Self.key(host, .rising)
        guard keepsStanding(at: host, in: session), Self.parts(at: host, in: session).contains(.rising),
              let held = standing(host, .rising, in: session), !held.asking, let read = held.rising[kind], !read.readingOn,
              let next = read.next ?? (read.failed ? read.rows.count : nil), let through = door(at: host, in: session)
        else { return }
        pages[key]?.rising[kind]?.readingOn = true
        await self.read(kind, at: host, from: next, through: through, errand: held.awaits, in: session)
        pages[key]?.rising[kind]?.readingOn = false
    }

    private func read(
        _ kind: RisingKind, at host: String, from offset: Int, through: MastodonAdminServer, errand: Int, in session: ShellSession
    ) async {
        let key = Self.key(host, .rising)
        do {
            let stretch = try await through.rising(kind, from: offset)
            guard var held = pages[key], held.awaits == errand else { return }
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
            pages[key] = held
        } catch {
            guard pages[key]?.awaits == errand else { return }
            failed(error, .rising, at: host, in: session) {
                if pages[key]?.rising[kind] == nil { pages[key]?.rising[kind] = Read() }
                pages[key]?.rising[kind]?.failed = true
            }
        }
    }

    private func failed(_ error: any Error, _ part: ServerPart, at host: String, in session: ShellSession, _ mark: () -> Void) {
        switch error {
        case MastodonAdminError.notAllowed: pages[Self.key(host, part)]?.notAllowed.insert(part)
        case MastodonAuthError.signedOut:
            session.mastodon.endedByServer(host: host)
            mark()
        default:
            if !Cancellation.happened(error) { mark() }
        }
    }

    // MARK: - What the server knows (#419)

    /// One of the two lists' foot pressed: its next stretch, or again the one that did not come.
    func readOnKnown(_ list: KnownList, of page: Tending, in session: ShellSession) async {
        let host = page.host
        let key = Self.key(host, .rising)
        guard keepsStanding(at: host, in: session), Self.parts(at: host, in: session).contains(.rising),
              let held = standing(host, .rising, in: session), !held.asking, let through = taxonomies(at: host, in: session)
        else { return }
        let next: String?
        switch list {
        case .tags: next = held.tags.readingOn || !held.tags.answered ? nil : held.tags.next
        case .sites: next = held.sites.readingOn || !held.sites.answered ? nil : held.sites.next
        }
        guard let next else { return }
        setReadingOn(list, at: key, true)
        await read(list, at: host, after: next, through: through, errand: held.awaits, in: session)
        setReadingOn(list, at: key, false)
    }

    private func setReadingOn(_ list: KnownList, at key: String, _ on: Bool) {
        switch list {
        case .tags: pages[key]?.tags.readingOn = on
        case .sites: pages[key]?.sites.readingOn = on
        }
    }

    private func read(
        _ list: KnownList, at host: String, after next: String?, through: MastodonAdminTaxonomies, errand: Int, in session: ShellSession
    ) async {
        let key = Self.key(host, .rising)
        do {
            switch list {
            case .tags: land(try await through.tags(after: next), into: \.tags, list, at: key, after: next, errand: errand)
            case .sites: land(try await through.sites(after: next), into: \.sites, list, at: key, after: next, errand: errand)
            }
        } catch {
            guard pages[key]?.awaits == errand else { return }
            failed(error, .rising, at: host, in: session) {
                switch list {
                case .tags: pages[key]?.tags.failed = true
                case .sites: pages[key]?.sites.failed = true
                }
            }
        }
    }

    /// A stretch landed, **under the rule every change keeps**: a row a change answered for after
    /// this read set out stands as the change left it.
    private func land<Item: Identifiable & Equatable>(
        _ stretch: FederationStretch<Item>, into path: WritableKeyPath<Page, Known<Item>>, _ list: KnownList, at key: String,
        after next: String?, errand: Int
    ) where Item.ID == String {
        guard var held = pages[key], held.awaits == errand else { return }
        var read = held[keyPath: path]
        let current = Dictionary(read.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let landed = stretch.items.map { item in
            (held.acted[TendingServerSaid.knownID(list, item.id)] ?? 0) > errand ? current[item.id] ?? item : item
        }
        var rows = next == nil ? [] : read.rows
        var seen = Set(rows.map(\.id))
        rows += landed.filter { seen.insert($0.id).inserted }
        read.rows = rows
        read.next = stretch.next
        read.answered = true
        read.failed = false
        held[keyPath: path] = read
        held.notAllowed.remove(.rising)
        pages[key] = held
    }

    /// A hashtag the server knows let rise or kept back, let be used or not: sent once — a
    /// press while it is on the wire sends nothing — and its row the server's answer. Every way
    /// it does not send, and every refusal, is said; nothing here changes by a failure.
    func change(_ tag: AdminTag, _ change: TendingServerSaid.TagChange, on page: Tending, in session: ShellSession) async {
        let failure = await act(.tags, tag.id, on: page, in: session) { through in
            let answered = switch change {
            case .rises(let rises): try await through.changeTag(tag.id, rises: rises)
            case .usable(let usable): try await through.changeTag(tag.id, usable: usable)
            }
            return { (held: inout Page) in
                if let index = held.tags.rows.firstIndex(where: { $0.id == tag.id }) { held.tags.rows[index] = answered }
            }
        }
        if let failure { session.showToast(failure) }
    }

    /// A site let rise — or kept back, and every link from it with it — as `change` is sent.
    func review(_ site: LinkSite, rise: Bool, on page: Tending, in session: ShellSession) async {
        let failure = await act(.sites, site.id, on: page, in: session) { through in
            let answered = try await through.reviewSite(site.id, rise: rise)
            return { (held: inout Page) in
                if let index = held.sites.rows.firstIndex(where: { $0.id == site.id }) { held.sites.rows[index] = answered }
            }
        }
        if let failure { session.showToast(failure) }
    }

    private func act(
        _ list: KnownList, _ id: String, on page: Tending, in session: ShellSession,
        _ send: (MastodonAdminTaxonomies) async throws -> (inout Page) -> Void
    ) async -> String? {
        let host = page.host
        let key = TendingServerSaid.knownID(list, id)
        let at = Self.key(host, .rising)
        let notAllowed = String(format: L10n.t("tend.act.notAllowed"), host)
        guard keepsStanding(at: host, in: session), Self.parts(at: host, in: session).contains(.rising),
              ShellTending.acts(at: host, in: session)
        else { return notAllowed }
        guard let held = standing(host, .rising, in: session) else { return String(format: L10n.t("tend.act.failed"), host) }
        guard !held.acting.contains(key) else { return nil }
        guard let through = taxonomies(at: host, in: session) else { return String(format: L10n.t("tend.act.failed"), host) }
        let under = held.under
        pages[at]?.acting.insert(key)
        defer { if pages[at]?.under == under { pages[at]?.acting.remove(key) } }
        do {
            let apply = try await send(through)
            // **Numbered as it answers**: a read sent while this was on the wire does not undo it.
            let errand = errands.next()
            guard pages[at]?.under == under, var now = pages[at] else { return nil }
            now.acted[key] = errand
            apply(&now)
            pages[at] = now
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
        let at = Self.key(host, .rising)
        let notAllowed = String(format: L10n.t("tend.act.notAllowed"), host)
        guard keepsStanding(at: host, in: session), Self.parts(at: host, in: session).contains(.rising),
              ShellTending.acts(at: host, in: session)
        else { return notAllowed }
        guard let held = standing(host, .rising, in: session) else { return String(format: L10n.t("tend.act.failed"), host) }
        guard !held.acting.contains(key) else { return nil }
        guard let through = door(at: host, in: session) else { return String(format: L10n.t("tend.act.failed"), host) }
        let under = held.under
        pages[at]?.acting.insert(key)
        defer { if pages[at]?.under == under { pages[at]?.acting.remove(key) } }
        do {
            let answered = try await through.review(kind, item.id, rise: rise)
            // **Numbered as it answers**: a read sent while this was on the wire does not undo it.
            let errand = errands.next()
            guard pages[at]?.under == under else { return nil }
            pages[at]?.acted[key] = errand
            if let index = pages[at]?.rising[kind]?.rows.firstIndex(where: { $0.id == item.id }) {
                pages[at]?.rising[kind]?.rows[index] = answered
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
        for part in ServerPart.allCases {
            let key = Self.key(host, part)
            asks[key]?.cancel()
            asks[key] = nil
            spanAsks[key]?.cancel()
            spanAsks[key] = nil
            pages[key] = nil
            halted.remove(key)
        }
    }
}
