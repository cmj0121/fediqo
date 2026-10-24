import FediqoCore
import Foundation
import Observation

// The People tab of tending a server (#382): who asks to join, let in or turned away; the
// server's accounts found by name, address or state; each acted on — warned, limited, marked
// sensitive, frozen or suspended, with the words the server sends — and each taken back; and
// what only staff see of somebody, on their own page's About.
//
// **The tab's own state, apart from the Reports tab's** (`ShellTending` holds one of each). It
// is asked as the tab comes in front, by the state it is set to — those waiting, first — read on
// at its foot by the server's own next, only after a stretch that came; `r`, the mark and a
// pull ask from the top; Stop calls off what is on the wire.
//
// **Every act is the server's, and its answer is the row**, by the rules the Reports tab keeps:
// an act is numbered as it answers, so a read sent while it was on the wire never undoes it,
// and its answer is written only into the page it was pressed on — never into one asked afresh
// as another reader meanwhile. An act on an account answers with nothing, so the account is read
// again, and that is the row. **What takes something away asks first**: turning somebody away —
// the server deletes them, and it cannot be taken back — and suspending, on the sheet. **A
// warning cannot be taken back, and the sheet says so in one line before it is sent.** A refusal
// says the server's words, or that the standing does not allow it, and changes nothing here.
//
// **Held nowhere.** In memory for the run, let go with its reader.

/// What the People tab is handed.
struct TendingPeopleSaid: Equatable {
    let host: String
    var filter = AdminAccountFilter()
    var accounts: [AdminAccount] = []
    /// Whether the sign-in may act: it holds tending's word that changes.
    var acts = false
    /// Whether the role lets accounts be let in, turned away and have acts taken back.
    var manages = false
    /// Accounts with an act on the wire.
    var acting: Set<String> = []
    var quiet: String?
    var foot: PersonSaid.Foot?
    /// Where the sign-in may not act: tending's lock.
    var lock: PartWords.Place?

    /// The row id of an account, as the lamp and the keys know it.
    static func rowID(_ id: String) -> String { "account\u{1e}\(id)" }

    static func footWords(_ foot: PersonSaid.Foot, host: String, language: DummyLanguage? = nil) -> String {
        switch foot {
        case .more: L10n.t("tend.people.foot.more", language: language)
        case .end: String(format: L10n.t("tend.people.foot.end", language: language), host)
        case .stopped: String(format: L10n.t("person.foot.stopped", language: language), host)
        }
    }
}

/// What only those who answer for a server see of somebody, on their page's About (#382).
struct TendingStaffSaid: Equatable {
    let host: String
    let account: AdminAccount
    /// Whether an act on them may be opened from here: the role allows it and the words are held.
    var acts = false
}

extension TendingStaffSaid {
    /// Its lines, each as About draws it beside the staff's mark.
    static func lines(_ staff: TendingStaffSaid, language: DummyLanguage? = nil) -> [String] {
        let account = staff.account
        let states = TendingPeopleSaid.states(account, language: language)
        return [
            String(format: L10n.t("tend.staff.title", language: language), staff.host),
            account.at.map { String(format: L10n.t("tend.staff.since", language: language), $0.formatted(date: .abbreviated, time: .omitted)) },
            account.email.map { String(format: L10n.t("tend.staff.email", language: language), $0) },
            account.ip.map { String(format: L10n.t("tend.staff.ip", language: language), $0) },
            states.isEmpty ? nil : states.joined(separator: " · "),
            account.reason.isEmpty ? nil : String(format: L10n.t("tend.people.wrote", language: language), account.reason),
        ].compactMap { $0 }
    }
}

/// An act on an account being written on its sheet (#382).
struct AccountActAsk: Equatable, Identifiable {
    enum Stage: Equatable {
        case writing
        /// Suspending asks once more, in so many words, before it is sent.
        case asking
        case sending
        case failed(String)
    }

    let host: String
    let accountID: String
    /// Whom it is about, as a line of ours.
    let handle: String
    /// The report it answers, where it is opened from one.
    let report: String?
    /// The acts the sheet offers: freezing only of somebody of this server, for a role that
    /// manages accounts (#382).
    var offered: [AccountAct] = AccountAct.allCases
    var act: AccountAct = .warn
    var words = ""
    var tell = true
    var stage = Stage.writing

    var id: String { host + "\u{1e}" + accountID }

    /// How long the words the server sends may be: what it takes for a report's.
    static let wordsLength = MastodonReports.wordsLength
}

@MainActor
@Observable
final class ShellTendingPeople {
    private struct People {
        var filter = AdminAccountFilter()
        var rows: [AdminAccount] = []
        var next: String?
        var answered = false
        var asking = false
        var readingOn = false
        var failed = false
        var notAllowed = false
        var notPaging = false
        var held = false
        var awaits = 0
        var acted: [String: Int] = [:]
        var acting: Set<String> = []
        var under = 0

        var readsOn: Bool { answered && !asking && !readingOn && !notPaging && (next != nil || failed) }
        var reachesOn: Bool { readsOn && !failed && !held && next != nil }
    }

    private var pages: [String: People] = [:]
    private var halted: Set<String> = []
    /// What only staff see of somebody, by host and the id their server gives them, and who it
    /// was asked as.
    private var staffSeen: [String: (under: Int, account: AdminAccount)] = [:]
    /// The sheet an act on an account is written on, where one is up.
    var asking: AccountActAsk?
    /// How many wait to be let in at each host, as one stretch of them said: the count, and
    /// whether the server named more.
    private(set) var waitingCounts: [String: (count: Int, more: Bool, under: Int)] = [:]
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to a server's accounts, where a test reaches it by one. Nothing in the app.
    @ObservationIgnored var reaching: ((MastodonAuthorized) -> MastodonAdminAccounts)?

    init(errands: PageErrands) {
        self.errands = errands
    }

    // MARK: - Who may

    /// Whether the role lets accounts be let in, turned away and have acts taken back.
    static func manages(at host: String, in session: ShellSession) -> Bool {
        session.mastodon.staff(host: host)?.allows(.manageUsers) == true
    }

    /// Whether an account at `host` may be acted on — the role lets users or reports be managed,
    /// and the sign-in holds tending's word that changes.
    static func actsOn(at host: String, in session: ShellSession) -> Bool {
        guard let staff = session.mastodon.staff(host: host), staff.allows(.manageUsers) || staff.allows(.manageReports) else {
            return false
        }
        return ShellTending.acts(at: host, in: session)
    }

    private func standing(_ host: String, in session: ShellSession) -> People? {
        pages[host].flatMap { $0.under == ShellPersonPages.signIns(at: host, in: session) ? $0 : nil }
    }

    private func door(at host: String, in session: ShellSession) -> MastodonAdminAccounts? {
        guard let door = session.mastodon.authorized(host: host, within: deadline, for: .tending) else { return nil }
        return reaching?(door) ?? MastodonAdminAccounts(door: door)
    }

    // MARK: - What the tab is handed

    func said(of page: Tending, in session: ShellSession, language: DummyLanguage? = nil) -> TendingPeopleSaid {
        let host = page.host
        let acts = ShellTending.acts(at: host, in: session)
        var said = TendingPeopleSaid(host: host, acts: acts, manages: Self.manages(at: host, in: session))
        if !acts { said.lock = session.mastodon.place(.tending, host: host) }
        guard let people = standing(host, in: session) else { return said }
        said.filter = people.filter
        said.accounts = people.rows
        said.acting = people.acting
        if people.notAllowed {
            said.quiet = String(format: L10n.t("tend.act.notAllowed", language: language), host)
        } else if people.answered, people.rows.isEmpty, people.next == nil {
            said.quiet = String(format: L10n.t("tend.people.none", language: language), host)
        }
        if people.answered, !people.asking, !people.readingOn, !people.notAllowed {
            said.foot = people.readsOn ? .more : people.notPaging ? .stopped : people.rows.isEmpty ? nil : .end
        }
        return said
    }

    func walked(_ page: Tending, in session: ShellSession) -> [String] {
        (standing(page.host, in: session)?.rows ?? []).map { TendingPeopleSaid.rowID($0.id) }
    }

    /// The account a row id names, where the tab holds it.
    func account(_ rowID: String, of page: Tending, in session: ShellSession) -> AdminAccount? {
        standing(page.host, in: session)?.rows.first { TendingPeopleSaid.rowID($0.id) == rowID }
    }

    func ask(of page: Tending, language: DummyLanguage? = nil) -> PageAsking {
        guard let people = pages[page.host] else { return PageAsking() }
        return PageAsking(
            asking: people.asking
                ? String(format: L10n.t("tend.people.asking", language: language), page.host)
                : people.readingOn ? L10n.t("tend.people.reading", language: language) : nil,
            stoppable: people.asking || people.readingOn,
            failed: people.failed && !people.asking && !people.readingOn ? [page.host] : [],
            stopped: halted.contains(page.host)
        )
    }

    @discardableResult
    func stop(_ page: Tending) -> Bool {
        let host = page.host
        guard let people = pages[host], people.asking || people.readingOn else { return false }
        asks[host]?.cancel()
        asks[host] = nil
        pages[host]?.awaits = errands.next()
        if people.readingOn { pages[host]?.held = true }
        pages[host]?.asking = false
        pages[host]?.readingOn = false
        halted.insert(host)
        return true
    }

    /// How many wait to be let in at `host`, as one stretch of them said this run — for the
    /// page's head. Nothing until asked, or where the role does not let accounts be managed.
    func waiting(at host: String, in session: ShellSession) -> (count: Int, more: Bool)? {
        guard Self.manages(at: host, in: session), let said = waitingCounts[host],
              said.under == ShellPersonPages.signIns(at: host, in: session)
        else { return nil }
        return (said.count, said.more)
    }

    /// How many wait, asked once a page opening: one stretch of them, counted.
    func countWaiting(_ page: Tending, in session: ShellSession) async {
        guard keepsStanding(at: page.host, in: session) else { return }
        let host = page.host
        let under = ShellPersonPages.signIns(at: host, in: session)
        guard Self.manages(at: host, in: session), waitingCounts[host]?.under != under, let through = door(at: host, in: session)
        else { return }
        guard let stretch = try? await through.stretch(AdminAccountFilter(state: .pending)),
              ShellPersonPages.signIns(at: host, in: session) == under
        else { return }
        waitingCounts[host] = (stretch.accounts.count, stretch.next != nil, under)
    }

    // MARK: - Asking

    func opened(_ page: Tending, in session: ShellSession) async {
        guard keepsStanding(at: page.host, in: session) else { return }
        if let people = standing(page.host, in: session) {
            if people.asking || people.readingOn {
                await asks[page.host]?.value
                return
            }
            if people.answered || people.notAllowed { return }
        }
        await begin(page, fromTop: true, filter: nil, in: session)?.value
    }

    func again(_ page: Tending, in session: ShellSession) async {
        if pages[page.host]?.asking == true { return }
        await begin(page, fromTop: true, filter: nil, in: session)?.value
    }

    /// The tab asked again for `filter`: another state, or a name.
    func find(_ filter: AdminAccountFilter, on page: Tending, in session: ShellSession) async {
        await begin(page, fromTop: true, filter: filter, in: session)?.value
    }

    func readOn(_ page: Tending, pressed: Bool, in session: ShellSession) async {
        guard let people = standing(page.host, in: session), pressed ? people.readsOn : people.reachesOn else { return }
        pages[page.host]?.held = false
        await begin(page, fromTop: false, filter: nil, in: session)?.value
    }

    private func begin(
        _ page: Tending, fromTop: Bool, filter: AdminAccountFilter?, in session: ShellSession
    ) -> Task<Void, Never>? {
        let host = page.host
        guard Self.manages(at: host, in: session), ShellTending.drawn(page, in: session), let through = door(at: host, in: session)
        else { return nil }
        let under = ShellPersonPages.signIns(at: host, in: session)
        if pages[host]?.under != under {
            asks[host]?.cancel()
            pages[host] = People(under: under)
        }
        if let filter { pages[host]?.filter = filter }
        let asked = pages[host]?.filter ?? AdminAccountFilter()
        let next = fromTop ? nil : pages[host]?.next
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
        let task = Task { await self.read(host, asked, after: next, fromTop: fromTop, through: through, errand: errand, in: session) }
        asks[host] = task
        return task
    }

    private func read(
        _ host: String, _ filter: AdminAccountFilter, after next: String?, fromTop: Bool, through: MastodonAdminAccounts,
        errand: Int, in session: ShellSession
    ) async {
        defer { if pages[host]?.awaits == errand { asks[host] = nil } }
        do {
            let stretch = try await through.stretch(filter, after: next)
            guard pages[host]?.awaits == errand, let held = pages[host] else { return }
            let current = Dictionary(held.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // What a write answered after this read set out stands as the write left it: its row,
            // or — for somebody turned away, whose row went — nothing.
            let landed = stretch.accounts.compactMap { account in
                (held.acted[account.id] ?? 0) > errand ? current[account.id] : account
            }
            var rows = fromTop ? [] : held.rows
            var seen = Set(rows.map(\.id))
            rows += landed.filter { seen.insert($0.id).inserted }
            pages[host]?.rows = rows
            pages[host]?.next = stretch.next
            pages[host]?.answered = true
            pages[host]?.notAllowed = false
            pages[host]?.notPaging = false
        } catch {
            guard pages[host]?.awaits == errand else { return }
            switch error {
            case MastodonAdminError.notAllowed: pages[host]?.notAllowed = true
            case is PagingError: pages[host]?.notPaging = true
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

    /// The account `id` lit on `page` — a notice of a new sign-up pressed — made one of the tab's
    /// rows: once the tab has answered, the account itself is asked for where it does not hold
    /// it, and stands at the top. What the server answers otherwise is said.
    func bringIn(_ id: String, of page: Tending, in session: ShellSession) async {
        await opened(page, in: session)
        let host = page.host
        guard let people = standing(host, in: session), people.answered, !people.rows.contains(where: { $0.id == id }),
              let through = door(at: host, in: session)
        else { return }
        let under = people.under
        do {
            let account = try await through.account(id)
            let errand = errands.next()
            guard pages[host]?.under == under, pages[host]?.rows.contains(where: { $0.id == id }) == false else { return }
            pages[host]?.rows.insert(account, at: 0)
            pages[host]?.acted[id] = errand
        } catch {
            guard !Cancellation.happened(error), pages[host]?.under == under else { return }
            say(error, at: host, notFound: "tend.people.unlisted", in: session)
        }
    }

    /// Somebody who signed up, from a notice of them (#382): brought in by the id the notice
    /// gave, the tab's search left as it was — and only where the notice gave none, found among
    /// those waiting by their name. The row they stand on, or nothing.
    func lightSignUp(_ person: NoticePerson, on page: Tending, in session: ShellSession) async -> String? {
        guard let id = person.accountID, ListSubscription.isPathSegment(id) else {
            return await findWaiting(person.handle, on: page, in: session)
        }
        await bringIn(id, of: page, in: session)
        return standing(page.host, in: session)?.rows.contains { $0.id == id } == true ? TendingPeopleSaid.rowID(id) : nil
    }

    /// Somebody who signed up, found among those waiting by the name a notice of them gave (#382),
    /// and the row they stand on — or nothing where the server no longer has them waiting.
    func findWaiting(_ handle: String, on page: Tending, in session: ShellSession) async -> String? {
        let name = String(handle.drop { $0 == "@" }.prefix { $0 != "@" })
        guard !name.isEmpty else { return nil }
        await find(AdminAccountFilter(state: .pending, words: name), on: page, in: session)
        let found = standing(page.host, in: session)?.rows.first { $0.person?.handle == handle || $0.person?.handle == "@\(name)@\(page.host)" }
        if found == nil, standing(page.host, in: session)?.answered == true {
            session.showToast(String(format: L10n.t("tend.people.unlisted"), page.host))
        }
        return found.map { TendingPeopleSaid.rowID($0.id) }
    }

    // MARK: - Acts

    /// Somebody waiting let in: their row the account as the server answers.
    func letIn(_ id: String, of page: Tending, in session: ShellSession) async {
        await write(id, of: page, in: session) { try await $0.approve(id) }
    }

    /// Somebody waiting turned away — after the question its menu item put: the server deletes
    /// them, and the row goes.
    func turnAway(_ id: String, of page: Tending, in session: ShellSession) async {
        await write(id, of: page, in: session) { through in
            try await through.reject(id)
            return nil
        }
    }

    /// `act` taken back from the account `id`: its row the account as the server answers.
    func undo(_ act: AccountAct, on id: String, of page: Tending, in session: ShellSession) async {
        await write(id, of: page, in: session) { try await $0.undo(act, on: id) }
    }

    /// One write on the account `id`, pressed on `page`: sent once — a press while one is on the
    /// wire sends nothing — and its answer written into that page and nowhere else, numbered as
    /// it answers. Nothing for an account the server deleted: the row goes. A refusal or a
    /// failure says so, and changes nothing here.
    private func write(
        _ id: String, of page: Tending, in session: ShellSession, _ send: (MastodonAdminAccounts) async throws -> AdminAccount?
    ) async {
        let host = page.host
        guard Self.manages(at: host, in: session), ShellTending.acts(at: host, in: session),
              pages[host]?.acting.contains(id) == false, let through = door(at: host, in: session)
        else { return }
        let under = pages[host]?.under
        pages[host]?.acting.insert(id)
        defer { if pages[host]?.under == under { pages[host]?.acting.remove(id) } }
        do {
            let account = try await send(through)
            let errand = errands.next()
            guard pages[host]?.under == under else { return }
            let wasWaiting = pages[host]?.rows.first { $0.id == id }?.waiting == true
            if let account {
                replace(account, at: host, errand: errand)
            } else {
                pages[host]?.rows.removeAll { $0.id == id }
                pages[host]?.acted[id] = errand
            }
            // One fewer waits, once they are let in or turned away: the head's figure follows.
            if wasWaiting, account?.waiting != true, let said = waitingCounts[host], said.under == under, said.count > 0 {
                waitingCounts[host] = (said.count - 1, said.more, said.under)
            }
        } catch {
            guard !Cancellation.happened(error), pages[host]?.under == under else { return }
            say(error, at: host, notFound: "tend.act.failed", in: session)
        }
    }

    private func replace(_ account: AdminAccount, at host: String, errand: Int) {
        if let index = pages[host]?.rows.firstIndex(where: { $0.id == account.id }) {
            pages[host]?.rows[index] = account
        }
        pages[host]?.acted[account.id] = errand
        if let seen = staffSeen[Self.key(host, account.id)] { staffSeen[Self.key(host, account.id)] = (seen.under, account) }
    }

    private func say(_ error: any Error, at host: String, notFound: String, in session: ShellSession) {
        switch error {
        case MastodonAdminError.notAllowed: session.showToast(String(format: L10n.t("tend.act.notAllowed"), host))
        case MastodonAdminError.refused(let sentence): session.showToast(String(format: L10n.t("tend.act.refused"), host, sentence))
        case MastodonAuthError.http(404): session.showToast(String(format: L10n.t(notFound), host))
        case MastodonAuthError.signedOut: session.mastodon.endedByServer(host: host)
        default: session.showToast(String(format: L10n.t("tend.act.failed"), host))
        }
    }

    // MARK: - The sheet

    /// The sheet opened on an account — from its row, its page, or a report that names it.
    func openAct(
        on accountID: String, handle: String, local: Bool, at host: String, report: String? = nil, in session: ShellSession
    ) {
        guard Self.actsOn(at: host, in: session), ListSubscription.isPathSegment(accountID) else { return }
        // Freezing is a sign-in's, so only of somebody of this server, and only for a role that
        // manages accounts; the rest are open to a role that answers for reports too.
        let freezes = local && Self.manages(at: host, in: session)
        asking = AccountActAsk(
            host: host, accountID: accountID, handle: LineText.oneLine(handle), report: report,
            offered: AccountAct.allCases.filter { $0 != .freeze || freezes }
        )
    }

    func closeAct() {
        guard asking?.stage != .sending else { return }
        asking = nil
    }

    /// The sheet's Send: suspending asks once more first; everything else is sent. The account is
    /// read again after, and its row and its page are the answer. A refusal stays on the sheet.
    func sendAct(in session: ShellSession, confirmed: Bool = false) async {
        guard var ask = asking, ask.stage != .sending, ask.offered.contains(ask.act) else { return }
        if ask.act == .suspend {
            // **Sent only from its question**: a yes from anywhere else puts the question first.
            guard confirmed, ask.stage == .asking else {
                ask.stage = .asking
                asking = ask
                return
            }
        }
        guard Self.actsOn(at: ask.host, in: session), let through = door(at: ask.host, in: session) else { return }
        let under = ShellPersonPages.signIns(at: ask.host, in: session)
        ask.stage = .sending
        asking = ask
        do {
            try await through.act(ask.act, on: ask.accountID, words: ask.words, tell: ask.tell, report: ask.report)
            guard asking?.id == ask.id else { return }
            asking = nil
            session.showToast(String(format: L10n.t("tend.act.done.\(String(describing: ask.act))"), ask.handle))
            // Read again after it is done: what the act did is the row, here and on their page.
            guard let account = try? await through.account(ask.accountID), ShellPersonPages.signIns(at: ask.host, in: session) == under
            else { return }
            let errand = errands.next()
            if pages[ask.host]?.under == under { replace(account, at: ask.host, errand: errand) }
            staffSeen[Self.key(ask.host, ask.accountID)] = (under, account)
        } catch {
            guard asking?.id == ask.id else { return }
            let words: String = switch error {
            case MastodonAdminError.notAllowed: String(format: L10n.t("tend.act.notAllowed"), ask.host)
            case MastodonAdminError.refused(let sentence): String(format: L10n.t("tend.act.refused"), ask.host, sentence)
            default: String(format: L10n.t("tend.act.failed"), ask.host)
            }
            ask.stage = .failed(words)
            asking = ask
        }
    }

    // MARK: - On their page

    private static func key(_ host: String, _ id: String) -> String { host + "\u{1e}" + id }

    /// Which opening of somebody's page asks what only staff see of them: the host, their id
    /// there, and who asks — nothing where the role does not let accounts be managed.
    func staffOpening(of person: Person?, in session: ShellSession) -> String? {
        guard let person, Self.manages(at: person.source.host, in: session),
              ShellTending.entry(at: person.source.host, in: session).map({ if case .open = $0 { true } else { false } }) == true
        else { return nil }
        return Self.key(person.source.host, person.accountID) + "\u{1e}\(ShellPersonPages.signIns(at: person.source.host, in: session))"
    }

    /// What only staff see of somebody, asked as their page's About comes up. Once a run, and
    /// again after an act on them.
    func staffOpened(of person: Person?, in session: ShellSession) async {
        if let person, !keepsStanding(at: person.source.host, in: session) { return }
        guard staffOpening(of: person, in: session) != nil, let person else { return }
        let host = person.source.host
        let under = ShellPersonPages.signIns(at: host, in: session)
        let key = Self.key(host, person.accountID)
        guard staffSeen[key]?.under != under, let through = door(at: host, in: session),
              let account = try? await through.account(person.accountID),
              ShellPersonPages.signIns(at: host, in: session) == under
        else { return }
        staffSeen[key] = (under, account)
    }

    /// What only staff see of somebody, for their page's About: nothing without the standing.
    func staffSaid(of person: Person?, in session: ShellSession) -> TendingStaffSaid? {
        guard let person, staffOpening(of: person, in: session) != nil,
              let seen = staffSeen[Self.key(person.source.host, person.accountID)],
              seen.under == ShellPersonPages.signIns(at: person.source.host, in: session)
        else { return nil }
        return TendingStaffSaid(host: person.source.host, account: seen.account, acts: Self.actsOn(at: person.source.host, in: session))
    }

    /// What only staff see of somebody let go as their page goes (#382).
    func forgetStaff(of person: Person?) {
        guard let person else { return }
        staffSeen[Self.key(person.source.host, person.accountID)] = nil
    }

    /// Everything of `host` let go where the role no longer lets accounts be managed there: asked
    /// at each press and opening, so nothing kept for the standing outlives it.
    private func keepsStanding(at host: String, in session: ShellSession) -> Bool {
        if Self.manages(at: host, in: session) { return true }
        letGo(at: host)
        return false
    }

    func letGo(at host: String) {
        let host = host.lowercased()
        asks[host]?.cancel()
        asks[host] = nil
        pages[host] = nil
        halted.remove(host)
        waitingCounts[host] = nil
        staffSeen = staffSeen.filter { !$0.key.hasPrefix(host + "\u{1e}") }
        if asking?.host == host { asking = nil }
    }
}
