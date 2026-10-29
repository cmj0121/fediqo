import FediqoCore
import Foundation

/// Where the person stands in the Admin place (#416): on the list of the hosts they answer for,
/// or on one host's page at one of its tabs — and the lamp on either. **Held by the root for the
/// run**, as each stream's walk is, so a person opened from a report and left comes back to the
/// row they pressed.
struct AdminFront: Equatable {
    /// The host's page in front, or nothing where the list is.
    var page: Tending?
    /// The row the lamp is on: a host's on the list, a row of the tab in front on a page.
    var lamp: String?
    /// Bumped by `g`: the list in front scrolled to its top.
    var jump = 0
    /// A notice of a new report or a sign-up pressed before its host's standing was known: the
    /// place is opened on it once it is known, and the press never bounces elsewhere meanwhile.
    var awaited: Notice?

    /// A host's row id, as the lamp and the keys know it.
    static func hostRow(_ host: String) -> String { "host\u{1e}" + host }

    /// The host a row id names, where it names one.
    static func host(ofRow id: String) -> String? {
        let prefix = hostRow("")
        return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
    }

    /// The host's page as it is drawn now: the page in front where its standing and its words
    /// still draw it (`ShellTending.drawn`). Nothing, and the list is drawn in its stead, while a
    /// look that could not be had leaves the standing unknown — the page itself stays in front.
    @MainActor
    func shown(in session: ShellSession) -> Tending? {
        page.flatMap { ShellTending.drawn($0, in: session) ? $0 : nil }
    }

    /// The rows `j` and `k` walk: the tab in front's on a page, the hosts on the list.
    @MainActor
    func rows(in session: ShellSession, tending: ShellTending) -> [String] {
        if let page = shown(in: session) { return tending.walked(page, in: session) }
        return ShellTending.hosts(in: session).map(Self.hostRow)
    }

    /// `j` or `k`: the lamp a row on, or entering at the first or the last. Whether it moved.
    mutating func move(by step: Int, among rows: [String]) -> Bool {
        guard let next = DummyCommand.stepped(rows, from: lamp, by: step), next != lamp else { return false }
        lamp = next
        return true
    }

    /// `g`: the lamp on the first row, and the list scrolled to it.
    mutating func top(among rows: [String]) -> Bool {
        guard let first = rows.first else { return false }
        lamp = first
        jump += 1
        return true
    }

    /// A host pressed, or one of its figures: its page, on `tab` where its standing allows it
    /// and on its first tab otherwise. **A host whose sign-in lacks tending's word that reads**
    /// asks for it alone (`ShellTending.entry`), and opens nothing. Whether anything happened.
    @MainActor
    mutating func open(_ host: String, on tab: AdminTab? = nil, in session: ShellSession) -> Bool {
        switch ShellTending.entry(at: host, in: session) {
        case .open(var opened)?:
            if let tab, ShellTending.tabs(at: host, in: session).contains(tab) { opened.tab = tab }
            page = opened
            lamp = nil
            return true
        case .lock(let place)?:
            return place.asks && session.askFor([.tending], host: host)
        case nil:
            return false
        }
    }

    /// Back from a host's page to the list, the lamp on the host left. The page left, or nothing
    /// where the list was already in front.
    mutating func back() -> Tending? {
        guard let left = page else { return nil }
        page = nil
        lamp = Self.hostRow(left.host)
        return left
    }

    /// Tab on a host's page: its next tab, round their ring. Whether the key was the page's.
    @MainActor
    mutating func rotate(by step: Int, covered: Bool, tending: ShellTending, in session: ShellSession) -> Bool {
        guard var turned = shown(in: session) else { return false }
        let taken = tending.rotate(&turned, by: step, covered: covered, lamp: &lamp, in: session)
        page = turned
        return taken
    }

    /// A tab pressed or swiped to: the page turned in place.
    @MainActor
    @discardableResult
    mutating func turn(to tab: AdminTab, tending: ShellTending, in session: ShellSession) -> Bool {
        guard var turned = shown(in: session), tending.turn(&turned, to: tab, lamp: &lamp, in: session) else { return false }
        page = turned
        return true
    }

    /// The hosts changed under the place — a sign-out, another account, the standing gone: a
    /// page whose host is no longer listed goes back to the list. The page left, for its owner
    /// to let go of what it held.
    @MainActor
    mutating func settle(in session: ShellSession) -> Tending? {
        guard let page, !ShellTending.hosts(in: session).contains(page.host) else { return nil }
        self.page = nil
        lamp = nil
        return page
    }

    /// Where a notice of the Admin place lands (#381, #382).
    enum Landing: Equatable {
        /// The host's page, at the notice's tab.
        case page(Tending)
        /// The list, the host's row lit: its standing is remembered and its page cannot open
        /// now — a check that fails, or the lock, whose words are asked as it lands.
        case list(String)
        /// Kept (`awaited`) until the host's standing is known: nothing opens meanwhile.
        case waiting
    }

    /// A notice pressed: where it lands — its page where the host's standing allows it, the list
    /// where the host is listed and its page cannot open, and **kept to open once the standing is
    /// known** where it is not known yet. Nothing for a notice that is not Admin's, or whose host
    /// is known to give no standing: the line opens what it always did.
    @MainActor
    mutating func noticePressed(_ notice: Notice, in session: ShellSession) -> Landing? {
        if let page = FediqoRootView.tendingOpened(by: notice, in: session) {
            awaited = nil
            return .page(page)
        }
        guard Self.isAdmin(notice) else { return nil }
        let host = notice.source.host.lowercased()
        if ShellTending.hosts(in: session).contains(host) {
            awaited = nil
            return .list(host)
        }
        if session.mastodon.isSignedIn(host: host), !session.mastodon.standingKnown(host: host) {
            awaited = notice
            return .waiting
        }
        awaited = nil
        return nil
    }

    /// The place put where `landing` says: the page, lit on the report a notice names; or the
    /// list, lit on the host — whose lock, where it is one, asks for its words. The page left
    /// for another host's, for its owner to let go of what it held.
    @MainActor
    mutating func land(_ landing: Landing, from notice: Notice?, in session: ShellSession) -> Tending? {
        switch landing {
        case .page(let opened):
            let left = page.flatMap { $0.host == opened.host ? nil : $0 }
            awaited = nil
            page = opened
            lamp = notice?.report.map(TendingReportsSaid.rowID)
            return left
        case .list(let host):
            let left = page
            awaited = nil
            page = nil
            lamp = Self.hostRow(host)
            if case .lock(let place)? = ShellTending.entry(at: host, in: session), place.asks {
                _ = session.askFor([.tending], host: host)
            }
            return left
        case .waiting:
            return nil
        }
    }

    /// The row a notice's page found — the one who signed up — lit, where that page is still
    /// the one in front.
    mutating func lit(_ row: String?, on opened: Tending) {
        guard let row, page == opened else { return }
        lamp = row
    }

    /// The hosts changed: `settle`, and a notice waiting on its host's standing — where that is
    /// known now — where it lands. **Known to give none, it waits no more.**
    @MainActor
    mutating func settled(in session: ShellSession) -> (left: Tending?, opens: (Landing, Notice)?) {
        let left = settle(in: session)
        guard let waiting = awaited else { return (left, nil) }
        let host = waiting.source.host
        guard session.mastodon.standingKnown(host: host) || !session.mastodon.isSignedIn(host: host) else { return (left, nil) }
        guard let landing = noticePressed(waiting, in: session), landing != .waiting else {
            awaited = nil
            return (left, nil)
        }
        return (left, (landing, waiting))
    }

    /// What `r` asks again in Admin: the tab in front, where it may be asked — or, on the list,
    /// each host's reports, whose figure the list draws. Nothing, and `r` is not taken.
    @MainActor
    func reloads(in session: ShellSession, tending: ShellTending) -> [Tending] {
        if let page = shown(in: session) { return tending.canAskAgain(page, in: session) ? [page] : [] }
        return ShellTending.hosts(in: session).map { Tending(host: $0, tab: .reports) }.filter { ShellTending.drawn($0, in: session) }
    }

    /// What Escape did in Admin.
    enum Dismissed: Equatable {
        /// The ask of the tab in front, stopped.
        case stopped
        /// The lamp, put out.
        case lampOut
        /// Back to the list from this page.
        case left(Tending)
    }

    /// Escape in Admin: the ask of the tab in front, then the lamp, then back to the list.
    @MainActor
    mutating func dismiss(in session: ShellSession, tending: ShellTending) -> Dismissed? {
        if let page = shown(in: session), tending.ask(of: page).stoppable, tending.stop(page) { return .stopped }
        if lamp != nil {
            lamp = nil
            return .lampOut
        }
        return back().map(Dismissed.left)
    }

    /// What Return did in Admin.
    enum Entered: Equatable {
        /// The account the lamp is on, on the People tab: that person, to be opened.
        case person(DummyPerson)
        /// The host the lamp is on, opened — or its words asked.
        case host
    }

    /// `Return` in Admin: on the list, the host the lamp is on; on the People tab, the account
    /// the lamp is on, for its person's page. A report opens nothing: its acts are its `…`.
    @MainActor
    mutating func enter(in session: ShellSession, tending: ShellTending) -> Entered? {
        guard let lamp else { return nil }
        if let page = shown(in: session) {
            guard page.tab == .people, let person = tending.people.account(lamp, of: page, in: session)?.person else { return nil }
            return .person(DummyPerson(person))
        }
        guard let host = Self.host(ofRow: lamp), open(host, in: session) else { return nil }
        return .host
    }

    /// The tab a notice of the Admin place opens: a new report the reports (#381), a new
    /// sign-up those waiting (#382). Nothing for any other notice.
    static func tab(of notice: Notice) -> AdminTab? {
        switch notice.kind {
        case .server("admin.report"): .reports
        case .server("admin.sign_up"): .people
        default: nil
        }
    }

    /// Whether a notice is one of those the Admin place opens.
    static func isAdmin(_ notice: Notice) -> Bool { tab(of: notice) != nil }
}
