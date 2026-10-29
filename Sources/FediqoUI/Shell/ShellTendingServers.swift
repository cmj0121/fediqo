import FediqoCore
import Foundation
import Observation

// The Federation and Blocks tabs of a host's page (#383, #416): on Federation the servers it
// suspends, limits or allows — with what each is refused and why — and on Blocks the mail domains
// and address ranges it refuses to let sign up. Each is added, changed or taken off.
//
// **Each tab's own state**, apart from each other's and from the other tabs'. **Each tab is its
// flag's**: Federation `manage_federation`'s, Blocks `manage_blocks`'; a tab whose flag the role
// lacks is absent, and **asks nothing** — a role holding one flag never asks the other tab's
// lists. Every list of the tab is asked as the tab comes in front; each reads on by its own
// press, by the server's own next. `r`, the mark and a pull ask the tab's lists from the top.
//
// **Every write is the server's, and its answer is the row**, by the rules the other tabs keep:
// numbered as it answers, so a read sent while it was on the wire neither undoes it nor brings
// back a row it took off; written only into the page it was pressed on. **What cuts the server
// off from others asks first, in one line, in red**: suspending a server, and taking a server
// off the ones it allows. A refusal says the server's words, or that the standing does not allow
// it, and changes nothing here.
//
// **Held for the page alone.** What the lists say — ranges of addresses, and why each server is
// refused — is let go when the page leaves, when who reads changes, and when the role no longer
// allows it.

/// One of the two tabs' lists, the tab it stands on, and so the flag of the role it needs.
enum ServerList: String, CaseIterable, Sendable {
    case blocks, allows, mail, addresses

    var tab: AdminTab {
        switch self {
        case .blocks, .allows: .federation
        case .mail, .addresses: .blocks
        }
    }

    var flag: MastodonStaff { tab.flag }
}

/// One list of the tab, as it is handed: its rows, whether more may be read, and what stands
/// where there are none.
struct ServerListSaid<Item: Equatable>: Equatable {
    var items: [Item] = []
    /// Whether the server named more: the list's foot reads on when pressed.
    var more = false
    var quiet: String?
}

/// What the Federation or the Blocks tab is handed: each of its lists the role allows, and
/// nothing of the rest — nothing of the other tab's.
struct TendingServersSaid: Equatable {
    let host: String
    var blocks: ServerListSaid<ServerBlock>?
    var allows: ServerListSaid<ServerAllow>?
    var mail: ServerListSaid<RefusedMailDomain>?
    var addresses: ServerListSaid<RefusedAddress>?
    /// Whether the sign-in may change them: it holds tending's word that changes.
    var acts = false
    /// Rows with a write on the wire, by `ServerList` and id.
    var acting: Set<String> = []
    /// Where the sign-in may not change them: tending's lock.
    var lock: PartWords.Place?

    /// The row id of one item of a list, as the lamp and the keys know it, and a write is told by.
    static func rowID(_ list: ServerList, _ id: String) -> String { "\(list.rawValue)\u{1e}\(id)" }
}

/// A change to the servers or the addresses being written on its sheet (#383).
struct FederationAsk: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A server refused: a new one, or one held, to change.
        case block(ServerBlock?)
        case allow
        case mail
        case address
    }

    enum Stage: Equatable {
        case writing
        /// A change that cuts the server off asks once more, in so many words.
        case asking
        case sending
        case failed(String)
    }

    let host: String
    let kind: Kind
    var draft = ServerBlockDraft()
    var domain = ""
    var ip = ""
    var addressSeverity = AddressSeverity.signUp
    var words = ""
    var stage = Stage.writing

    var id: String { host + "\u{1e}" + String(describing: kind) }

    /// The most a server takes of what is written about a block or a range.
    static let wordsLength = MastodonAdminFederation.wordsLength

    /// Which list it changes.
    var list: ServerList {
        switch kind {
        case .block: .blocks
        case .allow: .allows
        case .mail: .mail
        case .address: .addresses
        }
    }

    /// The page it is sent on: the host's, at the tab its list stands on.
    var page: Tending { Tending(host: host, tab: list.tab) }

    /// Whether what is written cuts the server off from others: a server suspended, where it was
    /// not; an address refused all access; or a range so wide it shuts out whole networks.
    var cutsOff: Bool {
        switch kind {
        case .block(let held): draft.severity == .suspend && held?.severity != .suspend
        case .address: addressSeverity == .noAccess || MastodonAdminFederation.range(ip)?.isWide == true
        case .allow, .mail: false
        }
    }

    /// Whether it may be sent as it stands: names trimmed, and an international one in its ASCII
    /// spelling; an address read as its family reads it, never the whole of one.
    var sendable: Bool {
        switch kind {
        case .block(let held): draft.sendable && (held == nil || held?.domain == draft.domain)
        case .allow, .mail: MastodonAdminFederation.wireDomain(domain) != nil
        case .address: MastodonAdminFederation.isAddress(ip) && words.unicodeScalars.count <= MastodonAdminFederation.wordsLength
        }
    }

    /// The name as it will be sent, where that is not as it was written — an international name
    /// in its ASCII spelling, so a look-alike shows what it truly names. Nothing where they agree.
    var sentAs: String? {
        let written: String = switch kind {
        case .block(let held): held == nil ? draft.domain : ""
        case .allow, .mail: domain
        case .address: ""
        }
        guard let wire = MastodonAdminFederation.wireDomain(written), wire != written else { return nil }
        return wire
    }

    /// Why Send is dim where what is written names nothing it can send — nothing where the field
    /// is empty, or it may be sent.
    var whyNot: String? {
        let (written, key): (String, String) = switch kind {
        case .block(let held): (held == nil ? draft.domain : "", "tend.servers.notDomain")
        case .allow, .mail: (domain, "tend.servers.notDomain")
        case .address: (ip, "tend.servers.notAddress")
        }
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let names = switch kind {
        case .address: MastodonAdminFederation.isAddress(trimmed)
        default: MastodonAdminFederation.wireDomain(trimmed) != nil
        }
        return names ? nil : L10n.t(key)
    }
}

@MainActor
@Observable
final class ShellTendingServers {
    /// One list as far as it has been read.
    private struct Read<Item: Equatable>: Equatable {
        var rows: [Item] = []
        var next: String?
        var answered = false
        var failed = false
        var notPaging = false
        var readingOn = false
    }

    private struct Lists {
        var blocks = Read<ServerBlock>()
        var allows = Read<ServerAllow>()
        var mail = Read<RefusedMailDomain>()
        var addresses = Read<RefusedAddress>()
        var asking = false
        var notAllowed = false
        var awaits = 0
        /// The number of the write that last answered for each row, by `rowID`.
        var acted: [String: Int] = [:]
        var acting: Set<String> = []
        var under = 0

        var answered: Bool { blocks.answered || allows.answered || mail.answered || addresses.answered }
    }

    /// Each tab's lists, by `key`: a tab's ask is its own, so turning to the other neither waits
    /// on it nor is answered by it.
    private var pages: [String: Lists] = [:]
    private var halted: Set<String> = []
    /// The sheet a change is written on, where one is up.
    var asking: FederationAsk?
    /// Why the sheet closed by itself, with nothing sent: the page, its reader or the standing
    /// went. Said once by whoever puts the sheet up, and cleared.
    var gone: String?
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to a server's lists, where a test reaches it by one. Nothing in the app.
    @ObservationIgnored var reaching: ((MastodonAuthorized) -> MastodonAdminFederation)?

    init(errands: PageErrands) {
        self.errands = errands
    }

    // MARK: - Who may

    /// The lists the role at `host` allows, in the order the tabs draw them.
    static func lists(at host: String, in session: ShellSession) -> [ServerList] {
        guard let staff = session.mastodon.staff(host: host) else { return [] }
        return ServerList.allCases.filter { staff.allows($0.flag) }
    }

    /// The lists of `page`'s tab the role allows: none on any other tab.
    static func lists(of page: Tending, in session: ShellSession) -> [ServerList] {
        lists(at: page.host, in: session).filter { $0.tab == page.tab }
    }

    private static func key(_ host: String, _ tab: AdminTab) -> String { host + "\u{1e}" + tab.rawValue }
    private static func key(_ page: Tending) -> String { key(page.host, page.tab) }
    private static func key(_ host: String, _ list: ServerList) -> String { key(host, list.tab) }
    private static let tabs: [AdminTab] = [.federation, .blocks]

    private func standing(_ page: Tending, in session: ShellSession) -> Lists? {
        pages[Self.key(page)].flatMap { $0.under == ShellPersonPages.signIns(at: page.host, in: session) ? $0 : nil }
    }

    /// What the role no longer answers for let go, list by list — everything of `host` where it
    /// answers for none: asked at each opening and press, so nothing kept for the standing
    /// outlives it. A sheet of a list let go closes, and says why.
    private func keepsStanding(at host: String, in session: ShellSession) -> Bool {
        let allowed = Set(Self.lists(at: host, in: session))
        if allowed.isEmpty {
            letGo(at: host)
            return false
        }
        if let ask = asking, ask.host == host, !allowed.contains(ask.list) || !ShellTending.acts(at: host, in: session) {
            closeGone(host)
        }
        for tab in Self.tabs {
            let key = Self.key(host, tab)
            guard pages[key] != nil else { continue }
            if !allowed.contains(.blocks) { pages[key]?.blocks = Read() }
            if !allowed.contains(.allows) { pages[key]?.allows = Read() }
            if !allowed.contains(.mail) { pages[key]?.mail = Read() }
            if !allowed.contains(.addresses) { pages[key]?.addresses = Read() }
        }
        return true
    }

    /// The sheet of `host` closed with nothing sent, since the page, its reader or the standing
    /// went: said once, as the sheet goes (`gone`).
    private func closeGone(_ host: String) {
        guard let ask = asking, ask.host == host else { return }
        asking = nil
        gone = String(format: L10n.t("tend.servers.gone"), host)
    }

    private func door(at host: String, in session: ShellSession) -> MastodonAdminFederation? {
        guard let door = session.mastodon.authorized(host: host, within: deadline, for: .tending) else { return nil }
        return reaching?(door) ?? MastodonAdminFederation(door: door)
    }

    // MARK: - What the tab is handed

    func said(of page: Tending, in session: ShellSession, language: DummyLanguage? = nil) -> TendingServersSaid {
        // What it is handed is only what the role answers for now; what it no longer does is let
        // go at the next opening or press (`keepsStanding`).
        let host = page.host
        let acts = ShellTending.acts(at: host, in: session)
        let allowed = Set(Self.lists(of: page, in: session))
        var said = TendingServersSaid(host: host, acts: acts)
        if !acts { said.lock = session.mastodon.place(.tending, host: host) }
        let lists = standing(page, in: session)
        said.acting = lists?.acting ?? []
        func list<Item: Equatable>(_ which: ServerList, _ read: Read<Item>?) -> ServerListSaid<Item>? {
            guard allowed.contains(which) else { return nil }
            var shown = ServerListSaid(items: read?.rows ?? [], more: read.map { $0.answered && !$0.notPaging && ($0.next != nil || $0.failed) } ?? false)
            if lists?.notAllowed == true {
                shown.quiet = String(format: L10n.t("tend.act.notAllowed", language: language), host)
            } else if let read, read.answered, read.rows.isEmpty, read.next == nil {
                shown.quiet = L10n.t("tend.servers.none.\(which.rawValue)", language: language)
            }
            return shown
        }
        said.blocks = list(.blocks, lists?.blocks)
        said.allows = list(.allows, lists?.allows)
        said.mail = list(.mail, lists?.mail)
        said.addresses = list(.addresses, lists?.addresses)
        return said
    }

    func walked(_ page: Tending, in session: ShellSession) -> [String] {
        guard let lists = standing(page, in: session) else { return [] }
        let allowed = Set(Self.lists(of: page, in: session))
        var ids: [String] = []
        if allowed.contains(.blocks) { ids += lists.blocks.rows.map { TendingServersSaid.rowID(.blocks, $0.id) } }
        if allowed.contains(.allows) { ids += lists.allows.rows.map { TendingServersSaid.rowID(.allows, $0.id) } }
        if allowed.contains(.mail) { ids += lists.mail.rows.map { TendingServersSaid.rowID(.mail, $0.id) } }
        if allowed.contains(.addresses) { ids += lists.addresses.rows.map { TendingServersSaid.rowID(.addresses, $0.id) } }
        return ids
    }

    func ask(of page: Tending, language: DummyLanguage? = nil) -> PageAsking {
        let key = Self.key(page)
        guard let lists = pages[key] else { return PageAsking() }
        let readingOn = lists.blocks.readingOn || lists.allows.readingOn || lists.mail.readingOn || lists.addresses.readingOn
        let failed = lists.blocks.failed || lists.allows.failed || lists.mail.failed || lists.addresses.failed
        return PageAsking(
            asking: lists.asking
                ? String(format: L10n.t("tend.servers.asking", language: language), page.host)
                : readingOn ? L10n.t("tend.servers.reading", language: language) : nil,
            stoppable: lists.asking,
            failed: failed && !lists.asking && !readingOn ? [page.host] : [],
            stopped: halted.contains(key)
        )
    }

    @discardableResult
    func stop(_ page: Tending) -> Bool {
        let key = Self.key(page)
        guard pages[key]?.asking == true else { return false }
        asks[key]?.cancel()
        asks[key] = nil
        pages[key]?.awaits = errands.next()
        pages[key]?.asking = false
        halted.insert(key)
        return true
    }

    // MARK: - Asking

    func opened(_ page: Tending, in session: ShellSession) async {
        guard keepsStanding(at: page.host, in: session) else { return }
        if let lists = standing(page, in: session) {
            if lists.asking {
                await asks[Self.key(page)]?.value
                return
            }
            if lists.answered || lists.notAllowed { return }
        }
        await begin(page, in: session)?.value
    }

    func again(_ page: Tending, in session: ShellSession) async {
        guard keepsStanding(at: page.host, in: session), pages[Self.key(page)]?.asking != true else { return }
        await begin(page, in: session)?.value
    }

    /// Every list of the tab the role allows asked from its top, at once — and nothing of the
    /// other tab's.
    private func begin(_ page: Tending, in session: ShellSession) -> Task<Void, Never>? {
        let host = page.host
        let key = Self.key(page)
        let allowed = Self.lists(of: page, in: session)
        guard !allowed.isEmpty, ShellTending.drawn(page, in: session), let through = door(at: host, in: session) else { return nil }
        let under = ShellPersonPages.signIns(at: host, in: session)
        if pages[key]?.under != under {
            asks[key]?.cancel()
            pages[key] = Lists(under: under)
        }
        let errand = errands.next()
        pages[key]?.awaits = errand
        pages[key]?.asking = true
        halted.remove(key)
        let task = Task {
            defer { if self.pages[key]?.awaits == errand { self.asks[key] = nil } }
            await withTaskGroup(of: Void.self) { group in
                for list in allowed {
                    group.addTask { await self.read(list, at: host, after: nil, through: through, errand: errand, in: session) }
                }
            }
            if self.pages[key]?.awaits == errand { self.pages[key]?.asking = false }
        }
        asks[key] = task
        return task
    }

    /// One list's foot pressed: its next stretch, or again the one that did not come.
    func readOn(_ list: ServerList, of page: Tending, in session: ShellSession) async {
        let host = page.host
        guard keepsStanding(at: host, in: session), Self.lists(at: host, in: session).contains(list),
              let lists = standing(Tending(host: host, tab: list.tab), in: session), !lists.asking,
              let through = door(at: host, in: session)
        else { return }
        let next: String?
        switch list {
        case .blocks: next = lists.blocks.readingOn ? nil : lists.blocks.next
        case .allows: next = lists.allows.readingOn ? nil : lists.allows.next
        case .mail: next = lists.mail.readingOn ? nil : lists.mail.next
        case .addresses: next = lists.addresses.readingOn ? nil : lists.addresses.next
        }
        guard let next else { return }
        setReadingOn(list, at: host, true)
        await read(list, at: host, after: next, through: through, errand: lists.awaits, in: session)
        setReadingOn(list, at: host, false)
    }

    private func setReadingOn(_ list: ServerList, at host: String, _ on: Bool) {
        let key = Self.key(host, list)
        switch list {
        case .blocks: pages[key]?.blocks.readingOn = on
        case .allows: pages[key]?.allows.readingOn = on
        case .mail: pages[key]?.mail.readingOn = on
        case .addresses: pages[key]?.addresses.readingOn = on
        }
    }

    private func read(
        _ list: ServerList, at host: String, after next: String?, through: MastodonAdminFederation, errand: Int, in session: ShellSession
    ) async {
        do {
            switch list {
            case .blocks:
                let stretch = try await through.blocks(after: next)
                land(stretch, into: \.blocks, list, at: host, after: next, errand: errand)
            case .allows:
                let stretch = try await through.allows(after: next)
                land(stretch, into: \.allows, list, at: host, after: next, errand: errand)
            case .mail:
                let stretch = try await through.mailDomains(after: next)
                land(stretch, into: \.mail, list, at: host, after: next, errand: errand)
            case .addresses:
                let stretch = try await through.addresses(after: next)
                land(stretch, into: \.addresses, list, at: host, after: next, errand: errand)
            }
        } catch {
            let key = Self.key(host, list)
            guard pages[key]?.awaits == errand else { return }
            switch error {
            case MastodonAdminError.notAllowed: pages[key]?.notAllowed = true
            case is PagingError: failed(list, at: host, paging: true)
            case MastodonAuthError.signedOut:
                session.mastodon.endedByServer(host: host)
                failed(list, at: host, paging: false)
            default:
                if !Cancellation.happened(error) { failed(list, at: host, paging: false) }
            }
        }
    }

    private func failed(_ list: ServerList, at host: String, paging: Bool) {
        let key = Self.key(host, list)
        switch list {
        case .blocks: if paging { pages[key]?.blocks.notPaging = true } else { pages[key]?.blocks.failed = true }
        case .allows: if paging { pages[key]?.allows.notPaging = true } else { pages[key]?.allows.failed = true }
        case .mail: if paging { pages[key]?.mail.notPaging = true } else { pages[key]?.mail.failed = true }
        case .addresses: if paging { pages[key]?.addresses.notPaging = true } else { pages[key]?.addresses.failed = true }
        }
    }

    /// A stretch landed in its list, **under the rule every write keeps**: a row a write answered
    /// for after this read set out stands as the write left it — changed, added, or gone.
    private func land<Item: Identifiable & Equatable>(
        _ stretch: FederationStretch<Item>, into path: WritableKeyPath<Lists, Read<Item>>, _ list: ServerList, at host: String,
        after next: String?, errand: Int
    ) where Item.ID == String {
        let key = Self.key(host, list)
        guard var lists = pages[key], lists.awaits == errand else { return }
        var read = lists[keyPath: path]
        let current = Dictionary(read.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newer = { (id: String) in (lists.acted[TendingServersSaid.rowID(list, id)] ?? 0) > errand }
        let landed = stretch.items.compactMap { item in newer(item.id) ? current[item.id] : item }
        // Added by a write since this read set out: not in what it brought, and kept.
        let added = next == nil ? read.rows.filter { newer($0.id) && !stretch.items.map(\.id).contains($0.id) } : []
        var rows = next == nil ? added : read.rows
        var seen = Set(rows.map(\.id))
        rows += landed.filter { seen.insert($0.id).inserted }
        read.rows = rows
        read.next = stretch.next
        read.answered = true
        read.failed = false
        read.notPaging = false
        lists[keyPath: path] = read
        lists.notAllowed = false
        pages[key] = lists
    }

    // MARK: - Writes

    /// The sheet for a change opened: a server to refuse, one held to change, a server to allow,
    /// a mail domain or a range to refuse — only where the role allows that list and the sign-in
    /// may change it.
    func open(_ kind: FederationAsk.Kind, at host: String, in session: ShellSession) {
        var ask = FederationAsk(host: host, kind: kind)
        guard Self.lists(at: host, in: session).contains(ask.list), ShellTending.acts(at: host, in: session) else { return }
        if case .block(let held?) = kind { ask.draft = held.draft }
        asking = ask
    }

    func close() {
        guard asking?.stage != .sending else { return }
        asking = nil
    }

    /// The sheet's Send. What cuts the server off asks once more first, and is sent only from
    /// that question. The row is the server's answer; a refusal stays on the sheet.
    func send(on page: Tending, in session: ShellSession, confirmed: Bool = false) async {
        guard var ask = asking, ask.stage != .sending, ask.sendable, ask.host == page.host else { return }
        if ask.cutsOff {
            guard confirmed, ask.stage == .asking else {
                ask.stage = .asking
                asking = ask
                return
            }
        }
        ask.stage = .sending
        asking = ask
        let failure: String? = switch ask.kind {
        case .block(let held):
            if let held {
                await write(.blocks, id: held.id, on: page, in: session) { try await $0.changeBlock(held.id, to: ask.draft) }
            } else {
                await write(.blocks, id: nil, on: page, in: session) { try await $0.addBlock(ask.draft) }
            }
        case .allow: await write(.allows, id: nil, on: page, in: session) { try await $0.addAllow(ask.domain) }
        case .mail: await write(.mail, id: nil, on: page, in: session) { try await $0.addMailDomain(ask.domain) }
        case .address:
            await write(.addresses, id: nil, on: page, in: session) {
                try await $0.addAddress(ask.ip, severity: ask.addressSeverity, words: ask.words)
            }
        }
        guard asking?.id == ask.id else { return }
        if let failure {
            ask.stage = .failed(failure)
            asking = ask
        } else {
            asking = nil
        }
    }

    /// One row taken off — after the question its item put, where taking it off cuts the server off.
    func remove(_ list: ServerList, id: String, on page: Tending, in session: ShellSession) async {
        let failure: String? = switch list {
        case .blocks: await write(list, id: id, on: page, in: session) { through -> ServerBlock? in try await through.removeBlock(id); return nil }
        case .allows: await write(list, id: id, on: page, in: session) { through -> ServerAllow? in try await through.removeAllow(id); return nil }
        case .mail: await write(list, id: id, on: page, in: session) { through -> RefusedMailDomain? in try await through.removeMailDomain(id); return nil }
        case .addresses: await write(list, id: id, on: page, in: session) { through -> RefusedAddress? in try await through.removeAddress(id); return nil }
        }
        if let failure { session.showToast(failure) }
    }

    /// One write on `list`: sent once a row — a press while it is on the wire sends nothing —
    /// numbered as it answers and written into the page it was pressed on and nowhere else. The
    /// failure, in words, where it did not land; nothing where it did, or was asked nothing.
    private func write<Item: Identifiable & Equatable>(
        _ list: ServerList, id: String?, on page: Tending, in session: ShellSession,
        _ send: (MastodonAdminFederation) async throws -> Item?
    ) async -> String? where Item.ID == String {
        let host = page.host
        let at = Self.key(host, list)
        let key = TendingServersSaid.rowID(list, id ?? "new")
        // **Nothing sent is never "done"**: each way this does not send says why, so a sheet stays up.
        let notAllowed = String(format: L10n.t("tend.act.notAllowed"), host)
        guard keepsStanding(at: host, in: session), Self.lists(at: host, in: session).contains(list),
              ShellTending.acts(at: host, in: session)
        else { return notAllowed }
        guard let held = pages[at], held.under == ShellPersonPages.signIns(at: host, in: session) else {
            return String(format: L10n.t("tend.act.failed"), host)
        }
        guard !held.acting.contains(key) else { return String(format: L10n.t("tend.servers.busy"), host) }
        guard let through = door(at: host, in: session) else { return String(format: L10n.t("tend.act.failed"), host) }
        let under = pages[at]?.under
        pages[at]?.acting.insert(key)
        defer { if pages[at]?.under == under { pages[at]?.acting.remove(key) } }
        do {
            let item = try await send(through)
            let errand = errands.next()
            guard pages[at]?.under == under else { return nil }
            let written = item?.id ?? id ?? ""
            pages[at]?.acted[TendingServersSaid.rowID(list, written)] = errand
            switch list {
            case .blocks: apply(item as? ServerBlock, id: id, to: \.blocks, at: at)
            case .allows: apply(item as? ServerAllow, id: id, to: \.allows, at: at)
            case .mail: apply(item as? RefusedMailDomain, id: id, to: \.mail, at: at)
            case .addresses: apply(item as? RefusedAddress, id: id, to: \.addresses, at: at)
            }
            return nil
        } catch {
            guard !Cancellation.happened(error) else { return nil }
            switch error {
            case MastodonAdminError.notAllowed: return String(format: L10n.t("tend.act.notAllowed"), host)
            case MastodonAdminError.refused(let sentence): return String(format: L10n.t("tend.act.refused"), host, sentence)
            case MastodonAuthError.signedOut:
                session.mastodon.endedByServer(host: host)
                return String(format: L10n.t("tend.act.failed"), host)
            default: return String(format: L10n.t("tend.act.failed"), host)
            }
        }
    }

    /// A write's answer in its list: the row replaced or added at the top — or, for one taken
    /// off, gone.
    private func apply<Item: Identifiable & Equatable>(
        _ item: Item?, id: String?, to path: WritableKeyPath<Lists, Read<Item>>, at key: String
    ) where Item.ID == String {
        guard var lists = pages[key] else { return }
        if let item {
            if let index = lists[keyPath: path].rows.firstIndex(where: { $0.id == item.id }) {
                lists[keyPath: path].rows[index] = item
            } else {
                lists[keyPath: path].rows.insert(item, at: 0)
            }
        } else if let id {
            lists[keyPath: path].rows.removeAll { $0.id == id }
        }
        pages[key] = lists
    }

    /// Everything of `host` let go: the page left, who reads it changed, or the role lost. A sheet
    /// up for it closes, and says why.
    func letGo(at host: String) {
        let host = host.lowercased()
        for tab in Self.tabs {
            let key = Self.key(host, tab)
            asks[key]?.cancel()
            asks[key] = nil
            pages[key] = nil
            halted.remove(key)
        }
        closeGone(host)
    }
}
