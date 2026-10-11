import AuthenticationServices
import FediqoCore
import Foundation
import Observation
import SwiftUI

/// A sign-in already held is asked for a further part **where it stands** (#347): one question,
/// one page of the source's own, and nobody signed out to ask. The one path every part goes by
/// — a part is an entry in `MastodonPart`'s table and its sentences in the string tables, and
/// nothing here names one.
///
/// The press raises a question (`ShellPartAsks.raise`) and sends nothing. Only its yes reaches
/// `MastodonSessions.ask`, which opens the page; whatever happens there, the sign-in the person
/// had goes on as it was, and **the act that was pressed is not carried out by itself**: the
/// place reads again and offers it.
struct PartAsk: Equatable {
    /// The source, folded.
    let host: String
    /// The parts the source's page will ask for beyond what the sign-in holds.
    let ticked: Set<MastodonPart>
    /// Every word of the page the question was drawn for. The page opened after its yes asks
    /// no word outside these, whatever the sign-in turns out to hold.
    let said: String
    /// The words the sign-in holds that this build does not use, which the question says are
    /// given up — with the sign-in this device had ended at the source.
    let givesUp: [String]
    /// Which sign-in the question is about: the mark of its filing. Another held by the time
    /// of the yes, and nothing is asked.
    let stamp: String?
    /// The parts whose act beside acting the page asks for with the rest, because it brings
    /// the two together (`MastodonParts.beside`): each is named by the question.
    var beside: [MastodonPart] = []
    /// Whether this question is put again in the place of one whose yes opened no page: what
    /// the sign-in holds turned out other than that one was drawn from, and it says so.
    var again = false
    /// The parts of `ticked` nobody pressed for: ticked with the one that was, because its
    /// question names them. A source with none of these has not said so of what was pressed.
    var with: Set<MastodonPart> = []
    /// Whether it is put again for want of a part the one before named, of which the source
    /// has none — which is then what it says, and not that the sign-in holds otherwise.
    var without = false
    /// The parts of `ticked` the sign-in holds in part: the page adds only the words of them
    /// it lacks, and the question says so.
    var rest: Set<MastodonPart> = []
}

/// The question open about a part, and the asks on their way — **an object of the session's,
/// so an ask belongs to no view**: a page left, a card sliding away or a window closed takes
/// nothing of it along.
@MainActor
@Observable
final class ShellPartAsks {
    /// The question raised last and not yet answered or put down. One at a time: a second
    /// raised over it takes its place.
    private var raised: PartAsk?

    /// Whose sign-ins the question raised is about.
    @ObservationIgnored private weak var sessions: MastodonSessions?

    /// The question open, where one is — **only while the sign-in it was raised about is the
    /// one held** (`MastodonSessions.isSame`): signed out of, removed, ended by its source, or
    /// replaced by another (a sign-in, a package read back), its question is down with it
    /// (`putDown(host:)`) and nobody is left looking at a yes that could ask nothing.
    var open: PartAsk? {
        guard let raised, let sessions, let held = sessions.heldParts[raised.host] else { return nil }
        return sessions.isSame(raised.stamp, as: held.stamp, host: raised.host) ? raised : nil
    }

    /// The asks started by a yes and not yet landed, a source each.
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]

    /// What the read-or-act question open carries beside its two answers.
    struct SignInTicks: Equatable {
        /// The source it is about, folded: it is said of no other's question.
        let host: String
        /// The parts ticked with either answer: the question was raised from their lock,
        /// where no sign-in is held (`ShellSession.askSignIn`).
        var parts: Set<MastodonPart> = []
        /// Whether it is put again in the place of one whose yes opened no page.
        var again = false
    }

    /// That, for the one question open — **one record, whatever the source**: gone when a
    /// question about any source is raised or put down, so it rides no later one.
    private var signInTicked: SignInTicks?

    /// What the question open about `host` carries, where it is the one this was kept for.
    func signInTicks(host: String) -> SignInTicks? {
        signInTicked.flatMap { $0.host == host ? $0 : nil }
    }

    /// The read-or-act question about `host` is raised with `parts` ticked.
    func tickSignIn(_ parts: Set<MastodonPart>, host: String, again: Bool = false) {
        signInTicked = SignInTicks(host: host, parts: parts, again: again)
    }

    /// A read-or-act question is raised with nothing ticked, or put down: the next one
    /// reads afresh.
    func putDownSignIn() {
        signInTicked = nil
    }

    /// The press on a locked act: raises the question about `host`'s sign-in and `ticked`.
    /// Sends nothing. Returns whether a question was raised — none where no part of `ticked`
    /// may be asked of that sign-in, and none while an ask of that source is on its way.
    ///
    /// `with` are parts ticked beside those pressed for (`PartAsk.with`): asked only with
    /// them, and never by themselves. `again` is a question put in the place of one whose
    /// yes opened no page — `without` a part that one named, where that is why.
    @discardableResult
    func raise(
        _ ticked: Set<MastodonPart>, with beside: Set<MastodonPart> = [], host raw: String, in session: ShellSession,
        again: Bool = false, without: Bool = false
    ) -> Bool {
        let host = raw.lowercased()
        let mastodon = session.mastodon
        let asked = ticked.union(beside).filter { mastodon.mayAsk($0, host: host) }
        let pressed = asked.subtracting(beside)
        guard !pressed.isEmpty, !mastodon.asking.contains(host), let held = mastodon.heldParts[host] else { return false }
        let page = MastodonParts.page(held: held.scopes, ticked: asked)
        sessions = mastodon
        raised = PartAsk(
            host: host, ticked: asked, said: page, givesUp: MastodonParts.unknown(in: held.scopes),
            stamp: held.stamp, beside: MastodonParts.beside(on: page, than: held.scopes), again: again,
            with: asked.subtracting(pressed), without: without,
            rest: asked.filter { mastodon.standing($0, host: host) == .partly }
        )
        return true
    }

    /// The question answered no, dismissed, or overtaken: everything stays as it was.
    func putDown() {
        raised = nil
    }

    /// The sign-in held at `host` has become another, or none: a question raised about the
    /// one before goes with it, and no sign-in filed there later brings it back.
    func putDown(host: String) {
        if raised?.host == host { raised = nil }
    }

    /// The question answered yes: the ask it starts is kept here until it lands, behind any
    /// of that source's started before it. The card has put its question down by the time it
    /// hands the answer over, so what makes a yes stale is looked for where the ask begins —
    /// the sign-in the question was about must still be the one held (`MastodonSessions.ask`).
    func answer(_ ask: PartAsk, through browser: any OAuthBrowser, in session: ShellSession) {
        if raised == ask { raised = nil }
        let before = running[ask.host]
        running[ask.host] = Task { [weak session] in
            await before?.value
            await session?.allow(ask, through: browser)
        }
    }

    /// Waits for the asks of `host` started here.
    func landed(host: String) async {
        await running[host.lowercased()]?.value
    }
}

extension ShellSession {
    /// The yes to a part's question: the source's own page, through `MastodonSessions.ask`, and
    /// then **what is true, said once** under the source's row and as a toast.
    ///
    /// The sign-in the person had is still held and still does everything it did, whatever
    /// happened on the page — so nothing here says "the sign-in failed". A page closed says
    /// nothing, as any sign-in's does; so does a question whose sign-in was gone by its yes.
    ///
    /// **Allowed, the place is read again and nothing more**: the act whose lock was pressed
    /// is offered there, and is the person's to press.
    ///
    /// **A yes is never left to come to nothing**: where what is held was not what the
    /// question was drawn from, or the source has none of a part ticked beside the one
    /// pressed for, the question is put again, drawn from what is held now and saying why
    /// it is back — and where that leaves nothing to ask, or there was nothing left by the
    /// yes, how the sign-in stands to the part is said instead.
    ///
    /// **It is put again only where no question stands open**: this lands seconds after
    /// the yes, and one the person has opened since — about another source — is not taken
    /// from under their hand. The place then goes on offering its press, and nothing is said.
    ///
    /// **A part with a place of its own is told there** (`PartWords.Earlier.says`): notices,
    /// on the notices page, where the press for them is. Every other, under the row.
    func allow(_ ask: PartAsk, through browser: any OAuthBrowser) async {
        let host = ask.host
        let own = PartWords.own(ask.ticked)
        if rowRefusal?.host == host { rowRefusal = nil }
        own?.says?(self, host, nil)
        let answer = await mastodon.ask(ask.ticked, host: host, through: browser, answering: ask)
        await forgetReaderMarksDue()
        if case .failed(let failure) = answer {
            NetLog.auth.notice("\(NetLog.line("part", host: host, error: failure), privacy: .public)")
        }
        var key = PartWords.said(answer, of: ask.ticked)
        let pressed = ask.ticked.subtracting(ask.with)
        let back = answer == .changed || answer == .hasNoneOfSome
        let waits = back && partAsks.open != nil
        let again = back && !waits && partAsks.raise(
            pressed, with: ask.with, host: host, in: self, again: true, without: answer == .hasNoneOfSome
        )
        if answer == .nothingLeft || (back && !waits && !again) { key = settled(ask.ticked, host: host) }
        if let key {
            if let says = own?.says {
                says(self, host, key)
            } else {
                if isAdded(host), PartWords.staysUnderRow(answer) { rowRefusal = (host: host, key: key) }
                showToast(String(format: L10n.t(key), host))
            }
        }
        guard answer == .allowed || answer == .notGiven, mastodon.isSignedIn(host: host) else { return }
        await own?.allowed?(self, host)
        await readAsYou(host: host)
    }

    /// What is said where a yes found nothing left of `ticked` to ask for at `host`: how the
    /// sign-in stands to the first part of them that has anything to say. Nothing, where the
    /// sign-in is gone.
    ///
    /// **Where what rides beside the sign-in still says the part may be asked, the sign-in
    /// itself is believed**: it holds the part, that is said, and what rides beside it is
    /// read again so the place stops offering.
    private func settled(_ ticked: Set<MastodonPart>, host: String) -> String? {
        for part in PartWords.named(ticked) {
            switch mastodon.standing(part, host: host) {
            case .held?: return "part.ask.held"
            case .notGiven?: return PartWords.earlier[part]?.none ?? "part.ask.none"
            // One that may not be asked though it never was: it adds to acting, and this
            // sign-in only reads.
            case .unasked?, .refused?:
                guard mastodon.mayAsk(part, host: host) else { return "part.ask.reads" }
                mastodon.refresh()
                return "part.ask.held"
            // Held in part, and the rest is not to be asked for where the sign-in stands.
            case .partly?:
                guard mastodon.mayAsk(part, host: host) else { return "part.ask.partly" }
                mastodon.refresh()
                return "part.ask.held"
            case nil: continue
            }
        }
        return nil
    }

    /// The press on a locked act or on a line that asks: raises the question about `ticked`
    /// at `host`. Sends nothing. Returns whether a question was raised.
    ///
    /// **While that source is being asked for anything, no second question is raised** — one
    /// ask a source at a time — **and the press says so** in place of doing nothing.
    ///
    /// `with` are parts ticked beside those pressed for, because the question names them.
    @discardableResult
    func askFor(_ ticked: Set<MastodonPart>, with beside: Set<MastodonPart> = [], host raw: String) -> Bool {
        let host = raw.lowercased()
        if partAsks.raise(ticked, with: beside, host: host, in: self) { return true }
        if mastodon.asking.contains(host) { showToast(String(format: L10n.t("part.ask.asking"), host)) }
        return false
    }
}

extension MastodonSessions {
    /// What is drawn where `part`'s act would be at `host`, as its sign-in stands to it now
    /// (`PartWords.place`) — nothing where the act itself is offered, or no sign-in is held.
    func place(_ part: MastodonPart, host raw: String) -> PartWords.Place? {
        let host = raw.lowercased()
        let lacking = MastodonParts.half(of: part, in: heldParts[host]?.scopes)?.other
        return standing(part, host: host).flatMap {
            PartWords.place($0, of: part, asking: asking.contains(host), rest: mayAsk(part, host: host), lacking: lacking)
        }
    }
}

/// The words an ask in place is put and answered in.
///
/// **A part's own are found by its name**: `part.<name>.ask.title`, `.line` and `.detail`,
/// `part.<name>.ask.beside` for the act it gains beside acting, `part.<name>.unasked` for
/// its lock, and `part.<name>.partly` for its lock where part of it is held — which only a
/// part of more than one word can be — or, for a part with a half that sees and a half that
/// changes, `part.<name>.partly.seeing` and `.changing`, by the half it lacks. And
/// `part.<name>.readOnly` for what reading alone leaves of it, where that is not all of it
/// (`ShellQuestion.signInSaid`). A question about several parts says each one's. A part asked before there
/// was a table keeps the sentences it had (`earlier`), and where a part has none of its own
/// for an outcome, the outcome's own sentence is said.
@MainActor
enum PartWords {
    /// The sentences a part was asked in before every part went one way.
    struct Earlier {
        /// Its question, as it was worded — or nothing where those words would not be true
        /// of this page, and the table's are said.
        let question: @MainActor (PartAsk, DummyLanguage?) -> ShellConfirmation?
        let failed: String
        /// What is said of a source with none of it.
        let none: String
        /// The line of its lock where the sign-in was never asked for it.
        let unasked: String
        /// The parts its question was worded to ask for with it, where they are ticked too.
        var with: Set<MastodonPart> = []
        /// Where what an ask came to is said, for a part with a place of its own: the key of
        /// the sentence, or nothing to take the last one down. Without one, under the row.
        var says: (@MainActor (ShellSession, String, String?) -> Void)?
        /// What its place does once the sign-in holds it.
        var allowed: (@MainActor (ShellSession, String) async -> Void)?
    }

    static let earlier: [MastodonPart: Earlier] = [
        .bookmarks: Earlier(
            // Worded for the notices too, where the page carries the ones the sign-in holds.
            // Only where it carries both of them: those words say the page asks to dismiss.
            question: { ShellQuestion.bookmarks(host: $0.host, notices: MastodonOAuth.dismisses($0.said), language: $1) },
            failed: "account.bookmarks.failed", none: "account.bookmarks.unavailable",
            unasked: "account.source.permission"
        ),
    ].merging(noticed) { own, _ in own }

    /// The parts a question about `ticked` words, every one, in the table's order.
    static func named(_ ticked: Set<MastodonPart>) -> [MastodonPart] {
        MastodonPart.allCases.filter(ticked.contains)
    }

    /// The sentences `ticked` was asked in before, where one part of it has any that cover
    /// every part ticked: asked alone, or with the parts its question was worded to name. A
    /// question about any other several is worded by the table for each.
    static func own(_ ticked: Set<MastodonPart>) -> Earlier? {
        named(ticked).lazy.compactMap { part in
            earlier[part].flatMap { ticked.subtracting([part]).isSubset(of: $0.with) ? $0 : nil }
        }.first
    }

    /// The most words a question names as given up, and the most of each: they are whatever
    /// a source chose to call them. And the most a source's own page lists (`holds`), where
    /// every one is to be said.
    static let wordsShown = 3
    static let wordLength = 24
    static let wordsWhole = 32

    /// The words a question says are given up: the first few — `most` of them — each cut
    /// short, and how many more there are.
    ///
    /// **Only what can be seen of a word is shown**: a mark that turns the line round, or
    /// any other character that draws nothing, is left out, and so is a word made of nothing
    /// else.
    static func shown(_ words: [String], most: Int = wordsShown, language: DummyLanguage? = nil) -> String {
        let seen = words.map { String(String.UnicodeScalarView($0.unicodeScalars.filter(isSeen))) }.filter { !$0.isEmpty }
        let few = seen.prefix(most).map { $0.count > wordLength ? String($0.prefix(wordLength)) + "…" : $0 }
        let listed = few.joined(separator: ", ")
        guard seen.count > few.count else { return listed }
        return String(format: L10n.t("part.ask.givesUp.more", language: language), listed, seen.count - few.count)
    }

    /// Whether a scalar of a source's word draws anything: not a control character, and not
    /// one that only directs the text around it.
    private static func isSeen(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: false
        default: true
        }
    }

    /// What a place draws where a part's act would be, for one standing of the sign-in.
    struct Place: Equatable {
        enum Kind: Equatable {
            /// Never asked: a lock whose press asks.
            case unasked
            /// Refused on the source's own page: the line is the press, and asks again.
            case refused
            /// The source has none to allow, or gave none: said, and not offered.
            case none
            /// The source is being asked for something now: nothing more until that lands.
            case asking
            /// Held in part, and never asked for the rest: a lock whose press asks for it.
            case partly
        }

        let kind: Kind
        /// The key of its line, with the source for its one argument.
        let key: String
        /// Whether pressing the line asks.
        var asks: Bool { kind == .unasked || kind == .refused || kind == .partly }
    }

    /// What is drawn where `part`'s act would be, for a sign-in that stands to it so — **the
    /// one reading of a standing every place draws from**. Nothing where the act itself is
    /// offered: held, and held in part, where what is held is offered and the rest is not
    /// asked for.
    ///
    /// **`rest` is whether the rest of a part held in part may be asked for**
    /// (`MastodonSessions.mayAsk`): then it has a line of its own, beside what is offered of
    /// it, and the press asks for the words it lacks.
    ///
    /// **`lacking` is the half of it the sign-in was not asked for**, where the part has
    /// halves (`MastodonParts.half`): the line is keyed by it, so it says what is missing
    /// and never what is held.
    ///
    /// `asking` is whether that source is being asked for something now: a line that would
    /// ask then says so, and cannot be pressed.
    static func place(
        _ standing: MastodonPartStanding, of part: MastodonPart, asking: Bool = false, rest: Bool = false,
        lacking: MastodonHalf? = nil
    ) -> Place? {
        let partly = "part.\(part.rawValue).partly" + (lacking.map { ".\($0.rawValue)" } ?? "")
        return switch standing {
        case .partly where rest && asking: Place(kind: .asking, key: "part.ask.asking")
        case .partly where rest: Place(kind: .partly, key: partly)
        case .held, .partly: nil
        case .unasked where asking, .refused where asking: Place(kind: .asking, key: "part.ask.asking")
        case .unasked: Place(kind: .unasked, key: earlier[part]?.unasked ?? "part.\(part.rawValue).unasked")
        case .refused: Place(kind: .refused, key: "part.ask.refused")
        case .notGiven: Place(kind: .none, key: earlier[part]?.none ?? "part.ask.none")
        }
    }

    /// The key of the sentence that says what `answer` came to, with the source for its one
    /// argument — or nothing where there is nothing to say.
    static func said(_ answer: MastodonSessions.PartAnswer, of ticked: Set<MastodonPart>) -> String? {
        let before = own(ticked)
        switch answer {
        case .allowed, .putDown, .busy, .changed, .nothingLeft, .hasNoneOfSome: return nil
        // With no press in it: the press is the place's own line (`part.ask.refused`).
        case .refused: return "part.ask.refused.said"
        case .hasNone, .notGiven: return before?.none ?? "part.ask.none"
        case .another: return "part.ask.another"
        case .less: return "part.ask.less"
        case .unconfirmed: return "part.ask.unconfirmed"
        case .coarse: return "part.ask.coarse"
        case .unnamed: return "part.ask.unnamed"
        case .stranded: return "part.ask.stranded"
        case .failed: return before?.failed ?? "part.ask.failed"
        }
    }

    /// Whether what `answer` came to stays under the source's row until its next press: what
    /// went wrong does, and what the place itself now draws — a part refused, a source with
    /// none — is said once and left to the place.
    static func staysUnderRow(_ answer: MastodonSessions.PartAnswer) -> Bool {
        switch answer {
        case .refused, .hasNone, .hasNoneOfSome, .notGiven, .allowed, .putDown, .busy, .changed, .nothingLeft: false
        case .another, .less, .unconfirmed, .coarse, .unnamed, .stranded, .failed: true
        }
    }
}

extension ShellQuestion {
    /// The question put before a source's page is opened to ask a sign-in for more (#347):
    /// what the page will ask beyond what is held, that nothing is signed out to ask it, and —
    /// where the sign-in holds a word this build does not use — that asking gives it up and
    /// ends the sign-in this device had at the source. One yes, and Cancel.
    ///
    /// **Every word the page asks beyond what is held is named**: each part ticked, and each
    /// act the page brings in beside acting (`PartAsk.beside`) where the part's own words do
    /// not already say it. **And every question ends on the same two things**: that the
    /// sign-in this device had stays live at the source until the person signs out here —
    /// or, where asking gives a word up, that it is ended — and that a source already
    /// holding a sign-in for exactly this asks nothing more.
    static func part(_ ask: PartAsk, language: DummyLanguage? = nil) -> ShellConfirmation {
        let parts = PartWords.named(ask.ticked)
        // Each part's own sentence of one kind, in the table's order.
        func worded(_ what: String, of parts: [MastodonPart]) -> [String] {
            parts.map { String(format: L10n.t("part.\($0.rawValue).ask.\(what)", language: language), ask.host) }
        }
        func joined(_ sentences: [String]) -> String {
            sentences.dropFirst().reduce(sentences.first ?? "") {
                String(format: L10n.t("question.join", language: language), $0, $1)
            }
        }
        func said(_ key: String) -> String {
            String(format: L10n.t(key, language: language), ask.host)
        }
        // One part is asked under its own title; several, under one that is nobody's.
        let title = parts.count == 1 ? worded("title", of: parts)[0] : said("part.several.ask.title")
        var question: ShellConfirmation
        if let before = PartWords.own(ask.ticked)?.question(ask, language) {
            question = before
        } else {
            question = ShellConfirmation(
                symbol: SourceRow.permissionSymbol, title: title, line: joined(worded("line", of: parts)),
                help: joined(worded("detail", of: parts)),
                choices: [.init(yes, L10n.t("item.bookmark.ask.confirm", language: language), role: .keyed)],
                cancel: L10n.t("board.choose.cancel", language: language)
            )
            for sentence in worded("beside", of: ask.beside) {
                (question.line, question.help) = saying(sentence, line: question.line, help: question.help, language: language)
            }
        }
        if !ask.rest.isEmpty {
            let rest = L10n.t("part.ask.rest", language: language)
            (question.line, question.help) = saying(rest, line: question.line, help: question.help, language: language)
        }
        if ask.again {
            let why = ask.without ? said("part.ask.again.without") : L10n.t("part.ask.again", language: language)
            (question.line, question.help) = saying(why, line: question.line, help: question.help, language: language)
        }
        var after = [said("part.ask.stays"), said("part.ask.same")]
        if !ask.givesUp.isEmpty {
            let words = PartWords.shown(ask.givesUp, language: language)
            after[0] = String(format: L10n.t("part.ask.givesUp", language: language), words, ask.host)
        }
        // Behind the (?) with the rest of what the page does, and never left off for length.
        question.help = joined([question.help].compactMap { $0 } + after)
        return question
    }
}

/// The question about a part, on the root: it is put from a post's row and from Account alike,
/// and one presenter answers both — a modifier, so the root's chain gains one plain call and
/// no presenter closure of its own.
struct PartQuestion: ViewModifier {
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    let session: ShellSession

    func body(content: Content) -> some View {
        content.shellConfirm(asked, question: question, onChoice: answered)
    }

    private func question(_ ask: PartAsk) -> ShellConfirmation {
        ShellQuestion.part(ask)
    }

    private func answered(_ ask: PartAsk, _ id: String) {
        session.partAsks.answer(ask, through: WebAuthBrowser(session: webAuthenticationSession), in: session)
    }

    private var asked: Binding<PartAsk?> {
        Binding(get: { session.partAsks.open }, set: { if $0 == nil { session.partAsks.putDown() } })
    }
}
