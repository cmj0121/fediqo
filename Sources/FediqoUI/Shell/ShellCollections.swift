import FediqoCore
import Foundation
import Observation

// A person's own collections, made and tended (#433), and taking themselves out of another's.
//
// **Offered only where the source offers them and the sign-in holds the part**; anything else is
// the ask-for-more of the place it is pressed from, and nothing is sent.
//
// **One thing on the wire per sheet.** While a read or a write is out the sheet's acts do nothing,
// so no read paints over a write and two quick writes are one. Its answer lands only while the
// sheet is the one that asked and the reader is who it was asked as: a sign-in ended or changed
// lets the sheet go, and what comes back lands nowhere (`letGo`).
//
// **What the source refuses changes nothing here**, and is said in its sentence. **An answer lost
// or unreadable is not a refusal**, nor is what it was about being gone: what was asked may have
// landed, so the sheet reads again and does not send it twice — the source's word on what it holds
// is what is then drawn. A read that fails draws that, and asking again: never an empty sheet.
//
// **Nothing is written down on this device.** After a write the page behind the sheet reads again
// (`ShellFeatures.collectionsChanged`), and the list of people kept for it is let go.

/// What the sheet is handed.
struct CollectionsSaid: Equatable, Identifiable {
    struct Row: Equatable, Identifiable {
        var id: String
        var name: String
        var words: String?
        var count: Int
        var hidden: Bool
        var warns: Bool
        /// Where the sheet is about somebody: whether they are in it, and whether that waits on them.
        var holds = false
        var waits = false
    }

    struct Member: Equatable, Identifiable {
        var id: String
        var name: String
        var handle: String
        var waits: Bool
    }

    struct Form: Equatable {
        /// What is changed, or nothing where one is being made.
        var changing: String?
        var draft: CollectionDraft
    }

    struct Opened: Equatable {
        var id: String
        var name: String
        var members: [Member]
    }

    let id: String
    var source: String
    /// Whom the sheet is about, where it is not the reader's own collections alone.
    var person: String?
    var rows: [Row] = []
    var asking = false
    var writing = false
    var sentence: String?
    /// Why the collections could not be read: said instead of any row, with asking again.
    var failed: String?
    var form: Form?
    var opened: Opened?

    /// How much of a stranger's words a line keeps.
    static let lineLength = 200
    static let wordsLength = 300

    /// Whether an act of the sheet does anything now.
    var live: Bool { !asking && !writing && failed == nil }
}

@MainActor
@Observable
final class ShellCollections {
    typealias AskedAs = ShellPersonPages.AskedAs

    /// What a press on the sheet is about: where, as whom, and of whom.
    struct Open: Identifiable {
        let host: String
        let readerID: String
        let askedAs: AskedAs
        /// The count of sign-ins at the host it was opened under.
        let under: Int
        /// Somebody the sheet puts in or takes out of the reader's collections.
        var person: (id: String, name: String)?
        var awaits = 0
        var collections: [PersonCollection] = []
        var asking = false
        var writing = false
        var sentence: String?
        /// Why the collections could not be read. Nothing is offered but asking again.
        var failed: String?
        var form: CollectionsSaid.Form?
        var opened: CollectionRead?

        /// Whether an act of the sheet does anything now.
        var live: Bool { !asking && !writing && failed == nil }

        var id: String { host + "\n" + readerID + "\n" + (person?.id ?? "") }
    }

    private(set) var open: Open?
    /// Places being taken out of another's, so one is never asked twice.
    private var takingOut: Set<String> = []
    @ObservationIgnored private let errands: PageErrands
    @ObservationIgnored private let readers: PageReaders
    @ObservationIgnored private let features: ShellFeatures
    @ObservationIgnored private let lists: ShellPeoplePages
    /// How long an ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)

    init(errands: PageErrands, readers: PageReaders, features: ShellFeatures, lists: ShellPeoplePages) {
        self.errands = errands
        self.readers = readers
        self.features = features
        self.lists = lists
    }

    func letGo(at host: String) {
        if open?.host == host { open = nil }
        takingOut = takingOut.filter { !$0.hasPrefix(host + "\n") }
    }

    /// Closing does not outrun a write: a sheet opened after it could send a second.
    func close() { if open?.writing != true { open = nil } }

    // MARK: - What the sheet is handed

    func said() -> CollectionsSaid? {
        guard let open else { return nil }
        return CollectionsSaid(
            id: open.id, source: open.host, person: open.person?.name,
            rows: open.collections.map { collection in
                let place = open.person.flatMap { person in collection.items.first { $0.accountID == person.id } }
                return CollectionsSaid.Row(
                    id: collection.id, name: Self.line(collection.name), words: collection.words.flatMap(Self.words),
                    count: collection.count,
                    hidden: collection.discoverable == false, warns: collection.sensitive == true,
                    holds: place != nil, waits: place?.state == .pending
                )
            },
            asking: open.asking, writing: open.writing, sentence: open.sentence, failed: open.failed, form: open.form,
            opened: open.opened.map { read in
                CollectionsSaid.Opened(id: read.collection.id, name: Self.line(read.collection.name), members: read.members.map { member in
                    CollectionsSaid.Member(
                        id: member.item.id, name: Self.line(member.person.name.isEmpty ? member.person.handle : member.person.name),
                        handle: Self.line(member.person.handle), waits: member.item.state == .pending
                    )
                })
            }
        )
    }

    /// A stranger's words made fit for a line of the sheet.
    private static func line(_ raw: String) -> String {
        LineText.oneLine(raw, limit: CollectionsSaid.lineLength)
    }

    private static func words(_ raw: String) -> String? {
        let said = LineText.oneLine(raw, limit: CollectionsSaid.wordsLength)
        return said.isEmpty ? nil : said
    }

    // MARK: - Opening

    /// The sheet of the reader's own collections at `host`, or of those `person` may be put in.
    /// Without the part it only asks, and nothing is sent. Not yet told who the reader is there,
    /// it asks the source that first, and says so where it still cannot tell.
    func opening(at raw: String, person: (id: String, name: String)? = nil, in session: ShellSession) async {
        let host = raw.lowercased()
        guard open?.writing != true,
              session.sources.first(where: { $0.host == host })?.kind.offers.tendsCollections == true,
              session.mastodon.signedInHosts.contains(host)
        else { return }
        // Before anything is kept: a look that finds another reader lets go what was theirs.
        var held = readers.look(at: host, in: session).held
        guard MastodonParts.holds(.collections, in: held?.scopes) else {
            _ = session.askFor([.collections], host: host)
            return
        }
        if let person, !ListSubscription.isPathSegment(person.id) { return }
        if Self.reader(at: host, in: session) == nil {
            let under = ShellPersonPages.signIns(at: host, in: session)
            await session.mastodon.learnWho(host: host, within: deadline)
            guard ShellPersonPages.signIns(at: host, in: session) == under else { return }
            held = readers.look(at: host, in: session).held
        }
        guard held != nil, let readerID = Self.reader(at: host, in: session) else {
            session.showToast(String(format: L10n.t("collections.noReader"), host))
            return
        }
        open = Open(
            host: host, readerID: readerID, askedAs: ShellPersonPages.askedAs(at: host, in: session),
            under: ShellPersonPages.signIns(at: host, in: session), person: person
        )
        await read(in: session)
    }

    private static func reader(at host: String, in session: ShellSession) -> String? {
        session.mastodon.reader(host: host)?.id ?? session.mastodon.token(host: host)?.accountID
    }

    /// The press on the way to the reader's own collections, or on leaving another's, wherever it
    /// was made: a pointer's or Return's on the row the lamp is on. Whether it was such a press.
    @discardableResult
    func pressed(_ press: FeaturedPress, on person: DummyPerson, in people: ShellPersonPages, session: ShellSession) -> Bool {
        switch press {
        case .tendCollections:
            Task { await opening(at: person.host, in: session) }
            return true
        case .takeOut(let list):
            guard let owner = people.said(of: person, in: session)?.person,
                  let item = people.featured(of: person, in: session)?.takeOuts[list.accountID]
            else { return true }
            Task { await takeOut(item: item, of: list.accountID, owner: owner.accountID, at: person.host, in: session) }
            return true
        case .tag, .people, .takeOff:
            return false
        }
    }

    /// A failed read asked once more.
    func again(in session: ShellSession) async {
        guard open?.failed != nil, open?.asking == false, open?.writing == false else { return }
        await read(in: session)
    }

    /// Reads the reader's collections, and the one opened, for the sheet up. **Only ever reads**,
    /// so what it fails with says nothing of what may have happened.
    private func read(in session: ShellSession) async {
        guard let (asked, through) = current(in: session) else { return }
        let errand = errands.next()
        open?.awaits = errand
        open?.asking = true
        open?.failed = nil
        let inside = asked.opened?.collection.id
        do {
            async let collections = through.of(asked.readerID)
            var opened: CollectionRead?
            if let inside, let source = ShellPersonPages.source(at: asked.host, in: session) {
                do {
                    opened = try await through.whole(inside, source: source)
                } catch MastodonCollectionError.gone {
                    opened = nil
                }
            }
            let read = try await collections
            guard stillTheirs(asked, errand: errand, in: session) else { return }
            open?.collections = read
            open?.opened = opened
        } catch {
            guard stillTheirs(asked, errand: errand, in: session) else { return }
            if !Cancellation.happened(error) {
                conclude(error, about: asked, in: session)
                open?.failed = Self.saidOfRead(error)
            }
        }
        open?.asking = false
    }

    // MARK: - Making and changing

    func startMaking() {
        guard open?.live == true else { return }
        open?.sentence = nil
        open?.form = CollectionsSaid.Form(changing: nil, draft: CollectionDraft())
    }

    func startChanging(_ id: String) {
        guard open?.live == true,
              let collection = open?.collections.first(where: { $0.id == id })
        else { return }
        open?.sentence = nil
        open?.form = CollectionsSaid.Form(changing: id, draft: CollectionDraft(collection))
    }

    func setDraft(_ draft: CollectionDraft) { open?.form?.draft = draft }

    func cancelForm() { if open?.writing == false { open?.form = nil } }

    /// Sends the form. A refusal leaves it up with what was typed, and says why.
    func save(in session: ShellSession) async {
        guard let form = open?.form else { return }
        if let id = form.changing {
            guard let before = open?.collections.first(where: { $0.id == id }) else { return }
            let was = CollectionDraft(before)
            func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard trimmed(was.name) != trimmed(form.draft.name) || trimmed(was.words) != trimmed(form.draft.words)
                || was.sensitive != form.draft.sensitive || was.discoverable != form.draft.discoverable
            else {
                open?.form = nil
                return
            }
            await write(in: session, closesForm: true) { try await $0.change(id, from: was, to: form.draft) } landed: { open, changed in
                if let index = open.collections.firstIndex(where: { $0.id == id }) { open.collections[index] = changed }
            }
        } else {
            await write(in: session, closesForm: true) { try await $0.make(form.draft) } landed: { open, made in
                open.collections.insert(made, at: 0)
            }
        }
    }

    func remove(_ id: String, in session: ShellSession) async {
        await write(in: session) { try await $0.remove(id) } landed: { open, _ in
            open.collections.removeAll { $0.id == id }
            if open.opened?.collection.id == id { open.opened = nil }
        }
    }

    // MARK: - Who is in one

    /// Somebody's sheet: puts them in `id`, or takes them out where they are in it. **Taking out
    /// asks nothing here, as a person's sheet of lists does not**: the row says where they stand,
    /// and a second press puts them back.
    func toggle(_ id: String, in session: ShellSession) async {
        guard let person = open?.person, let collection = open?.collections.first(where: { $0.id == id }) else { return }
        if let place = collection.items.first(where: { $0.accountID == person.id }) {
            await write(in: session) { try await $0.drop(place.id, from: id) } landed: { open, _ in
                Self.change(&open, id) { $0.filter { $0.id != place.id } }
            }
        } else {
            await write(in: session, notAllowed: "collections.notAllowed.add") { try await $0.add(person.id, to: id) } landed: { open, item in
                Self.change(&open, id) { $0 + [item] }
            }
        }
    }

    /// The items of `id` as `changing` makes them, and its count by them: nothing else of it moves.
    private static func change(_ open: inout Open, _ id: String, _ changing: ([CollectionItem]) -> [CollectionItem]) {
        guard let index = open.collections.firstIndex(where: { $0.id == id }) else { return }
        let was = open.collections[index], items = changing(was.items)
        open.collections[index] = PersonCollection(
            id: was.id, name: was.name, words: was.words, count: items.count, sensitive: was.sensitive,
            discoverable: was.discoverable, items: items
        )
    }

    /// Who is in `id`, read as its owner: those waiting on their consent among them. Gone, the
    /// list is read again and its row leaves.
    func openMembers(_ id: String, in session: ShellSession) async {
        guard open?.asking == false, open?.writing == false, let (asked, through) = current(in: session),
              let source = ShellPersonPages.source(at: asked.host, in: session)
        else { return }
        let errand = errands.next()
        open?.awaits = errand
        open?.asking = true
        open?.sentence = nil
        do {
            let read = try await through.whole(id, source: source)
            guard stillTheirs(asked, errand: errand, in: session) else { return }
            open?.opened = read
        } catch {
            guard stillTheirs(asked, errand: errand, in: session) else { return }
            open?.asking = false
            if Cancellation.happened(error) { return }
            conclude(error, about: asked, in: session)
            if (error as? MastodonCollectionError) == .gone {
                open?.sentence = Self.said(error)
                await self.read(in: session)
            } else {
                open?.sentence = Self.saidOfRead(error)
            }
            return
        }
        open?.asking = false
    }

    func closeMembers() { if open?.asking == false, open?.writing == false { open?.opened = nil } }

    /// Takes the place `item` out of the collection opened, as its owner.
    func dropMember(_ item: String, in session: ShellSession) async {
        guard let inside = open?.opened?.collection.id else { return }
        await write(in: session) { try await $0.drop(item, from: inside) } landed: { open, _ in
            Self.change(&open, inside) { $0.filter { $0.id != item } }
            if let read = open.opened {
                let members = read.members.filter { $0.item.id != item }
                open.opened = CollectionRead(collection: read.collection, members: members)
            }
        }
    }

    // MARK: - One write

    private func write<Answer>(
        in session: ShellSession, closesForm: Bool = false, notAllowed: String = "collections.notAllowed",
        work: (MastodonCollectionWrites) async throws -> Answer, landed: (inout Open, Answer) -> Void
    ) async {
        guard open?.live == true,
              let (asked, through) = current(in: session)
        else { return }
        let errand = errands.next()
        open?.awaits = errand
        open?.writing = true
        open?.sentence = nil
        do {
            let answer = try await work(through)
            guard stillTheirs(asked, errand: errand, in: session), var now = open else { return }
            landed(&now, answer)
            now.writing = false
            if closesForm { now.form = nil }
            open = now
            await changed(asked, in: session)
        } catch {
            guard stillTheirs(asked, errand: errand, in: session) else { return }
            open?.writing = false
            if Cancellation.happened(error) { return }
            conclude(error, about: asked, in: session)
            open?.sentence = Self.said(error, notAllowed: notAllowed)
            if Self.readsAgain(error) {
                // What was asked may stand there, or be gone: read what does, and send nothing.
                open?.form = nil
                await read(in: session)
                await changed(asked, in: session)
            }
        }
    }

    /// What is kept of it elsewhere, told: the page behind reads again, its people are let go.
    private func changed(_ asked: Open, in session: ShellSession) async {
        for collection in asked.collections { lists.forgetCollection(collection.id, at: asked.host) }
        await features.collectionsChanged(of: asked.readerID, at: asked.host, in: session)
    }

    // MARK: - Taking oneself out

    /// The reader takes themselves out of `collection`, which `owner` put together, by their place
    /// in it. A refusal is said and nothing here moves; an answer lost, or a place gone, is read
    /// again and never sent twice.
    func takeOut(
        item: String, of collection: String, owner: String, at raw: String, in session: ShellSession
    ) async {
        let host = raw.lowercased()
        let held = readers.look(at: host, in: session).held
        guard MastodonParts.holds(.changing, of: .collections, in: held?.scopes) else {
            _ = session.askFor([.collections], host: host)
            return
        }
        guard let held, takingOut.insert(host + "\n" + item).inserted else { return }
        let asked = ShellPersonPages.askedAs(at: host, in: session), under = ShellPersonPages.signIns(at: host, in: session)
        func same() -> Bool { ShellPersonPages.stillAsked(host: host, askedAs: asked, under: under, in: session) }
        defer { takingOut.remove(host + "\n" + item) }
        do {
            try await client(held, in: session).leave(item, from: collection)
        } catch {
            guard same() else { return }
            if Cancellation.happened(error) { return }
            if let source = ShellPersonPages.source(at: host, in: session) {
                ShellPersonPages.concluded(error, at: source, askedAs: asked, in: session)
            }
            session.showToast(Self.said(error))
            guard Self.readsAgain(error) else { return }
        }
        guard same() else { return }
        lists.forgetCollection(collection, at: host)
        await features.collectionsChanged(of: owner, at: host, in: session)
    }

    // MARK: - Asking

    /// The sheet as it stands once the sign-in has been looked at, and the door of that sign-in:
    /// **the look comes first**, since it may let the sheet go, and a sheet that is another
    /// reader's is let go here rather than acted on with this one's token.
    private func current(in session: ShellSession) -> (Open, MastodonCollectionWrites)? {
        guard let host = open?.host else { return nil }
        let held = readers.look(at: host, in: session).held
        guard let asked = open else { return nil }
        guard let held, isTheirs(asked, in: session) else {
            open = nil
            return nil
        }
        return (asked, client(held, in: session))
    }

    private func client(_ held: MastodonToken, in session: ShellSession) -> MastodonCollectionWrites {
        session.reach.collections(session.mastodon.authorized(token: held, within: deadline, for: .people))
    }

    /// Whether whoever would ask now is who the sheet was opened as.
    private func isTheirs(_ asked: Open, in session: ShellSession) -> Bool {
        ShellPersonPages.stillAsked(host: asked.host, askedAs: asked.askedAs, under: asked.under, in: session)
    }

    /// What a failure says of the sign-in, told as every read here tells it.
    private func conclude(_ error: any Error, about asked: Open, in session: ShellSession) {
        guard let source = ShellPersonPages.source(at: asked.host, in: session) else { return }
        ShellPersonPages.concluded(error, at: source, askedAs: asked.askedAs, in: session)
    }

    private func stillTheirs(_ asked: Open, errand: Int, in session: ShellSession) -> Bool {
        guard open?.awaits == errand else { return false }
        guard isTheirs(asked, in: session) else {
            open = nil
            return false
        }
        return true
    }

    /// Whether a failed write leaves the source's word to be read: no answer said what became of
    /// it, what it took came back unreadable, or what it was about is gone. **Never sent again.**
    static func readsAgain(_ error: any Error) -> Bool {
        switch error {
        case MastodonCollectionError.gone, MastodonCollectionError.tookUnreadable: true
        case is MastodonCollectionError: false
        default: (error as? MastodonAuthError) != .signedOut
        }
    }

    static func said(_ error: any Error, notAllowed: String = "collections.notAllowed", language: DummyLanguage? = nil) -> String {
        switch error {
        case MastodonCollectionError.refused(let sentence): sentence
        case MastodonCollectionError.tooMany: L10n.t("collections.tooMany", language: language)
        case MastodonCollectionError.notAllowed: L10n.t(notAllowed, language: language)
        case MastodonCollectionError.outOfScope, MastodonCollectionError.locked: L10n.t("collections.outOfScope", language: language)
        case MastodonCollectionError.gone: L10n.t("collections.gone", language: language)
        case MastodonCollectionError.invalid: L10n.t("collections.blank", language: language)
        case MastodonCollectionError.unreadable: L10n.t("collections.failed", language: language)
        default: L10n.t("collections.lost", language: language)
        }
    }

    /// What a read that failed says: nothing was asked to happen.
    static func saidOfRead(_ error: any Error, language: DummyLanguage? = nil) -> String {
        switch error {
        case MastodonCollectionError.outOfScope, MastodonCollectionError.locked: L10n.t("collections.outOfScope", language: language)
        case MastodonCollectionError.gone: L10n.t("collections.gone", language: language)
        default: L10n.t("collections.readFailed", language: language)
        }
    }
}

extension MastodonSessions {
    /// What stands where the collections of `host` would, where the sign-in lacks their words.
    func collectionsLock(host: String) -> PartWords.Place? {
        MastodonParts.holds(.collections, in: token(host: host)?.scopes) ? nil
            : place(.collections, host: host) ?? PartWords.Place(kind: .unasked, key: "part.collections.unasked")
    }
}
