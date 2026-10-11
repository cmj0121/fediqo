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
}

/// The question open about a part, and the asks on their way — **an object of the session's,
/// so an ask belongs to no view**: a page left, a card sliding away or a window closed takes
/// nothing of it along.
@MainActor
@Observable
final class ShellPartAsks {
    /// The question open, where one is. One at a time: a second raised over it takes its place.
    private(set) var open: PartAsk?

    /// The asks started by a yes and not yet landed, a source each.
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]

    /// The press on a locked act: raises the question about `host`'s sign-in and `ticked`.
    /// Sends nothing. Returns whether a question was raised — none where no part of `ticked`
    /// may be asked of that sign-in, and none while an ask of that source is on its way.
    @discardableResult
    func raise(_ ticked: Set<MastodonPart>, host raw: String, in session: ShellSession) -> Bool {
        let host = raw.lowercased()
        let mastodon = session.mastodon
        let asked = ticked.filter { mastodon.mayAsk($0, host: host) }
        guard !asked.isEmpty, !mastodon.asking.contains(host), let held = mastodon.heldParts[host] else { return false }
        open = PartAsk(
            host: host, ticked: asked, said: MastodonParts.page(held: held.scopes, ticked: asked),
            givesUp: MastodonParts.unknown(in: held.scopes), stamp: held.stamp
        )
        return true
    }

    /// The question answered no, dismissed, or overtaken: everything stays as it was.
    func putDown() {
        open = nil
    }

    /// The question answered yes: the ask it starts is kept here until it lands, behind any
    /// of that source's started before it. The card has put its question down by the time it
    /// hands the answer over, so what makes a yes stale is looked for where the ask begins —
    /// the sign-in the question was about must still be the one held (`MastodonSessions.ask`).
    func answer(_ ask: PartAsk, through browser: any OAuthBrowser, in session: ShellSession) {
        if open == ask { open = nil }
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
    /// question was drawn from, the question is put again, drawn from what is held now.
    func allow(_ ask: PartAsk, through browser: any OAuthBrowser) async {
        let host = ask.host
        if rowRefusal?.host == host { rowRefusal = nil }
        let answer = await mastodon.ask(ask.ticked, host: host, through: browser, answering: ask)
        await forgetReaderMarksDue()
        if case .failed(let failure) = answer {
            NetLog.auth.notice("\(NetLog.line("part", host: host, error: failure), privacy: .public)")
        }
        if let key = PartWords.said(answer, of: ask.ticked) {
            if isAdded(host), PartWords.staysUnderRow(answer) { rowRefusal = (host: host, key: key) }
            showToast(String(format: L10n.t(key), host))
        }
        if answer == .changed { partAsks.raise(ask.ticked, host: host, in: self) }
        if answer == .allowed || answer == .notGiven, mastodon.isSignedIn(host: host) { await readAsYou(host: host) }
    }
}

/// The words an ask in place is put and answered in.
///
/// **A part's own are found by its name**: `part.<name>.ask.title`, `.line` and `.detail`, and
/// a question about several parts says each one's. A part asked before there was a table
/// keeps the sentences it had where it is asked alone (`earlier`), and where a part has none
/// of its own for an outcome, the outcome's own sentence is said.
@MainActor
enum PartWords {
    /// The sentences a part was asked in before every part went one way.
    struct Earlier {
        /// Its question, as it was worded.
        let question: @MainActor (PartAsk, DummyLanguage?) -> ShellConfirmation
        let failed: String
        let hasNone: String
    }

    static let earlier: [MastodonPart: Earlier] = [
        .bookmarks: Earlier(
            // Worded for the notices too, where the page carries the ones the sign-in holds.
            question: { ShellQuestion.bookmarks(host: $0.host, notices: MastodonOAuth.notices($0.said), language: $1) },
            failed: "account.bookmarks.failed", hasNone: "account.bookmarks.unavailable"
        ),
    ]

    /// The parts a question about `ticked` words, every one, in the table's order.
    static func named(_ ticked: Set<MastodonPart>) -> [MastodonPart] {
        MastodonPart.allCases.filter(ticked.contains)
    }

    /// The sentences `ticked` was asked in before, where it is the one part that has any: a
    /// question about several is worded by the table for each.
    static func own(_ ticked: Set<MastodonPart>) -> Earlier? {
        ticked.count == 1 ? ticked.first.flatMap { earlier[$0] } : nil
    }

    /// The most words a question names as given up, and the most of each: they are whatever
    /// a source chose to call them.
    static let wordsShown = 3
    static let wordLength = 24

    /// The words a question says are given up: the first few, each cut short, and how many
    /// more there are.
    static func shown(_ words: [String], language: DummyLanguage? = nil) -> String {
        let few = words.prefix(wordsShown).map { $0.count > wordLength ? String($0.prefix(wordLength)) + "…" : $0 }
        let listed = few.joined(separator: ", ")
        guard words.count > few.count else { return listed }
        return String(format: L10n.t("part.ask.givesUp.more", language: language), listed, words.count - few.count)
    }

    /// The key of the sentence that says what `answer` came to, with the source for its one
    /// argument — or nothing where there is nothing to say.
    static func said(_ answer: MastodonSessions.PartAnswer, of ticked: Set<MastodonPart>) -> String? {
        let before = own(ticked)
        switch answer {
        case .allowed, .putDown, .busy, .changed: return nil
        // With no press in it: the press is the place's own line (`part.ask.refused`).
        case .refused: return "part.ask.refused.said"
        case .hasNone, .notGiven: return before?.hasNone ?? "part.ask.none"
        case .another: return "part.ask.another"
        case .less: return "part.ask.less"
        case .unconfirmed: return "part.ask.unconfirmed"
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
        case .refused, .hasNone, .notGiven, .allowed, .putDown, .busy, .changed: false
        case .another, .less, .unconfirmed, .unnamed, .stranded, .failed: true
        }
    }
}

extension ShellQuestion {
    /// The question put before a source's page is opened to ask a sign-in for more (#347):
    /// what the page will ask beyond what is held, that nothing is signed out to ask it, and —
    /// where the sign-in holds a word this build does not use — that asking gives it up and
    /// ends the sign-in this device had at the source. One yes, and Cancel.
    static func part(_ ask: PartAsk, language: DummyLanguage? = nil) -> ShellConfirmation {
        let parts = PartWords.named(ask.ticked)
        // Each part's own sentence of one kind, in the table's order.
        func worded(_ what: String) -> [String] {
            parts.map { L10n.t("part.\($0.rawValue).ask.\(what)", language: language) }
        }
        func joined(_ sentences: [String]) -> String {
            sentences.dropFirst().reduce(sentences.first ?? "") {
                String(format: L10n.t("question.join", language: language), $0, $1)
            }
        }
        // One part is asked under its own title; several, under one that is nobody's.
        let title = parts.count == 1 ? worded("title")[0] : L10n.t("part.ask.title", language: language)
        let details = worded("detail") + [L10n.t("part.ask.detail", language: language)]
        var question = PartWords.own(ask.ticked)?.question(ask, language) ?? ShellConfirmation(
            symbol: SourceRow.permissionSymbol,
            title: String(format: title, ask.host),
            line: joined(worded("line")),
            help: joined(details.map { String(format: $0, ask.host) }),
            choices: [.init(yes, L10n.t("item.bookmark.ask.confirm", language: language), role: .keyed)],
            cancel: L10n.t("board.choose.cancel", language: language)
        )
        if !ask.givesUp.isEmpty {
            let words = PartWords.shown(ask.givesUp, language: language)
            let given = String(format: L10n.t("part.ask.givesUp", language: language), words, ask.host)
            // Behind the (?) with the rest of what the page does, and never left off for length.
            question.help = question.help.map { joined([$0, given]) } ?? given
        }
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
