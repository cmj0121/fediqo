import FediqoCore
import SwiftUI

/// How the reader stands to somebody, and what may be done about it, as their page is handed
/// it (#310, #313): what the source last said, the press that is on its way, and how the
/// sign-in stands where it was not asked for this.
///
/// **Handed to the page, or not.** A page handed none is the page of somebody nobody stands to
/// here — a forum's author, a source nobody is signed in to, the reader's own page — and draws
/// no line, no press and no `…`. The page never asks which it was: what is offered at a source
/// is decided where the source is asked (`ShellPersonActs`), and this is a value.
///
/// **The source's word, with a press drawn over it and never written into it** (`shown`): what
/// the reader pressed is drawn at the press, and what the source then answers is what stands.
///
/// **Nothing is guessed.** Where the sign-in does not see how the reader stands to people,
/// there are no pills and no sentence about them — only the line that says what the sign-in
/// was not asked, dim with the lock, whose press asks.
struct PersonActing: Equatable {
    /// Where asking how the reader stands to them has got to.
    enum Reading: Equatable {
        /// The ask is out, or about to be.
        case asking
        /// As the source last said.
        case said(PersonStanding)
        /// The source answered, and said nothing of them: an account it suspended.
        case unsaid
        /// The source refused, failed, or sent what could not be read.
        case failed
    }

    /// What the heading's press does.
    enum Press: Equatable {
        /// Follows them, or asks to.
        case follow
        /// Raises the question that asks the sign-in for following.
        case ask
    }

    /// The host of the source that says, and is acted at.
    let source: String
    /// Who they are, as a sentence of ours names them: their handle, made fit for a line.
    let named: String
    /// Whether they ask before anyone may follow them.
    var asksFirst = false
    /// Whether they are somebody to follow at all: not gone, and not moved away.
    var followable = true
    /// Where the asking stands — or nothing where the sign-in does not see how the reader
    /// stands to people, and nobody was asked.
    var reading: Reading?
    /// How the sign-in stands where it holds less than following needs: the line under the
    /// heading. Nothing where it holds all of it.
    var lock: PartWords.Place?
    /// Whether the sign-in may follow and unfollow.
    var changes = false
    /// The press on its way to the source.
    var doing: PersonAct?
    /// The press that did not arrive.
    var missed: PersonAct?
    /// What the source said where it would not do the press that did not arrive, made fit for
    /// a line: said under the sentence that it did not. Nothing where it said nothing.
    var refused: String?
    /// Whether the source keeps people featured on a profile (#315): not where the host said it
    /// has no such thing this run.
    var featurable = false
    /// How the sign-in stands where it holds less than featuring needs — the account part —
    /// or nothing where it holds it.
    var accountLock: PartWords.Place?
    /// The server they live on, where it is not the source's own (#314): what blocking a whole
    /// server names. Nothing for somebody of the source itself, whose server is the reader's.
    var server: String?
    /// How the sign-in stands where it holds less than muting and blocking need (#314), or
    /// nothing where it holds them.
    var blocksLock: PartWords.Place?
    /// Whether somebody is muted and blocked at the source at all (#314): the one fact of its
    /// kind (`SourceOffers.blocks`), handed in where the source is asked.
    var blockable = false
    /// Whether somebody is reported at the source at all (#339): the one fact of its kind
    /// (`SourceOffers.reports`), handed in where the source is asked.
    var reportable = false
    /// How the sign-in stands where it holds less than reporting needs, or nothing where it holds it.
    var reportsLock: PartWords.Place?

    /// How the reader stands to them as the page draws it: what the source last said, with the
    /// press on its way drawn over it. Nothing until the source has said.
    var shown: PersonStanding? {
        guard case .said(var standing) = reading else { return nil }
        switch doing {
        case .follow:
            // Somebody who must agree is asked: the source says "asked", so it is shown so.
            standing.following = !asksFirst
            standing.requested = asksFirst
        case .unfollow: standing.following = false
        case .withdraw: standing.requested = false
        case .showBoosts: standing.showsBoosts = true
        case .hideBoosts: standing.showsBoosts = false
        case .notify: standing.notifies = true
        case .stopNotifying: standing.notifies = false
        case .acceptRequest: standing.followedBy = true
        case .refuseRequest, .removeFollower: standing.followedBy = false
        case .feature: standing.featured = true
        case .unfeature: standing.featured = false
        case .mute: standing.muting = true
        case .unmute:
            standing.muting = false
            standing.mutedUntil = nil
            standing.mutesNotices = nil
        // A block takes a follow either way with it, and a request.
        case .block, .blockServer:
            if doing == .block { standing.blocking = true } else { standing.serverBlocked = true }
            standing.following = false
            standing.requested = false
            standing.followedBy = false
        case .unblock: standing.blocking = false
        case .unblockServer: standing.serverBlocked = false
        case .dismissSuggestion, .report, nil: break
        }
        return standing
    }

    // MARK: - What is taken from somebody followed

    /// One thing taken from somebody the reader follows, as About says it (#313): whether
    /// their boosts are shown, or whether the reader is told of each of their posts — as the
    /// source last said, with a press on its way drawn over it.
    struct Narrow: Equatable, Identifiable {
        enum Which: String, CaseIterable {
            case boosts, notices
        }

        let which: Which
        /// As it stands: shown, told.
        let on: Bool

        var id: String { which.rawValue }

        /// What a press does: the act that turns it the other way.
        var act: PersonAct {
            switch which {
            case .boosts: on ? .hideBoosts : .showBoosts
            case .notices: on ? .stopNotifying : .notify
            }
        }

        var symbol: String {
            switch which {
            case .boosts: "arrow.2.squarepath"
            case .notices: "bell"
            }
        }

        func name(language: DummyLanguage? = nil) -> String { PersonActing.name(act, language: language) }

        /// How it stands, in words: nothing of it is said by a colour or a glyph alone.
        func state(language: DummyLanguage? = nil) -> String {
            L10n.t("person.narrow.\(which.rawValue).\(on ? "on" : "off")", language: language)
        }

        /// The row as it is written and read: what it is, and how it stands.
        func words(language: DummyLanguage? = nil) -> String {
            String(format: L10n.t("person.narrow.said", language: language), name(language: language), state(language: language))
        }
    }

    /// What is taken from them, in the order About draws it: their boosts, a notice of each
    /// post. **Only of somebody the reader follows** — not one only asked — **and only what
    /// the source said**: one it left out has no row, and nothing is guessed in its place.
    /// **A sign-in that sees and may not change who the reader follows is shown them too, as
    /// the source said** — plain rows that take no press (`narrowsTakePress`), beside the
    /// lock's own sentence, which goes on asking for the rest.
    func narrows() -> [Narrow] {
        guard let standing = shown, standing.following else { return [] }
        return [
            standing.showsBoosts.map { Narrow(which: .boosts, on: $0) },
            standing.notifies.map { Narrow(which: .notices, on: $0) },
        ].compactMap { $0 }
    }

    /// Whether a press on one of them is taken now: only from a sign-in that may change who
    /// the reader follows, and not while another press is on its way. **What is sent rests
    /// on this**: where it is false the rows are words, and nothing leaves for them.
    var narrowsTakePress: Bool { changes && doing == nil }

    /// What a pointer and a listener are told a press on one of them does, and where.
    func narrowHint(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("person.narrow.hint", language: language), source)
    }

    /// Whether they block the reader, as the source said: the one thing that says why it gives
    /// the reader none of their posts.
    var blockedBy: Bool { shown?.blockedBy == true }

    /// Whether the source has not said how the reader stands to them: the sign-in does not
    /// see it, the ask is out or failed, or it was answered with nothing about them. Why the
    /// source gives the reader none of their posts is then not known here.
    var givesNoneUnexplained: Bool {
        if case .said = reading { false } else { true }
    }

    /// Whether how the reader stands to them is still being asked: what stands where their
    /// posts would waits for the answer, so that no sentence there turns into another.
    var stillAsked: Bool { reading == .asking }

    /// Whether what stands where their posts would is only that the source gives this sign-in
    /// none of them, given how many it counts: where they block the reader, whatever it
    /// counts; and where it counts some and how the reader stands to them is not known.
    /// Asked once the ask is no longer out (`stillAsked`).
    func givesNone(counted: Int?) -> Bool {
        blockedBy || (givesNoneUnexplained && (counted ?? 0) > 0)
    }

    // MARK: - What is offered

    /// The heading's press, or nothing. **Follow only over what the source said**: not while
    /// it is being asked, not where they are followed or asked already, not where either
    /// blocks the other, and not while a press is on its way. Where the sign-in may not
    /// follow and may be asked to, the press asks.
    var press: Press? {
        guard followable else { return nil }
        guard changes else { return lock?.asks == true ? .ask : nil }
        guard doing == nil, let standing = shown, !standing.following, !standing.requested,
              !standing.blockedBy, !standing.blocking
        else { return nil }
        return .follow
    }

    /// What the page's `…` offers, in the order it lists them: featuring them on the reader's
    /// profile or taking them off (#315); stopping following, or taking a request back; and —
    /// under the divider, since it takes something from them — having them follow the reader
    /// no longer (#313), only where the source said they do. None while a press is on its way.
    ///
    /// **Featuring is offered only of somebody the source said the reader follows**, at a
    /// source that keeps people featured, and only where it said which of the two it is:
    /// absent otherwise, never grey. Where the sign-in lacks the account part it is offered
    /// dim with the lock (`menu`), and its press asks. The rest only to a sign-in that may
    /// change who the reader follows.
    var more: [PersonAct] {
        guard doing == nil, let standing = shown else { return [] }
        var offered: [PersonAct] = []
        if featurable, standing.following, let featured = standing.featured { offered.append(featured ? .unfeature : .feature) }
        guard changes else { return offered }
        offered += standing.following ? [.unfollow] : standing.requested ? [.withdraw] : []
        return offered + (standing.followedBy ? [.removeFollower] : [])
    }

    /// What the page's `…` offers of muting and blocking (#314), after what `more` offers: one of
    /// mute or unmute, of block or unblock, as the source said it stands — and, of somebody whose
    /// server is not the source's own, blocking that whole server or not. **Offered of anybody the
    /// source said how the reader stands to**; none while a press is on its way. Where the
    /// sign-in lacks what they need they are dim with that lock (`menu`), and a press asks.
    var keeping: [PersonAct] {
        guard blockable, doing == nil, let standing = shown else { return [] }
        var offered: [PersonAct] = [standing.muting ? .unmute : .mute, standing.blocking ? .unblock : .block]
        if server != nil { offered.append(standing.serverBlocked ? .unblockServer : .blockServer) }
        return offered
    }

    /// What the page's `…` offers last, under muting and blocking (#339): reporting them, where the
    /// source has reports — **whatever the source has said of how the reader stands**, since a
    /// report needs none of it. None while a press is on its way.
    var reporting: [PersonAct] { reportable && doing == nil ? [.report] : [] }

    /// Whether the page's `…` offers `act`: among `more`, `keeping` or `reporting`.
    func offersInMenu(_ act: PersonAct) -> Bool { more.contains(act) || keeping.contains(act) || reporting.contains(act) }

    /// The mark of a report (#339).
    static let reportSymbol = "flag"

    /// Whether `act` is one muting and blocking's that is answered on a sheet of its own before
    /// it is sent (#314): what it takes away, for how long, and what becomes of what this device
    /// holds of them. Undoing one is sent at the press.
    static func asksOnASheet(_ act: PersonAct) -> Bool {
        act == .mute || act == .block || act == .blockServer
    }

    /// Whether `act` is one of featuring's two, which want the account part.
    static func features(_ act: PersonAct) -> Bool { act == .feature || act == .unfeature }

    /// Whether a press on `act` is the lock's: it wants the account part, which the sign-in
    /// does not hold — the press then only asks.
    func asksForPart(_ act: PersonAct) -> Bool { lock(of: act) != nil }

    /// The lock a press on `act` would only ask through: the account part's for featuring,
    /// muting and blocking's for theirs (#314) — or nothing where the sign-in holds it.
    func lock(of act: PersonAct) -> PartWords.Place? {
        if Self.features(act) { return accountLock }
        if act == .report { return reportsLock }
        return act.isMuteOrBlock ? blocksLock : nil
    }

    /// Whether `act` is asked about before it is sent: unfollowing somebody who must agree to
    /// be followed, since following them again means asking again.
    func asksBefore(_ act: PersonAct) -> Bool {
        (act == .unfollow && asksFirst) || act == .removeFollower
    }

    /// The question `act` is asked about first with.
    @MainActor
    func question(before act: PersonAct) -> ShellConfirmation {
        act == .removeFollower ? ShellQuestion.about(act, named, at: source) : ShellQuestion.unfollow(named, at: source)
    }

    // MARK: - Words

    /// The pills of how the reader stands to them, in the order they are drawn: they follow the
    /// reader, the reader follows them, has asked to, mutes them, blocks them.
    func pills(language: DummyLanguage? = nil) -> [String] {
        shown.map { Self.pills(of: $0, language: language) } ?? []
    }

    /// The pills of `standing`, in that order and those words: a page's, and a row's on a list
    /// of people.
    static func pills(of standing: PersonStanding, language: DummyLanguage? = nil) -> [String] {
        var pills: [String] = []
        if standing.followedBy { pills.append(L10n.t("person.stands.followsYou", language: language)) }
        if standing.following { pills.append(L10n.t("person.stands.following", language: language)) }
        if standing.requested { pills.append(L10n.t("person.stands.asked", language: language)) }
        if standing.muting {
            pills.append(standing.mutedUntil.map { until in
                let day = until.formatted(Date.FormatStyle().day().month(.abbreviated).locale(L10n.locale(language)))
                return String(format: L10n.t("person.stands.mutedUntil", language: language), day)
            } ?? L10n.t("person.stands.muted", language: language))
        }
        if standing.blocking { pills.append(L10n.t("person.stands.blocked", language: language)) }
        if standing.serverBlocked { pills.append(L10n.t("person.stands.serverBlocked", language: language)) }
        return pills
    }

    /// One way the reader stands to them, as the head of their page draws it: a glyph, called
    /// by the words About says beside it.
    struct Mark: Equatable, Identifiable {
        let symbol: String
        let words: String
        var id: String { symbol }
    }

    /// The marks of how the reader stands to them, in the order the head draws them: the
    /// reader follows them, they follow the reader, the reader has asked to, mutes them,
    /// blocks them. **A standing that is not so has no mark**: there is no glyph for "not".
    func marks(language: DummyLanguage? = nil) -> [Mark] {
        shown.map { Self.marks(of: $0, language: language) } ?? []
    }

    static func marks(of standing: PersonStanding, language: DummyLanguage? = nil) -> [Mark] {
        var marks: [Mark] = []
        func say(_ symbol: String, _ key: String) { marks.append(Mark(symbol: symbol, words: L10n.t(key, language: language))) }
        if standing.following { say("person.fill.checkmark", "person.stands.following") }
        if standing.featured == true { say(featuredSymbol, "person.stands.featured") }
        if standing.followedBy { say("person.badge.plus", "person.stands.followsYou") }
        if standing.requested { say("person.badge.clock", "person.stands.asked") }
        if standing.muting {
            let muted = PersonStanding(accountID: standing.accountID, muting: true, mutedUntil: standing.mutedUntil)
            marks.append(Mark(symbol: "speaker.slash", words: pills(of: muted, language: language).first ?? ""))
        }
        if standing.blocking { say("hand.raised", "person.stands.blocked") }
        if standing.serverBlocked { say(serverBlockedSymbol, "person.stands.serverBlocked") }
        return marks
    }

    /// The mark of somebody whose whole server the reader blocks (#314).
    static let serverBlockedSymbol = "xmark.shield"

    /// The mark of somebody the reader features on their profile (#315).
    static let featuredSymbol = "person.crop.rectangle.stack"

    /// Whether the head of their page has anything to draw where the marks stand: a mark, or
    /// the lock of a sign-in that holds less than following needs. Nothing while it is being
    /// asked, where it could not be — the page's toast says both (DESIGN-reload) — and where
    /// the source answered with nothing about them.
    var standsInHead: Bool { !marks().isEmpty || lock != nil }

    /// What the head says in full ink under the figures, for what no glyph may say: that
    /// they block the reader, and a press that did not arrive.
    func headWords(language: DummyLanguage? = nil) -> [String] {
        [blockedWords(language: language), missedWords(language: language), refusedWords(language: language)].compactMap { $0 }
    }

    /// What the source said where it would not do the press, in its own words after its name.
    func refusedWords(language: DummyLanguage? = nil) -> String? {
        guard missed != nil, let refused, !refused.isEmpty else { return nil }
        return String(format: L10n.t("profile.refused.said", language: language), source, refused)
    }

    /// The account part's lock, in its own sentence: what the `…` says at its head over a
    /// featuring it cannot make.
    func accountLockWords(language: DummyLanguage? = nil) -> String? {
        accountLock.map { String(format: L10n.t($0.key, language: language), source) }
    }

    /// The words of the lock a press on `act` would only ask through (`lock(of:)`), as the `…`
    /// says it at its head.
    func lockWords(of act: PersonAct, language: DummyLanguage? = nil) -> String? {
        lock(of: act).map { String(format: L10n.t($0.key, language: language), source) }
    }

    /// What a listener is read of the marks, as one element: each in words, joined.
    static func spoken(_ marks: [Mark], language: DummyLanguage? = nil) -> String {
        marks.map(\.words).joined(separator: L10n.t("people.row.between", language: language))
    }

    /// What About says where the source said how the reader stands and it is none of the
    /// five; and while it is being asked.
    func neitherWords(language: DummyLanguage? = nil) -> String? {
        guard let shown, Self.marks(of: shown).isEmpty else { return nil }
        return L10n.t("person.stands.neither", language: language)
    }

    /// The sentence that they block the reader, in full ink — or nothing where they do not, or
    /// the source has not said.
    func blockedWords(language: DummyLanguage? = nil) -> String? {
        blockedBy ? String(format: L10n.t("person.stands.blockedBy", language: language), named, source) : nil
    }

    /// The line under the heading where the sign-in holds less than following needs.
    func lockWords(language: DummyLanguage? = nil) -> String? {
        lock.map { String(format: L10n.t($0.key, language: language), source) }
    }

    /// The sentence of a press that did not arrive, or nothing.
    func missedWords(language: DummyLanguage? = nil) -> String? {
        missed.map { Self.missedWords($0, named: named, at: source, language: language) }
    }

    /// The word of the heading's press: to follow, or — of somebody who must agree — to ask.
    func pressWords(language: DummyLanguage? = nil) -> String {
        L10n.t(asksFirst ? "person.act.askToFollow" : "person.act.follow", language: language)
    }

    /// What the heading's press is called to a pointer and a listener: what it will do, to
    /// whom and where — or, where it only asks, why it does not.
    func pressSpoken(language: DummyLanguage? = nil) -> String {
        if press == .ask, let why = lockWords(language: language) {
            return ShellMark.said(pressWords(language: language), why, language: language)
        }
        let key = asksFirst ? "person.act.askToFollow.spoken" : "person.act.follow.spoken"
        return String(format: L10n.t(key, language: language), named, source)
    }

    /// What a press that did not arrive is said as, of an act on somebody a sentence of ours
    /// calls `named` at `source`: the one sentence, on their page and on a row of a list.
    static func missedWords(_ act: PersonAct, named: String, at source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t(key(act) + ".failed", language: language), named, source)
    }

    /// What accepting somebody's request is called to a pointer and a listener: what it
    /// does, to whom and where.
    static func acceptSpoken(_ named: String, at source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("person.act.accept.spoken", language: language), named, source)
    }

    /// What an act is called in the page's `…`.
    static func name(_ act: PersonAct, language: DummyLanguage? = nil) -> String {
        L10n.t(key(act), language: language)
    }

    /// What an act is called in the page's `…`, of somebody whose server is `server`: blocking
    /// a whole server names it (#314).
    static func name(_ act: PersonAct, server: String?, language: DummyLanguage? = nil) -> String {
        guard act == .blockServer || act == .unblockServer, let server else { return name(act, language: language) }
        return String(format: L10n.t(key(act) + ".named", language: language), server)
    }

    static func symbol(_ act: PersonAct) -> String {
        switch act {
        case .follow: "person.badge.plus"
        case .unfollow: "person.badge.minus"
        case .withdraw: "arrow.uturn.backward"
        case .showBoosts, .hideBoosts: "arrow.2.squarepath"
        case .notify, .stopNotifying: "bell"
        case .acceptRequest: "person.crop.circle.badge.checkmark"
        case .refuseRequest: "person.crop.circle.badge.xmark"
        case .removeFollower: "person.crop.circle.badge.minus"
        case .feature, .unfeature: featuredSymbol
        case .dismissSuggestion: PeopleSaid.dismissSymbol
        case .mute: "speaker.slash"
        case .unmute: "speaker.wave.2"
        case .block: "hand.raised"
        case .unblock: "hand.raised.slash"
        case .blockServer: serverBlockedSymbol
        case .unblockServer: "checkmark.shield"
        case .report: reportSymbol
        }
    }

    private static func key(_ act: PersonAct) -> String {
        switch act {
        case .follow: "person.act.follow"
        case .unfollow: "person.act.unfollow"
        case .withdraw: "person.act.withdraw"
        case .showBoosts, .hideBoosts: "person.act.boosts"
        case .notify, .stopNotifying: "person.act.notify"
        case .acceptRequest: "person.act.accept"
        case .refuseRequest: "person.act.refuse"
        case .removeFollower: "person.act.removeFollower"
        case .feature: "person.act.feature"
        case .unfeature: "person.act.unfeature"
        case .dismissSuggestion: "people.suggested.dismiss"
        case .mute: "person.act.mute"
        case .unmute: "person.act.unmute"
        case .block: "person.act.block"
        case .unblock: "person.act.unblock"
        case .blockServer: "person.act.blockServer"
        case .unblockServer: "person.act.unblockServer"
        case .report: "person.act.report"
        }
    }

    /// The page's `…`: at its head who they are and whose view the page is, and under it what
    /// `more` offers. Unfollowing somebody who must agree is asked about first. **Featuring,
    /// where the sign-in lacks the account part, is dim with the lock**, the part's sentence
    /// at the head, and its press is `act`'s too — which only asks (`asksForPart`).
    @MainActor
    func menu(head: [String], act: @escaping (PersonAct) -> Void) -> ShellMore {
        var said = head
        let items: [ShellMoreItem] = (more + keeping + reporting).map { offered in
            let symbol = Self.symbol(offered), name = Self.name(offered, server: server)
            if let lock = lock(of: offered) {
                if let words = lockWords(of: offered), !said.contains(words) { said.append(words) }
                let dim = ShellMark(SourceRow.permissionSymbol, name, look: .dim(.askAgain))
                return ShellMoreItem.plain(dim, ask: lock.asks ? { act(offered) } : nil, act: {}).underHead
            }
            guard asksBefore(offered) else { return .plain(symbol, name) { act(offered) } }
            return .danger(symbol, name, asks: question(before: offered)) { act(offered) }
        }
        return ShellMore(head: said, items: items)
    }
}

/// What the person answered on the sheet a mute or a block is asked on (#314), beside the act.
///
/// **What becomes of what this device holds of them is the person's to say**, and is done only
/// once the source has said the act is done: a press that did not arrive changes nothing here.
struct StandingChoice: Equatable, Sendable {
    /// What becomes of the posts this device holds of them.
    enum Held: String, CaseIterable, Sendable {
        /// Drawn as hidden, each saying why, until the mute or the block is taken back.
        case hide
        /// Let go of, as a letting go by dates lets posts go: a post the person keeps stays.
        case letGo
        /// Left as it is.
        case leave
    }

    var held: Held = .hide
    /// Whether a mute keeps their notices from the reader too.
    var notices = true
    /// How long a mute lasts, in seconds; nothing, for good.
    var seconds: Int?

    /// The lengths a mute is offered for, in seconds — nothing, for good — in the order offered:
    /// the ones a Mastodon's own page offers.
    static let lengths: [Int?] = [nil, 30 * 60, 60 * 60, 6 * 60 * 60, 24 * 60 * 60, 3 * 24 * 60 * 60, 7 * 24 * 60 * 60]
}

/// The heading's press and the page's `…`, side by side: Follow — dim with the lock where the
/// sign-in must be asked first — and the menu, where it has anything to offer.
struct PersonHeadActs: View {
    let acting: PersonActing
    /// What stands at the head of the `…`: who they are, and whose view the page is.
    var head: [String] = []
    var onAct: (PersonAct) -> Void
    var onAsk: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// Whether there is anything to draw: a press, or a menu with something in it.
    static func draws(_ acting: PersonActing) -> Bool {
        acting.press != nil || !acting.more.isEmpty || !acting.keeping.isEmpty || !acting.reporting.isEmpty
    }

    var body: some View {
        HStack(alignment: .center, spacing: ShellSpace.step) {
            switch acting.press {
            case .follow:
                ShellLinkButton(acting.pressWords()) { onAct(.follow) }
                    .accessibilityLabel(acting.pressSpoken())
                    .help(acting.pressSpoken())
                    .fixedSize()
            case .ask:
                Button(action: onAsk) {
                    Label(acting.pressWords(), systemImage: SourceRow.permissionSymbol)
                        .shellFont(.meta, weight: .medium)
                        .foregroundStyle(ShellChrome.markDim(colorScheme))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(acting.pressSpoken())
                .help(L10n.t("mark.dim.askAgain"))
                .fixedSize()
            case nil:
                EmptyView()
            }
            if !acting.more.isEmpty || !acting.keeping.isEmpty || !acting.reporting.isEmpty {
                ShellMoreButton(label: ShellMore.label()) { acting.menu(head: head, act: onAct) }
                    .fixedSize()
            }
        }
    }
}

/// The pills of how the reader stands to somebody, on a row of a list of people: each a few
/// words of this app's on the well, as a row's source pill is.
struct PersonStandingPills: View {
    let pills: [String]

    var body: some View {
        if !pills.isEmpty {
            // Wrapped where one line has no room: no pill is cut.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ShellSpace.tight) { ForEach(pills, id: \.self) { ShellWellPill($0) } }
                VStack(alignment: .leading, spacing: ShellSpace.tight) { ForEach(pills, id: \.self) { ShellWellPill($0) } }
            }
        }
    }
}
