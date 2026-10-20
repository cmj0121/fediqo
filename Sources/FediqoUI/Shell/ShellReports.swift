import FediqoCore
import Foundation
import Observation

// A post or a person reported to those who answer for the source (#339): what is asked, when,
// and what the sheet holds while it is written.
//
// **Written on a sheet, and sent only from it.** A press on Report — in a post's `…` or on the
// page of whoever wrote it — puts the sheet up and sends nothing: who they are is asked of their
// page as their page asks it (the id the source knows them by, and where they live), and the
// server's rules are read once for the sheet. The report goes when its one Send is pressed, and
// **leaving the sheet any other way sends nothing** and keeps nothing of what was written.
//
// **Nothing is sent to another server unless the person chose it**: the choice to tell the server
// they live on is offered only of somebody who lives on another one, named by that server, and
// off until the person turns it on.
//
// **As the reader who pressed.** The sheet is that sign-in's: the report goes through the door of
// the sign-in held when Send is pressed, and only where it is still the one the sheet was put up
// under — a reader who changed meanwhile sends nothing, and is told so.
//
// **Nothing on this device changes**, sent or not: a report is the source's to keep. A refusal
// or a failure says so on the sheet, and what was written stays there to send again.

/// The report being written, as the person has it now.
struct ReportDraft: Equatable {
    var category: ReportCategory = .spam
    /// The rules it names, by the server's ids: sent only with a violation.
    var rules: Set<String> = []
    /// The posts that show it, by the ids the source gave them.
    var posts: Set<String> = []
    var words = ""
    /// Whether the server they live on is told too. Off until the person turns it on.
    var forward = false
}

/// Every report written this run: the one sheet up, where there is one.
@MainActor
@Observable
final class ShellReports {
    /// The sheet up: whom it reports, at which source, the post it began from, and which sheet
    /// this is of all put up this run.
    struct Open: Identifiable, Equatable {
        let who: DummyPerson
        let host: String
        /// The post the press came from, by the id its source gave it.
        let post: String?
        let number: Int
        /// How often the sign-in at the host had become another when the sheet went up.
        let under: Int
        var id: Int { number }
    }

    enum Stage: Equatable {
        case writing
        case sending
        /// Taken; and whether the source passed it on to the server they live on.
        case sent(forwarded: Bool)
        /// Not taken, in the source's own words where it gave any.
        case failed(String?)
    }

    enum Rules: Equatable {
        case asking
        case said([ServerRule])
        case failed
    }

    private(set) var open: Open?
    var draft = ReportDraft()
    private(set) var stage: Stage = .writing
    private(set) var rules: Rules = .asking
    @ObservationIgnored private var count = 0
    @ObservationIgnored private let readers: PageReaders
    /// How long one ask may take. A test shortens it.
    @ObservationIgnored var deadline: Duration = .seconds(30)
    /// How many of their posts this device holds are offered to pick from.
    static let postsOffered = 40

    init(readers: PageReaders) {
        self.readers = readers
    }

    /// Whether `host` is a source where a post or a person is reported, and somebody is signed
    /// in to it: the one fact of its kind (`SourceOffers.reports`), and a sign-in.
    static func reports(at host: String, in session: ShellSession) -> Bool {
        guard let source = ShellPersonPages.source(at: host, in: session), source.kind.offers.reports else { return false }
        return session.mastodon.token(host: host) != nil
    }

    /// Whether `person` is somebody the reader may report: the reader is known at `host` — by
    /// the account the sign-in's check named, or by their handle — and they are not the reader.
    static func isSomebodyElse(_ person: Person, at host: String, in session: ShellSession) -> Bool {
        if let reader = session.mastodon.reader(host: host) { return reader.id != person.accountID }
        guard let me = ShellPersonPages.own(at: host, in: session) else { return false }
        return me.id != DummyPerson(person).id
    }

    /// Whether `who` may be somebody else than the reader, before the source has said who they
    /// are: the reader is known at `host`, and `who` is not the reader by handle.
    static func mayBeSomebodyElse(_ who: DummyPerson, at host: String, in session: ShellSession) -> Bool {
        guard let me = ShellPersonPages.own(at: host, in: session) else { return false }
        return me.id != who.id
    }

    /// How the sign-in at `host` stands where it holds less than reporting needs, or nothing.
    static func lock(at host: String, in session: ShellSession) -> PartWords.Place? {
        guard session.mastodon.standing(PersonAct.report.needs, host: host) != .held else { return nil }
        return session.mastodon.place(PersonAct.report.needs, host: host) ?? PartWords.Place(kind: .none, key: "part.reports.unasked")
    }

    // MARK: - Putting it up and taking it down

    /// Report pressed, of `who` — from the post `post`, where it came from one. **Where the
    /// sign-in lacks what reporting needs, the press only asks for it**; otherwise the sheet goes
    /// up, who they are is asked of their page, and the server's rules are read. Nothing is sent.
    func start(_ who: DummyPerson, post: String? = nil, people: ShellPersonPages, in session: ShellSession) async {
        guard open == nil, Self.reports(at: who.host, in: session), who.handle != nil,
              Self.mayBeSomebodyElse(who, at: who.host, in: session)
        else { return }
        if let lock = Self.lock(at: who.host, in: session) {
            if lock.asks { session.askFor([PersonAct.report.needs], host: who.host) }
            return
        }
        count += 1
        let sheet = Open(who: who, host: who.host, post: post, number: count, under: ShellPersonPages.signIns(at: who.host, in: session))
        open = sheet
        draft = ReportDraft(posts: post.map { [$0] } ?? [])
        stage = .writing
        rules = .asking
        await people.opened(who, in: session)
        // The source has said who they are: the reader is not reported, however they were named.
        if let person = people.said(of: who, in: session)?.person, !Self.isSomebodyElse(person, at: sheet.host, in: session) {
            if open == sheet { close() }
            return
        }
        await readRules(for: sheet, in: session)
    }

    /// The server's rules read again, for the sheet up.
    func rulesAgain(in session: ShellSession) async {
        guard let open, rules == .failed else { return }
        rules = .asking
        await readRules(for: open, in: session)
    }

    private func readRules(for sheet: Open, in session: ShellSession) async {
        guard let held = readers.look(at: sheet.host, in: session).held else {
            rules = .failed
            return
        }
        let door = MastodonReports(door: session.mastodon.authorized(token: held, within: deadline, for: .people))
        do {
            let read = try await door.rules()
            guard open == sheet else { return }
            rules = .said(read)
        } catch {
            guard open == sheet else { return }
            if let source = ShellPersonPages.source(at: sheet.host, in: session) {
                ShellPersonPages.concluded(error, at: source, askedAs: ShellPersonPages.askedAs(at: sheet.host, in: session), in: session)
            }
            rules = .failed
        }
    }

    /// The sheet taken down — Cancel, Done, or any way out: nothing is sent, and nothing of what
    /// was written is kept. A report on its way is not called back: it is the source's now.
    func close() {
        open = nil
        draft = ReportDraft()
        stage = .writing
        rules = .asking
    }

    // MARK: - What the sheet is handed

    /// What the sheet draws, or nothing where none is up.
    func said(people: ShellPersonPages, in session: ShellSession) -> ReportSaid? {
        guard let open else { return nil }
        let person = people.said(of: open.who, in: session)?.person
        var said = ReportSaid(host: open.host, named: person?.lineHandle ?? LineText.oneLine(open.who.handle ?? open.who.name))
        said.known = person != nil
        said.server = person.flatMap { $0.livesHere ? nil : $0.home }
        said.draft = draft
        said.stage = stage
        said.rules = rules
        // Their posts this device holds, newest first, with the one it began from among them.
        var posts = session.heldPosts(of: open.who).filter { $0.source.host == open.host && $0.statusID != nil }
        posts.sort { $0.postedAt > $1.postedAt }
        said.posts = Array(posts.prefix(Self.postsOffered)).compactMap { item in
            item.statusID.map { ReportSaid.Post(id: $0, line: LineText.oneLine(item.spoiler ?? item.body, limit: 120)) }
        }
        if let first = open.post, !said.posts.contains(where: { $0.id == first }) {
            said.posts.insert(ReportSaid.Post(id: first, line: ""), at: 0)
        }
        // What the person can do themselves, once it is sent: mute or block them (#314).
        if case .sent = stage, let acting = people.stands(to: open.who, in: session) {
            said.afterwards = acting.keeping.filter { ($0 == .mute || $0 == .block) && !acting.asksForPart($0) }
        }
        return said
    }

    // MARK: - Sending

    /// Send pressed: the report as written, through the door of the sign-in held now — only
    /// where the sheet is still that sign-in's, the source has said who they are, and the report
    /// is one a source takes. **Whether the server they live on is told is the draft's word,
    /// and only of somebody who lives on another server.** Whether it was taken.
    @discardableResult
    func send(people: ShellPersonPages, in session: ShellSession) async -> Bool {
        guard let sheet = open, stage != .sending, let said = said(people: people, in: session), said.sends,
              let person = people.said(of: sheet.who, in: session)?.person, Self.isSomebodyElse(person, at: sheet.host, in: session)
        else { return false }
        let looked = readers.look(at: sheet.host, in: session)
        guard let held = looked.held, !looked.changed, sheet.under == ShellPersonPages.signIns(at: sheet.host, in: session) else {
            stage = .failed(nil)
            return false
        }
        let report = ReportToSend(
            accountID: person.accountID, postIDs: said.posts.map(\.id).filter(draft.posts.contains), category: draft.category,
            ruleIDs: said.ruleList.map(\.id).filter(draft.rules.contains), words: draft.words,
            forward: said.server != nil && draft.forward
        )
        stage = .sending
        let door = MastodonReports(door: session.mastodon.authorized(token: held, within: deadline, for: .write))
        do {
            let taken = try await door.send(report)
            guard open == sheet else { return true }
            stage = .sent(forwarded: taken.forwarded)
            // So the sheet may offer to mute or block them: how the reader stands is asked.
            await people.standsOpened(to: sheet.who, in: session)
            return true
        } catch {
            if let source = ShellPersonPages.source(at: sheet.host, in: session) {
                ShellPersonPages.concluded(error, at: source, askedAs: ShellPersonPages.askedAs(at: sheet.host, in: session), in: session)
            }
            guard open == sheet else { return false }
            if case .refused(let sentence) = error as? MastodonReportError {
                stage = .failed(sentence.isEmpty ? nil : sentence)
            } else {
                stage = .failed(nil)
            }
            return false
        }
    }

    /// Mute or Block pressed on the sheet once the report is sent (#314): the sheet comes down,
    /// and **once it is down** (`dismissed`) the act's own sheet goes up — two sheets are not
    /// put up and down in one pass, which a phone answers by showing neither.
    func afterwards(_ act: PersonAct, people: ShellPersonPages, in session: ShellSession) {
        guard let open, case .sent = stage, act == .mute || act == .block else { return }
        following = (act, open.who)
        close()
    }

    /// The act pressed on the sheet as it came down, waiting for it to be gone.
    @ObservationIgnored private(set) var following: (act: PersonAct, who: DummyPerson)?

    /// The sheet is gone from the screen: the act pressed on it as it came down, if any, has its
    /// own sheet put up now.
    func dismissed(people: ShellPersonPages, in session: ShellSession) {
        guard let next = following else { return }
        following = nil
        people.ask(next.act, of: next.who, in: session)
    }
}

/// What the report's sheet draws, as a value — worked out where the report is held, so it is
/// checked without standing a view up.
struct ReportSaid: Equatable {
    struct Post: Equatable, Identifiable {
        let id: String
        /// Its first words, made fit for a line; nothing where this device holds none of it.
        let line: String
    }

    let host: String
    /// Whom it reports, as a sentence of ours names them.
    let named: String
    /// Whether the source has said who they are: until it has, there is nobody to report.
    var known = false
    /// The server they live on, where it is not the source's own: the one that may be told too.
    var server: String?
    var draft = ReportDraft()
    var stage: ShellReports.Stage = .writing
    var rules: ShellReports.Rules = .asking
    var posts: [Post] = []
    /// What the person may do themselves once it is sent.
    var afterwards: [PersonAct] = []

    /// The server's rules as it read them, or none.
    var ruleList: [ServerRule] {
        if case .said(let rules) = rules { rules } else { [] }
    }

    /// Whether Send is a press: they are known, nothing is on its way or taken, a violation names
    /// a rule the server has, and the words are within what a server takes.
    var sends: Bool {
        guard known else { return false }
        switch stage {
        case .sending, .sent: return false
        case .writing, .failed: break
        }
        if draft.category == .violation, !ruleList.contains(where: { draft.rules.contains($0.id) }) { return false }
        return draft.words.unicodeScalars.count <= MastodonReports.wordsLength
    }

    /// Whether the sheet asks which of the server's rules it breaks: only of a violation.
    var asksRules: Bool { draft.category == .violation }

    func title(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("report.title", language: language), named)
    }

    /// Who is told: the source, always — and the server they live on only where the person chose it.
    func told(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("report.told", language: language), host)
    }

    static func category(_ category: ReportCategory, language: DummyLanguage? = nil) -> String {
        L10n.t("report.category.\(category.rawValue)", language: language)
    }

    static func categoryLine(_ category: ReportCategory, language: DummyLanguage? = nil) -> String {
        L10n.t("report.category.\(category.rawValue).line", language: language)
    }

    /// The choice to tell the server they live on, naming it — or nothing of somebody of this one.
    func forwardWords(language: DummyLanguage? = nil) -> String? {
        server.map { String(format: L10n.t("report.forward", language: language), $0) }
    }

    func forwardLine(language: DummyLanguage? = nil) -> String? {
        server.map { String(format: L10n.t("report.forward.line", language: language), $0, host) }
    }

    func rulesLine(language: DummyLanguage? = nil) -> String? {
        switch rules {
        case .asking: String(format: L10n.t("report.rules.asking", language: language), host)
        case .failed: String(format: L10n.t("report.rules.failed", language: language), host)
        case .said(let rules): rules.isEmpty ? String(format: L10n.t("report.rules.none", language: language), host) : nil
        }
    }

    func postsLine(language: DummyLanguage? = nil) -> String {
        posts.isEmpty ? String(format: L10n.t("report.posts.none", language: language), named)
            : L10n.t("report.posts", language: language)
    }

    func wordsCount(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("report.words.count", language: language), draft.words.unicodeScalars.count, MastodonReports.wordsLength)
    }

    /// What stands at the foot, by where sending has got to.
    func stageLine(language: DummyLanguage? = nil) -> String? {
        switch stage {
        case .writing: known ? nil : String(format: L10n.t("report.asking", language: language), host)
        case .sending: String(format: L10n.t("report.sending", language: language), host)
        case .sent(let forwarded):
            forwarded ? String(format: L10n.t("report.sent.forwarded", language: language), host, server ?? "")
                : String(format: L10n.t("report.sent", language: language), host)
        case .failed(let sentence):
            sentence.map { String(format: L10n.t("report.failed.said", language: language), host, $0) }
                ?? String(format: L10n.t("report.failed", language: language), host)
        }
    }

    var isSent: Bool {
        if case .sent = stage { true } else { false }
    }
}

extension ShellSession {
    /// What a post's `…` offers of reporting it (#339): whom, the post by its source's id, and the
    /// lock where the sign-in lacks what reporting needs — or nothing where the post is not one to
    /// report: no sign-in at its source, a kind of source with no reports, the reader's own, no id
    /// to name it by, or gone. **A reblog's row reports the post it shows**, and who wrote it.
    func reportOffer(on item: DummyItem) -> (who: DummyPerson, post: String, lock: ItemActing.Lock?)? {
        let post = item.isReblog ? item.reblogged.first ?? item : item
        let host = post.source.host
        guard ShellReports.reports(at: host, in: self), let id = post.statusID, post.goneSince == nil, !isMine(post),
              let who = DummyPerson(post), who.handle != nil, ShellReports.mayBeSomebodyElse(who, at: host, in: self)
        else { return nil }
        return (who, id, ShellReports.lock(at: host, in: self).map { ItemActing.Lock(place: $0, host: host) })
    }
}
