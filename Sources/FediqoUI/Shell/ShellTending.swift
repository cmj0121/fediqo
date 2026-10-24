import FediqoCore
import Foundation
import Observation

// Tending a Mastodon the reader answers for (#380), and — for #381 — what was reported to it:
// who may, what is asked, when, and what the page holds of the answers.
//
// **The standing draws it, and only the standing.** A source's `…` offers "Tend <host>" only
// where the server's role for the account signed in there allows some task of tending
// (`MastodonStaff`, read off its own account check this run), and the page has a tab only for a
// task the role allows. An account without the standing sees no trace of it, whatever its
// sign-in holds. **The words are asked apart**: where the role allows it and the sign-in does
// not hold tending's words, the item is that part's lock, which asks for them alone (D9).
// Holding only the word that reads, the page lists and offers no act.
//
// **Asked as the page opens, and read on at its foot.** What was reported is asked for open
// ones first, newest first, a stretch at a time by the server's own next; reaching the end of
// the open ones goes on to the closed, until the server names no next — so reading on reaches
// every report it keeps. Reaching the foot reads on by itself only after a stretch that came;
// after a failure, or a reading-on stopped, the foot waits for a press. `r`, the mark and a
// pull ask from the top; Stop calls off what is on the wire.
//
// **Every act is the server's, and its answer is the row.** Taking a report on, handing it
// back, closing and opening it again are each sent once and the row is replaced by the report
// as the server answers; **a read that left before an act lands after it without undoing it**:
// each row remembers the number of the act that last answered for it, and a stretch asked
// before that keeps the act's row. A refusal says the server's words, or that the role does not
// allow it, and changes nothing. What this app does not carry — a note, an act on the account —
// is the report's own page on the server, one press away.
//
// **Held nowhere.** What a server says to those who answer for it stays in memory for the run,
// is let go with its reader (`PageReaders`), and none of its posts becomes an item.

/// An act on a report, as the page offers it: the server's own (`MastodonAdminReports.Act`).
typealias ReportAct = MastodonAdminReports.Act

/// A tab of the page of tending, each the task a flag of the role allows. Later tasks of #380
/// add their own tab and flag here.
enum TendingTab: String, ShellTab, Sendable, CaseIterable {
    case reports
    /// Who asks to join, and the server's accounts (#382).
    case people
    /// The servers it refuses or allows, and the addresses it refuses (#383).
    case servers
    /// How it is doing, what waits to rise on it, and its rules (#384).
    case server

    var id: String { rawValue }
    var titleKey: String { "tend.tab.\(rawValue)" }

    var symbol: String {
        switch self {
        case .reports: "exclamationmark.bubble"
        case .people: "person.badge.clock"
        case .servers: "network"
        case .server: "chart.bar"
        }
    }

    /// The flags of the role this tab's task needs, any one of which opens it: the Servers tab
    /// holds the servers' lists and the addresses', each its own flag's.
    var flags: [MastodonStaff] {
        switch self {
        case .reports: [.manageReports]
        case .people: [.manageUsers]
        case .servers: [.manageFederation, .manageBlocks]
        case .server: [.viewDashboard, .manageTaxonomies, .manageRules]
        }
    }

    /// The tabs a standing allows, in the order they stand: none for no standing.
    static func allowed(by staff: MastodonStaff?) -> [TendingTab] {
        guard let staff else { return [] }
        return allCases.filter { $0.flags.contains(where: staff.allows) }
    }
}

/// The page of tending one server, on one of its tabs: a step of the walk (`ShellStep.server`).
struct Tending: Hashable, Sendable, Identifiable {
    let host: String
    var tab: TendingTab

    var id: String { host }
}

/// What the Reports tab is handed.
struct TendingReportsSaid: Equatable {
    let host: String
    var reports: [AdminReport] = []
    /// Whether the sign-in may act on them: it holds tending's word that changes.
    var acts = false
    /// Which reports have an act on the wire: their `…` asks nothing more meanwhile.
    var acting: Set<String> = []
    /// What stands where rows would, and nothing where there are rows or nothing has answered.
    var quiet: String?
    var foot: PersonSaid.Foot?
    /// Where the sign-in may not act: tending's lock — the half that changes, asked for alone.
    var lock: PartWords.Place?

    /// What the foot says: reports, not posts, and whose.
    static func footWords(_ foot: PersonSaid.Foot, host: String, language: DummyLanguage? = nil) -> String {
        switch foot {
        case .more: L10n.t("tend.foot.more", language: language)
        case .end: String(format: L10n.t("tend.foot.end", language: language), host)
        case .stopped: String(format: L10n.t("person.foot.stopped", language: language), host)
        }
    }

    /// The row id of a report, as the lamp and the keys know it.
    static func rowID(_ id: String) -> String { "report\u{1e}\(id)" }
}

/// Every server's page of tending opened this run, by host.
///
/// Held by `ShellPersonPages`, on its count of asks, and let go with the same reader.
@MainActor
@Observable
final class ShellTending {
    /// Where the next stretch is read from: the open ones, then the closed.
    private enum Cursor: Equatable {
        case open(after: String?)
        case closed(after: String?)

        var resolved: Bool { if case .closed = self { true } else { false } }
        var after: String? {
            switch self {
            case .open(let after), .closed(let after): after
            }
        }
    }

    private struct Reports {
        var rows: [AdminReport] = []
        /// Where the next stretch is read from, or nothing where the server named no more.
        var cursor: Cursor? = .open(after: nil)
        var answered = false
        var asking = false
        var readingOn = false
        var failed = false
        /// The server refused this account's standing (403): said, and nothing listed.
        var notAllowed = false
        var notPaging = false
        /// A reading-on was stopped: the foot waits for a press.
        var held = false
        /// The number of the ask whose answer is awaited.
        var awaits = 0
        /// The number of the act that last answered for each report.
        var acted: [String: Int] = [:]
        /// Reports with an act on the wire.
        var acting: Set<String> = []
        /// How often the sign-in at its host had become another when it was asked: a page asked
        /// as one reader is never drawn for the next (`ShellPersonPages.signIns`).
        var under = 0

        var readsOn: Bool { answered && !asking && !readingOn && !notPaging && (cursor != nil || failed) }
        var reachesOn: Bool { readsOn && !failed && !held && cursor != nil }
    }

    private var pages: [String: Reports] = [:]
    private var halted: Set<String> = []
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to a server's reports, where a test reaches it by one. Nothing in the app.
    @ObservationIgnored var reaching: ((MastodonAuthorized) -> MastodonAdminReports)?

    /// The People tab's own state (#382), apart from the reports'.
    let people: ShellTendingPeople
    /// The Servers tab's own state (#383).
    let servers: ShellTendingServers
    /// The Server tab's own state (#384).
    let server: ShellTendingServer

    init(errands: PageErrands) {
        self.errands = errands
        people = ShellTendingPeople(errands: errands)
        servers = ShellTendingServers(errands: errands)
        server = ShellTendingServer(errands: errands)
    }

    // MARK: - Who may

    /// The tabs of tending `host` for whoever is signed in there now: those the role its own
    /// check said allows — **none where it said no role, or has not said**, and none for a
    /// source that is no Mastodon's people.
    static func tabs(at host: String, in session: ShellSession) -> [TendingTab] {
        guard ShellPersonPages.source(at: host, in: session) != nil, session.mastodon.isSignedIn(host: host) else { return [] }
        return TendingTab.allowed(by: session.mastodon.staff(host: host))
    }

    /// What a source's `…` offers for tending it: nothing without the standing; where the
    /// sign-in holds tending's word that reads, the page; and otherwise the part's lock, which
    /// asks for it alone.
    enum Entry: Equatable {
        case open(Tending)
        case lock(PartWords.Place)
    }

    static func entry(at host: String, in session: ShellSession) -> Entry? {
        guard let first = tabs(at: host, in: session).first else { return nil }
        let held = session.mastodon.heldParts[host.lowercased()]?.scopes
        if MastodonParts.holds(.seeing, of: .tending, in: held) {
            return .open(Tending(host: host.lowercased(), tab: first))
        }
        return session.mastodon.place(.tending, host: host).map(Entry.lock)
    }

    /// The report's own page on the server, where a note is written and the account acted on.
    static func page(of report: AdminReport, host: String) -> URL? {
        MastodonAdminReports.page(of: report.id, host: host)
    }

    /// Whether the sign-in at `host` may act for the server: it holds tending's word that changes.
    static func acts(at host: String, in session: ShellSession) -> Bool {
        MastodonParts.holds(.changing, of: .tending, in: session.mastodon.heldParts[host.lowercased()]?.scopes)
    }

    /// Whether the page `page` may be drawn: its tab is one the standing allows, and its words held.
    static func drawn(_ page: Tending, in session: ShellSession) -> Bool {
        guard case .open = entry(at: page.host, in: session) else { return false }
        return tabs(at: page.host, in: session).contains(page.tab)
    }

    // MARK: - What the page is handed

    /// The page of `host` as it stands for whoever is signed in there now, or nothing.
    private func standing(_ host: String, in session: ShellSession) -> Reports? {
        pages[host].flatMap { $0.under == ShellPersonPages.signIns(at: host, in: session) ? $0 : nil }
    }

    /// Which opening a page is, as its pane's task is named: the host, and how often the sign-in
    /// there has become another — so a page in front whose reader changes is asked afresh.
    func opening(_ page: Tending, in session: ShellSession) -> ShellPersonPages.Opening {
        ShellPersonPages.Opening(
            id: page.host + "\u{1e}" + page.tab.rawValue, askedAs: ShellPersonPages.askedAs(at: page.host, in: session),
            under: ShellPersonPages.signIns(at: page.host, in: session)
        )
    }

    func said(of page: Tending, in session: ShellSession, language: DummyLanguage? = nil) -> TendingReportsSaid {
        let host = page.host
        let acts = Self.acts(at: host, in: session)
        guard let reports = standing(host, in: session) else {
            return TendingReportsSaid(host: host, acts: acts, lock: acts ? nil : session.mastodon.place(.tending, host: host))
        }
        var said = TendingReportsSaid(host: host, reports: reports.rows, acts: acts, acting: reports.acting)
        if !acts { said.lock = session.mastodon.place(.tending, host: host) }
        if reports.notAllowed {
            said.quiet = String(format: L10n.t("tend.act.notAllowed", language: language), host)
        } else if reports.answered, reports.rows.isEmpty, reports.cursor == nil {
            said.quiet = String(format: L10n.t("tend.reports.none", language: language), host)
        }
        said.foot = Self.foot(of: reports)
        return said
    }

    private static func foot(of reports: Reports) -> PersonSaid.Foot? {
        guard reports.answered, !reports.asking, !reports.readingOn, !reports.notAllowed else { return nil }
        if reports.readsOn { return .more }
        if reports.notPaging { return .stopped }
        return reports.rows.isEmpty ? nil : .end
    }

    /// The rows `j` and `k` walk, top to bottom.
    func walked(_ page: Tending, in session: ShellSession) -> [String] {
        switch page.tab {
        case .reports: (standing(page.host, in: session)?.rows ?? []).map { TendingReportsSaid.rowID($0.id) }
        case .people: people.walked(page, in: session)
        case .servers: servers.walked(page, in: session)
        case .server: server.walked(page, in: session)
        }
    }

    /// The head's figures (#382): for each tab the standing allows, how many it holds as far as
    /// it has been read — the open reports, and those waiting to be let in. Nothing for a tab not
    /// yet asked.
    func counts(of page: Tending, in session: ShellSession) -> [TendingCount] {
        Self.tabs(at: page.host, in: session).compactMap { tab in
            let said: (count: Int, more: Bool)? = switch tab {
            case .reports: openReports(at: page.host, in: session)
            case .people: people.waiting(at: page.host, in: session)
            case .servers, .server: nil
            }
            return said.map { TendingCount(tab: tab, count: $0.count, more: $0.more) }
        }
    }

    /// What the head's figures are asked from, as the page opens, whichever tab is in front: the
    /// reports' first stretch, and one stretch of those waiting.
    func headOpened(_ page: Tending, in session: ShellSession) async {
        async let reports: Void = reportsOpened(page, in: session)
        async let waiting: Void = people.countWaiting(page, in: session)
        _ = await (reports, waiting)
    }

    /// How many reports stand open at `host`, as far as the Reports tab has read — and whether
    /// open ones remain unread. Nothing before it has answered.
    func openReports(at host: String, in session: ShellSession) -> (count: Int, more: Bool)? {
        guard let reports = standing(host, in: session), reports.answered else { return nil }
        let more = if case .open(let after) = reports.cursor { after != nil } else { false }
        return (reports.rows.filter { !$0.closed }.count, more)
    }

    /// The report a row id names, where the page holds it.
    func report(_ rowID: String, of page: Tending, in session: ShellSession) -> AdminReport? {
        standing(page.host, in: session)?.rows.first { TendingReportsSaid.rowID($0.id) == rowID }
    }

    func canAskAgain(_ page: Tending, in session: ShellSession) -> Bool {
        Self.drawn(page, in: session)
    }

    func ask(of page: Tending, language: DummyLanguage? = nil) -> PageAsking {
        if page.tab == .people { return people.ask(of: page, language: language) }
        if page.tab == .servers { return servers.ask(of: page, language: language) }
        if page.tab == .server { return server.ask(of: page, language: language) }
        guard let reports = pages[page.host] else { return PageAsking() }
        return PageAsking(
            asking: reports.asking
                ? String(format: L10n.t("tend.asking", language: language), page.host)
                : reports.readingOn ? L10n.t("person.foot.reading", language: language) : nil,
            stoppable: reports.asking || reports.readingOn,
            failed: reports.failed && !reports.asking && !reports.readingOn ? [page.host] : [],
            stopped: halted.contains(page.host)
        )
    }

    @discardableResult
    func stop(_ page: Tending) -> Bool {
        if page.tab == .people { return people.stop(page) }
        if page.tab == .servers { return servers.stop(page) }
        if page.tab == .server { return server.stop(page) }
        let host = page.host
        guard let reports = pages[host], reports.asking || reports.readingOn else { return false }
        asks[host]?.cancel()
        asks[host] = nil
        pages[host]?.awaits = errands.next()
        if reports.readingOn { pages[host]?.held = true }
        pages[host]?.asking = false
        pages[host]?.readingOn = false
        halted.insert(host)
        return true
    }

    // MARK: - Asking

    /// The page opening: its reports asked from the top, once a run; opened again it is drawn
    /// from what was held, and an ask on the wire is waited on.
    func opened(_ page: Tending, in session: ShellSession) async {
        switch page.tab {
        case .reports: await reportsOpened(page, in: session)
        case .people: await people.opened(page, in: session)
        case .servers: await servers.opened(page, in: session)
        case .server: await server.opened(page, in: session)
        }
    }

    /// The Reports tab asked from the top, once a run — wherever the page stands: its count is
    /// the head's on every tab.
    func reportsOpened(_ page: Tending, in session: ShellSession) async {
        guard Self.tabs(at: page.host, in: session).contains(.reports) else { return }
        if let reports = standing(page.host, in: session) {
            if reports.asking || reports.readingOn {
                await asks[page.host]?.value
                return
            }
            if reports.answered || reports.notAllowed { return }
        }
        await begin(page, fromTop: true, in: session)?.value
    }

    /// `r`, the mark and a pull: asked from the top again. A press while it is asked asks nothing.
    func again(_ page: Tending, in session: ShellSession) async {
        if page.tab == .people { return await people.again(page, in: session) }
        if page.tab == .servers { return await servers.again(page, in: session) }
        if page.tab == .server { return await server.again(page, in: session) }
        if pages[page.host]?.asking == true { return }
        await begin(page, fromTop: true, in: session)?.value
    }

    /// The foot pressed — `pressed` — or reached: the next stretch; pressed, again the one that
    /// did not come or was stopped. Reached, only after a stretch that came.
    func readOn(_ page: Tending, pressed: Bool, in session: ShellSession) async {
        if page.tab == .people { return await people.readOn(page, pressed: pressed, in: session) }
        // The Servers and Server tabs' lists read on each by its own foot, pressed (`readOn`).
        if page.tab == .servers || page.tab == .server { return }
        guard let reports = standing(page.host, in: session), pressed ? reports.readsOn : reports.reachesOn else { return }
        pages[page.host]?.held = false
        await begin(page, fromTop: false, in: session)?.value
    }

    private func door(at host: String, in session: ShellSession) -> MastodonAdminReports? {
        guard let door = session.mastodon.authorized(host: host, within: deadline, for: .tending) else { return nil }
        return reaching?(door) ?? MastodonAdminReports(door: door)
    }

    private func begin(_ page: Tending, fromTop: Bool, in session: ShellSession) -> Task<Void, Never>? {
        let host = page.host
        guard Self.drawn(page, in: session), let through = door(at: host, in: session) else { return nil }
        let under = ShellPersonPages.signIns(at: host, in: session)
        if pages[host]?.under != under {
            // Asked as another reader: what was said to the one before is not this one's.
            asks[host]?.cancel()
            pages[host] = Reports(under: under)
        }
        let cursor: Cursor = fromTop ? .open(after: nil) : (pages[host]?.cursor ?? .open(after: nil))
        let errand = errands.next()
        pages[host]?.awaits = errand
        if fromTop {
            pages[host]?.asking = true
            pages[host]?.readingOn = false
            pages[host]?.held = false
        } else {
            pages[host]?.readingOn = true
        }
        pages[host]?.failed = false
        halted.remove(host)
        let task = Task { await self.read(host, at: cursor, fromTop: fromTop, through: through, errand: errand, in: session) }
        asks[host] = task
        return task
    }

    private func read(
        _ host: String, at cursor: Cursor, fromTop: Bool, through: MastodonAdminReports, errand: Int, in session: ShellSession
    ) async {
        defer { if pages[host]?.awaits == errand { asks[host] = nil } }
        do {
            let stretch = try await through.stretch(resolved: cursor.resolved, after: cursor.after)
            guard pages[host]?.awaits == errand, let held = pages[host] else { return }
            // What an act answered after this stretch set out stands over what the stretch says.
            let current = Dictionary(held.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let landed = stretch.reports.map { report in
                (held.acted[report.id] ?? 0) > errand ? current[report.id] ?? report : report
            }
            var rows = fromTop ? [] : held.rows
            var seen = Set(rows.map(\.id))
            rows += landed.filter { seen.insert($0.id).inserted }
            pages[host]?.rows = rows
            pages[host]?.cursor = stretch.next.map { cursor.resolved ? .closed(after: $0) : .open(after: $0) }
                ?? (cursor.resolved ? nil : .closed(after: nil))
            pages[host]?.answered = true
            pages[host]?.notAllowed = false
            pages[host]?.notPaging = false
        } catch {
            guard pages[host]?.awaits == errand else { return }
            switch error {
            case MastodonAdminError.notAllowed:
                pages[host]?.notAllowed = true
            case is PagingError:
                pages[host]?.notPaging = true
            case MastodonAuthError.signedOut:
                session.mastodon.endedByServer(host: host)
                pages[host]?.failed = true
            default:
                if !Cancellation.happened(error) { pages[host]?.failed = true }
            }
        }
        pages[host]?.asking = false
        pages[host]?.readingOn = false
    }

    /// `act` done to the report `id` on `page`'s server, as the reader: sent once, and its row
    /// replaced by the report as the server answers. A press while that report's act is on the
    /// wire sends nothing. A refusal or a failure says so, and changes nothing here.
    func act(_ act: MastodonAdminReports.Act, on id: String, of page: Tending, in session: ShellSession) async {
        let host = page.host
        guard Self.drawn(page, in: session), Self.acts(at: host, in: session), pages[host]?.acting.contains(id) == false,
              let through = door(at: host, in: session)
        else { return }
        // The page this act was pressed on: its answer is written there and nowhere else — not
        // into a page asked afresh as another reader while it was on the wire.
        let under = pages[host]?.under
        pages[host]?.acting.insert(id)
        defer { if pages[host]?.under == under { pages[host]?.acting.remove(id) } }
        do {
            let report = try await through.act(act, on: id)
            // **Numbered as it answers, not as it set out**: a read sent while the act was on the
            // wire was answered before it, and must not undo it when it lands after.
            let errand = errands.next()
            guard pages[host]?.under == under, let index = pages[host]?.rows.firstIndex(where: { $0.id == id }) else { return }
            pages[host]?.rows[index] = report
            pages[host]?.acted[id] = errand
        } catch MastodonAdminError.notAllowed {
            session.showToast(String(format: L10n.t("tend.act.notAllowed"), host))
        } catch MastodonAdminError.refused(let sentence) {
            session.showToast(String(format: L10n.t("tend.act.refused"), host, sentence))
        } catch MastodonAuthError.signedOut {
            session.mastodon.endedByServer(host: host)
        } catch {
            if !Cancellation.happened(error) { session.showToast(String(format: L10n.t("tend.act.failed"), host)) }
        }
    }

    /// The report `id` lit on `page` — a notice of it pressed (#381) — made one of the page's
    /// rows: once the page has answered, the report itself is asked for where the page does not
    /// hold it, and stands at the top. Where the server gives it nobody, that is said.
    func bringIn(_ id: String, of page: Tending, in session: ShellSession) async {
        await reportsOpened(page, in: session)
        let host = page.host
        guard let reports = standing(host, in: session), reports.answered, !reports.rows.contains(where: { $0.id == id }),
              let through = door(at: host, in: session)
        else { return }
        let under = reports.under
        do {
            let report = try await through.report(id)
            let errand = errands.next()
            guard pages[host]?.under == under, pages[host]?.rows.contains(where: { $0.id == id }) == false else { return }
            pages[host]?.rows.insert(report, at: 0)
            pages[host]?.acted[id] = errand
        } catch {
            guard !Cancellation.happened(error), pages[host]?.under == under else { return }
            switch error {
            // Only the server saying it has no such report is that it did not give it.
            case MastodonAuthError.http(404): session.showToast(String(format: L10n.t("tend.reports.unlisted"), host))
            case MastodonAdminError.notAllowed: session.showToast(String(format: L10n.t("tend.act.notAllowed"), host))
            case MastodonAuthError.signedOut: session.mastodon.endedByServer(host: host)
            default: session.showToast(String(format: L10n.t("tend.act.failed"), host))
            }
        }
    }

    // MARK: - Tabs

    /// Tab on the page in front: the next tab its standing allows, round their ring, turned in
    /// place as a tab of what a search found is. Taken, turning nothing, where it has one.
    func rotate(_ walk: inout ShellWalk, by step: Int, covered: Bool, lamp: inout String?, in session: ShellSession) -> Bool {
        guard !covered, let page = walk.openedTending else { return false }
        let tabs = Self.tabs(at: page.host, in: session)
        guard tabs.count > 1, let at = tabs.firstIndex(of: page.tab) else { return true }
        return turn(&walk, to: tabs[(at + step + tabs.count) % tabs.count], lamp: &lamp, in: session)
    }

    /// A tab of the page in front pressed or swiped to: the step turned in place, no step more.
    @discardableResult
    func turn(_ walk: inout ShellWalk, to tab: TendingTab, lamp: inout String?, in session: ShellSession) -> Bool {
        guard var page = walk.openedTending, page.tab != tab, Self.tabs(at: page.host, in: session).contains(tab) else { return false }
        page.tab = tab
        guard walk.turned(to: .server(page)) else { return false }
        lamp = nil
        return true
    }

    /// What was asked of `host` let go, and its ask called off: who reads it changed.
    func letGo(at host: String) {
        let host = host.lowercased()
        asks[host]?.cancel()
        asks[host] = nil
        pages[host] = nil
        halted.remove(host)
        people.letGo(at: host)
        servers.letGo(at: host)
        server.letGo(at: host)
    }
}
