import FediqoCore
import Foundation
import Observation

/// A list the server keeps, named apart from the tending page's `ServerList`.
fileprivate typealias KeptList = FediqoCore.ServerList

// Lists a source keeps (#337): made, renamed, removed, and who is on them, for that source's
// own page and for a person's page.
//
// **Asked when the source's page opens**, once a run for a host, and only of a source that
// keeps lists and a reader signed in to it. A forum's page is drawn the same and asks nobody.
// Opened again, the page is drawn from what was answered. A failure's try-again asks once more.
//
// **As whoever asked.** An answer lands only while that reader is still who would ask, and is
// let go when the sign-in ends, begins or changes. A write that comes back after they have gone
// is kept for nobody, and changes nothing on this device.
//
// **A sign-in that was not asked for lists still reads them** — reading lists is the reading
// part — **and changes none**. The place says why, and the press asks before any page of the
// server's opens. A write the server refuses is said in the server's sentence, and nothing on
// this device moves.
//
// **What is written down is written here, and only after the server has taken it.** Making a
// list puts it among the categories at once. Renaming one the reader chose relabels it.
// Removing one takes it off, and only once the question was answered yes. A read relabels a
// chosen list and never adds one the reader did not choose.

/// What a source's page is handed of the lists it keeps.
struct ServerListsSaid: Equatable {
    /// Where asking has got to.
    enum Stand: Equatable {
        /// On the wire, or not yet asked.
        case asking
        /// The lists, and the sign-in may change them.
        case ready
        /// The lists, and the sign-in may not change them. The sentence says why.
        case locked(String)
        /// The source failed, or sent what could not be read. Nothing was written down.
        case failed(String)
        /// Not offered: the source has none, or nobody is signed in. The same icon, and why.
        case unavailable(DimReason, String)
    }

    struct Row: Equatable, Identifiable {
        var id: String
        var title: String
        var draft: String
        var replies: ListReplies
        var alsoOnHome: Bool
    }

    var source: String
    var stand: Stand = .asking
    var rows: [Row] = []
    var making = ""
    /// What the source said of a change it would not take, or a name that was nothing.
    var sentence: String?

    var writes: Bool {
        if case .ready = stand { return true }
        return false
    }

    var lock: String? {
        if case .locked(let said) = stand { return said }
        return nil
    }
}

/// The lists a person is on, as their sheet is handed them.
struct PersonListsSaid: Equatable, Identifiable {
    struct Row: Equatable, Identifiable {
        var id: String
        var title: String
        var on: Bool
    }

    var id: String
    var name: String
    var source: String
    var rows: [Row]
    var asking: Bool
    var sentence: String?
    /// Why a change is not offered, where the sign-in may not make one.
    var locked: String?
}

/// Who is on one list, as its sheet is handed them.
struct MembersSaid: Equatable, Identifiable {
    struct Person: Equatable, Identifiable {
        var id: String
        var name: String
        var acct: String
    }

    var id: String
    var title: String
    var source: String
    var people: [Person]
    var adding: String
    var asking: Bool
    var sentence: String?
    var locked: String?
}

/// What every source's page was told this run of the lists it keeps, by host.
@MainActor
@Observable
final class ShellServerLists {
    typealias AskedAs = ShellPersonPages.AskedAs

    private struct Page {
        var askedAs: AskedAs
        var awaits = 0
        var stand: ServerListsSaid.Stand = .asking
        var lists: [KeptList] = []
        var drafts: [String: String] = [:]
        var making = ""
        var sentence: String?
        var asking = false
        /// Lists written while a read of them was still out: that read must not paint over them.
        var kept: Set<String> = []
        /// Lists removed while a read was still out: that read must not put them back.
        var dropped: Set<String> = []
    }

    struct PersonOpen: Identifiable, Equatable {
        var host: String
        var accountID: String
        var name: String
        var id: String { host + "\n" + accountID }
        var rows: [PersonListsSaid.Row] = []
        var asking = false
        var sentence: String?
        var locked: String?
        var awaits = 0
    }

    struct MembersOpen: Identifiable, Equatable {
        var host: String
        var listID: String
        var title: String
        var id: String { host + "\n" + listID }
        var people: [ListPerson] = []
        var adding = ""
        var asking = false
        var sentence: String?
        var locked: String?
        var awaits = 0
    }

    private var pages: [String: Page] = [:]
    var person: PersonOpen?
    var members: MembersOpen?
    @ObservationIgnored private var asks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    /// How long an ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// Another way to the lists, where a test reaches them by one. Nothing in the app.
    @ObservationIgnored var reaching: ((MastodonToken) -> MastodonLists)?

    init(errands: PageErrands, readers: PageReaders) {
        self.errands = errands
        self.readers = readers
    }

    static func opening(_ host: String, in session: ShellSession) -> ShellPersonPages.Opening {
        ShellPersonPages.Opening(id: host, askedAs: ShellPersonPages.askedAs(at: host, in: session))
    }

    func letGo(at host: String) {
        asks[host]?.cancel()
        asks[host] = nil
        pages[host] = nil
        if person?.host == host { person = nil }
        if members?.host == host { members = nil }
    }

    // MARK: - What the page is handed

    func said(at raw: String, in session: ShellSession) -> ServerListsSaid? {
        let host = raw.lowercased()
        guard let source = session.sources.first(where: { $0.host == host }) else { return nil }
        if !source.kind.offers.tendsLists {
            return ServerListsSaid(source: host, stand: .unavailable(.never, L10n.t("mark.dim.never")))
        }
        guard session.mastodon.signedInHosts.contains(host) else {
            return ServerListsSaid(source: host, stand: .unavailable(.notNow, L10n.t("mark.dim.notNow")))
        }
        let askedAs = ShellPersonPages.askedAs(at: host, in: session)
        guard var page = pages[host], page.askedAs.isTheSame(as: askedAs) else {
            return ServerListsSaid(source: host, stand: .asking)
        }
        if case .reader(nil) = page.askedAs, case .reader(.some) = askedAs { page.askedAs = askedAs }
        return ServerListsSaid(
            source: host, stand: page.stand,
            rows: page.lists.map { list in
                ServerListsSaid.Row(
                    id: list.id, title: list.title, draft: page.drafts[list.id] ?? list.title,
                    replies: list.replies, alsoOnHome: list.alsoOnHome
                )
            },
            making: page.making, sentence: page.sentence
        )
    }

    func personSaid() -> PersonListsSaid? {
        guard let person else { return nil }
        return PersonListsSaid(
            id: person.id, name: person.name, source: person.host, rows: person.rows,
            asking: person.asking, sentence: person.sentence, locked: person.locked
        )
    }

    func membersSaid() -> MembersSaid? {
        guard let members else { return nil }
        return MembersSaid(
            id: members.id, title: members.title, source: members.host,
            people: members.people.map { MembersSaid.Person(id: $0.id, name: $0.name, acct: $0.acct) },
            adding: members.adding, asking: members.asking, sentence: members.sentence, locked: members.locked
        )
    }

    /// The question before `id` is removed: which timelines use it, named while the list still is.
    func deleteQuestion(for id: String, title: String, at host: String, in session: ShellSession) -> ShellConfirmation {
        let names = session.written.compactMap { definition -> String? in
            let uses = definition.rules.contains { rule in
                guard rule.effect == .include, case .category(.list(let listed), .source(let there)) = rule.kind else { return false }
                return listed == id && there == host
            }
            return uses ? definition.name : nil
        }
        return ShellQuestion.deleteList(named: title, usedBy: names, at: host)
    }

    // MARK: - The page opening

    func opened(_ raw: String, in session: ShellSession) async {
        guard let source = session.sources.first(where: { $0.host == raw.lowercased() }) else { return }
        let host = source.host
        guard source.kind.offers.tendsLists else { return }
        guard let held = readers.look(at: host, in: session).held,
              session.mastodon.signedInHosts.contains(host)
        else { return }
        let askedAs = ShellPersonPages.askedAs(at: host, in: session)
        if let page = pages[host], page.askedAs.isTheSame(as: askedAs) {
            if page.asking {
                await asks[host]?.value
                return
            }
            if page.stand != .asking { return }
        }
        await begin(source, as: askedAs, with: held, in: session).value
    }

    func again(_ raw: String, in session: ShellSession) async {
        guard let source = session.sources.first(where: { $0.host == raw.lowercased() }),
              source.kind.offers.tendsLists,
              let held = readers.look(at: source.host, in: session).held
        else { return }
        let askedAs = ShellPersonPages.askedAs(at: source.host, in: session)
        if let page = pages[source.host], page.askedAs.isTheSame(as: askedAs) {
            guard isFailed(page.stand), !page.asking else { return }
        }
        await begin(source, as: askedAs, with: held, in: session).value
    }

    private func isFailed(_ stand: ServerListsSaid.Stand) -> Bool {
        if case .failed = stand { return true }
        return false
    }

    private func begin(
        _ source: Source, as askedAs: AskedAs, with held: MastodonToken, in session: ShellSession
    ) -> Task<Void, Never> {
        let host = source.host
        if pages[host]?.askedAs.isTheSame(as: askedAs) != true {
            pages[host] = Page(askedAs: askedAs)
        }
        let errand = errands.next()
        pages[host]?.awaits = errand
        pages[host]?.asking = true
        pages[host]?.stand = .asking
        let through = client(held, in: session)
        let task = Task { await self.load(source, of: through, as: askedAs, errand: errand, in: session) }
        asks[host] = task
        return task
    }

    private func load(
        _ source: Source, of through: MastodonLists, as askedAs: AskedAs, errand: Int, in session: ShellSession
    ) async {
        let host = source.host
        defer { if pages[host]?.awaits == errand { asks[host] = nil; pages[host]?.asking = false } }
        do {
            let lists = try await through.all()
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            let local = pages[host]
            let dropped = local?.dropped ?? []
            let kept = local?.kept ?? []
            var shown = lists.filter { !dropped.contains($0.id) }
            for id in kept {
                guard let row = local?.lists.first(where: { $0.id == id }) else { continue }
                if let index = shown.firstIndex(where: { $0.id == id }) {
                    shown[index] = row
                } else {
                    shown.append(row)
                }
            }
            pages[host]?.lists = shown
            pages[host]?.kept = []
            pages[host]?.dropped = []
            for list in shown where pages[host]?.drafts[list.id] == nil {
                pages[host]?.drafts[list.id] = list.title
            }
            pages[host]?.sentence = nil
            pages[host]?.stand = lock(at: host, in: session).map { .locked($0) } ?? .ready
            let names = Dictionary(lists.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            await session.store.relabel(host: host, lists: names)
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            await session.reprojectSources()
        } catch {
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            if !Cancellation.happened(error), (error as? MastodonAuthError) != .signedOut {
                ShellPersonPages.concluded(error, at: source, askedAs: askedAs, in: session)
                pages[host]?.stand = .failed(said(error))
            }
        }
    }

    // MARK: - Changing a list

    func setMaking(_ text: String, at host: String) {
        pages[host.lowercased()]?.making = text
    }

    func setDraft(_ text: String, of id: String, at host: String) {
        pages[host.lowercased()]?.drafts[id] = text
    }

    func setAdding(_ text: String) {
        members?.adding = text
    }

    /// Asks the sign-in for lists. Nothing is sent, and the server's page is not opened here.
    @discardableResult
    func ask(_ raw: String, in session: ShellSession) -> Bool {
        session.askFor([.lists], host: raw.lowercased())
    }

    func make(at raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        guard writes(at: host, in: session) else { return }
        let title = pages[host]?.making.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            pages[host]?.sentence = L10n.t("lists.blank")
            return
        }
        guard let held = readers.look(at: host, in: session).held, pages[host] != nil else { return }
        let errand = pages[host]?.awaits ?? 0
        let askedAs = ShellPersonPages.askedAs(at: host, in: session)
        do {
            let made = try await client(held, in: session).make(title: title)
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            if var page = pages[host] {
                page.lists.append(made)
                page.drafts[made.id] = made.title
                page.making = ""
                page.sentence = nil
                page.kept.insert(made.id)
                page.dropped.remove(made.id)
                pages[host] = page
            }
            await added(made, at: host, in: session)
        } catch {
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            if let said = failure(error) { pages[host]?.sentence = said }
        }
    }

    func rename(_ id: String, at raw: String, in session: ShellSession) async {
        await edit(id, at: raw, in: session) { list, page in
            var next = list
            next.title = page.drafts[id] ?? list.title
            return next
        }
    }

    func replies(_ id: String, _ replies: ListReplies, at raw: String, in session: ShellSession) async {
        await edit(id, at: raw, in: session) { list, _ in
            var next = list
            next.replies = replies
            return next
        }
    }

    func home(_ id: String, alsoOnHome: Bool, at raw: String, in session: ShellSession) async {
        await edit(id, at: raw, in: session) { list, _ in
            var next = list
            next.exclusive = !alsoOnHome
            return next
        }
    }

    func remove(_ id: String, at raw: String, in session: ShellSession) async {
        let host = raw.lowercased()
        guard writes(at: host, in: session) else { return }
        guard let held = readers.look(at: host, in: session).held, pages[host] != nil else { return }
        let errand = pages[host]?.awaits ?? 0
        let askedAs = ShellPersonPages.askedAs(at: host, in: session)
        let through = client(held, in: session)
        do {
            try await through.remove(id)
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            if var page = pages[host] {
                page.lists.removeAll { $0.id == id }
                page.drafts[id] = nil
                page.sentence = nil
                page.kept.remove(id)
                page.dropped.insert(id)
                pages[host] = page
            }
            await forget(id, at: host, in: session)
        } catch {
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            if let said = failure(error) { pages[host]?.sentence = said }
        }
    }

    private func edit(
        _ id: String, at raw: String, in session: ShellSession,
        proposing: (KeptList, Page) -> KeptList
    ) async {
        let host = raw.lowercased()
        guard writes(at: host, in: session), let page = pages[host], let current = page.lists.first(where: { $0.id == id }) else { return }
        let proposed = proposing(current, page)
        let title = proposed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            pages[host]?.sentence = L10n.t("lists.blank")
            return
        }
        guard let held = readers.look(at: host, in: session).held, pages[host] != nil else { return }
        let errand = page.awaits
        let askedAs = page.askedAs
        do {
            let changed = try await client(held, in: session).change(
                id, title: title, replies: proposed.replies, exclusive: proposed.exclusive
            )
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            if var page = pages[host] {
                if let index = page.lists.firstIndex(where: { $0.id == id }) {
                    page.lists[index] = changed
                }
                page.drafts[id] = changed.title
                page.sentence = nil
                page.kept.insert(id)
                pages[host] = page
            }
            await relabel(changed, at: host, in: session)
        } catch {
            guard stillTheirs(host, errand: errand, askedAs: askedAs, in: session) else { return }
            if let said = failure(error) { pages[host]?.sentence = said }
        }
    }

    // MARK: - A person's lists, and who is on one

    func openPerson(_ accountID: String, named name: String, at raw: String, in session: ShellSession) {
        let host = raw.lowercased()
        guard ListSubscription.isPathSegment(accountID),
              session.sources.first(where: { $0.host == host })?.kind.offers.tendsLists == true,
              session.mastodon.signedInHosts.contains(host)
        else { return }
        members = nil
        let errand = errands.next()
        person = PersonOpen(
            host: host, accountID: accountID, name: name, asking: true,
            locked: lock(at: host, in: session), awaits: errand
        )
        guard let held = readers.look(at: host, in: session).held else { return }
        let through = client(held, in: session)
        Task { await self.loadPerson(of: through, errand: errand) }
    }

    func closePerson() { person = nil }

    func toggle(_ id: String, in session: ShellSession) async {
        guard let open = person else { return }
        guard open.locked == nil else {
            _ = ask(open.host, in: session)
            return
        }
        guard let on = open.rows.first(where: { $0.id == id })?.on,
              let held = readers.look(at: open.host, in: session).held
        else { return }
        let errand = open.awaits
        let through = client(held, in: session)
        person?.asking = true
        do {
            if on {
                try await through.drop(open.accountID, from: id)
            } else {
                try await through.add(open.accountID, to: id)
            }
            guard person?.awaits == errand, person?.accountID == open.accountID else { return }
            if let index = person?.rows.firstIndex(where: { $0.id == id }) {
                person?.rows[index].on.toggle()
            }
            person?.sentence = nil
        } catch {
            guard person?.awaits == errand else { return }
            if let said = failure(error) { person?.sentence = said }
        }
        person?.asking = false
    }

    func openMembers(_ id: String, at raw: String, in session: ShellSession) {
        let host = raw.lowercased()
        guard let list = pages[host]?.lists.first(where: { $0.id == id }) else { return }
        person = nil
        let errand = errands.next()
        members = MembersOpen(
            host: host, listID: id, title: list.title, asking: true,
            locked: lock(at: host, in: session), awaits: errand
        )
        guard let held = readers.look(at: host, in: session).held else { return }
        let through = client(held, in: session)
        Task { await self.loadMembers(of: through, errand: errand) }
    }

    func closeMembers() { members = nil }

    func addMember(at session: ShellSession) async {
        guard let open = members, open.locked == nil else {
            if let host = members?.host { _ = ask(host, in: session) }
            return
        }
        let accountID = open.adding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ListSubscription.isPathSegment(accountID) else {
            members?.sentence = L10n.t("lists.failed")
            return
        }
        guard let held = readers.look(at: open.host, in: session).held else { return }
        let errand = open.awaits
        do {
            try await client(held, in: session).add(accountID, to: open.listID)
            guard members?.awaits == errand else { return }
            members?.adding = ""
            members?.sentence = nil
            if let held = readers.look(at: open.host, in: session).held {
                await loadMembers(of: client(held, in: session), errand: errand)
            }
        } catch {
            guard members?.awaits == errand else { return }
            if let said = failure(error) { members?.sentence = said }
        }
    }

    func dropMember(_ accountID: String, in session: ShellSession) async {
        guard let open = members else { return }
        guard open.locked == nil else {
            _ = ask(open.host, in: session)
            return
        }
        guard let held = readers.look(at: open.host, in: session).held else { return }
        let errand = open.awaits
        do {
            try await client(held, in: session).drop(accountID, from: open.listID)
            guard members?.awaits == errand else { return }
            members?.people.removeAll { $0.id == accountID }
            members?.sentence = nil
        } catch {
            guard members?.awaits == errand else { return }
            if let said = failure(error) { members?.sentence = said }
        }
    }

    private func loadPerson(of through: MastodonLists, errand: Int) async {
        guard let open = person, open.awaits == errand else { return }
        do {
            async let owned = through.all()
            async let on = through.lists(ofAccount: open.accountID)
            let (lists, member) = try await (owned, on)
            guard person?.awaits == errand else { return }
            let ids = Set(member.map(\.id))
            person?.rows = lists.map { PersonListsSaid.Row(id: $0.id, title: $0.title, on: ids.contains($0.id)) }
            person?.sentence = nil
        } catch {
            guard person?.awaits == errand else { return }
            if let said = failure(error) { person?.sentence = said }
        }
        if person?.awaits == errand { person?.asking = false }
    }

    private func loadMembers(of through: MastodonLists, errand: Int) async {
        guard let open = members, open.awaits == errand else { return }
        do {
            let people = try await through.members(of: open.listID)
            guard members?.awaits == errand else { return }
            members?.people = people
            members?.sentence = nil
        } catch {
            guard members?.awaits == errand else { return }
            if let said = failure(error) { members?.sentence = said }
        }
        if members?.awaits == errand { members?.asking = false }
    }

    // MARK: - The store, after a success

    private func added(_ list: KeptList, at host: String, in session: ShellSession) async {
        let existing = await session.store.sources().first { $0.host == host }?.lists ?? []
        guard !existing.contains(where: { $0.id == list.id }) else {
            await relabel(list, at: host, in: session)
            return
        }
        await session.store.subscribe(host: host, toLists: existing + [ListSubscription(id: list.id, name: list.title)])
        await session.reprojectSources()
    }

    private func relabel(_ list: KeptList, at host: String, in session: ShellSession) async {
        await session.store.relabel(host: host, lists: [list.id: list.title])
        await session.reprojectSources()
    }

    private func forget(_ id: String, at host: String, in session: ShellSession) async {
        let existing = await session.store.sources().first { $0.host == host }?.lists ?? []
        await session.store.subscribe(host: host, toLists: existing.filter { $0.id != id })
        await session.reprojectSources()
    }

    // MARK: - Asking

    private func writes(at host: String, in session: ShellSession) -> Bool {
        guard session.sources.first(where: { $0.host == host })?.kind.offers.tendsLists == true,
              session.mastodon.signedInHosts.contains(host)
        else { return false }
        guard MastodonParts.holds(.lists, in: session.mastodon.token(host: host)?.scopes) else {
            _ = ask(host, in: session)
            return false
        }
        return pages[host] != nil
    }

    private func lock(at host: String, in session: ShellSession) -> String? {
        guard !MastodonParts.holds(.lists, in: session.mastodon.token(host: host)?.scopes) else { return nil }
        let place = session.mastodon.place(.lists, host: host) ?? PartWords.Place(kind: .unasked, key: "part.lists.unasked")
        return String(format: L10n.t(place.key), host)
    }

    private func client(_ held: MastodonToken, in session: ShellSession) -> MastodonLists {
        if let reaching { return reaching(held) }
        return MastodonLists(door: session.mastodon.authorized(token: held, within: deadline, for: .lists))
    }

    private func stillTheirs(_ host: String, errand: Int, askedAs: AskedAs, in session: ShellSession) -> Bool {
        guard pages[host]?.awaits == errand else { return false }
        guard ShellPersonPages.askedAs(at: host, in: session).isTheSame(as: askedAs) else {
            pages[host] = nil
            return false
        }
        return true
    }

    /// What a failure says. Nothing where the reader walked away or the sign-in ended: the page
    /// is no longer theirs to write a sentence on, and nothing was written down.
    private func failure(_ error: any Error) -> String? {
        if Cancellation.happened(error) || (error as? MastodonAuthError) == .signedOut { return nil }
        return said(error)
    }

    private func said(_ error: any Error) -> String {
        switch error {
        case MastodonListError.forbidden: L10n.t("lists.forbidden")
        case MastodonListError.refused(let sentence): sentence.isEmpty ? L10n.t("lists.failed") : sentence
        case MastodonListError.gone: L10n.t("lists.gone.said")
        case MastodonListError.invalid: L10n.t("lists.blank")
        default: L10n.t("lists.failed")
        }
    }
}
