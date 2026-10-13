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
        case nil: break
        }
        return standing
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

    /// What the page's `…` offers, in the order it lists them: stopping following, or taking a
    /// request back. None while a press is on its way, and none the sign-in may not make.
    var more: [PersonAct] {
        guard changes, doing == nil, let standing = shown else { return [] }
        if standing.following { return [.unfollow] }
        return standing.requested ? [.withdraw] : []
    }

    /// Whether `act` is asked about before it is sent: unfollowing somebody who must agree to
    /// be followed, since following them again means asking again.
    func asksBefore(_ act: PersonAct) -> Bool {
        act == .unfollow && asksFirst
    }

    /// Whether "Try again" stands beside the line: the source could not be asked.
    var offersAgain: Bool { reading == .failed }

    // MARK: - Words

    /// The pills of how the reader stands to them, in the order they are drawn: they follow the
    /// reader, the reader follows them, has asked to, mutes them, blocks them.
    func pills(language: DummyLanguage? = nil) -> [String] {
        guard let standing = shown else { return [] }
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
        return pills
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

    /// The line under the heading where the source could not be asked how the reader stands.
    func failedWords(language: DummyLanguage? = nil) -> String? {
        reading == .failed ? String(format: L10n.t("person.stands.failed", language: language), source) : nil
    }

    /// The sentence of a press that did not arrive, or nothing.
    func missedWords(language: DummyLanguage? = nil) -> String? {
        missed.map { String(format: L10n.t(Self.key($0) + ".failed", language: language), named, source) }
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

    /// What an act is called in the page's `…`.
    static func name(_ act: PersonAct, language: DummyLanguage? = nil) -> String {
        L10n.t(key(act), language: language)
    }

    static func symbol(_ act: PersonAct) -> String {
        switch act {
        case .follow: "person.badge.plus"
        case .unfollow: "person.badge.minus"
        case .withdraw: "arrow.uturn.backward"
        }
    }

    private static func key(_ act: PersonAct) -> String {
        switch act {
        case .follow: "person.act.follow"
        case .unfollow: "person.act.unfollow"
        case .withdraw: "person.act.withdraw"
        }
    }

    /// The page's `…`: at its head who they are and whose view the page is, and under it what
    /// `more` offers. Unfollowing somebody who must agree is asked about first.
    @MainActor
    func menu(head: [String], act: @escaping (PersonAct) -> Void) -> ShellMore {
        ShellMore(head: head, items: more.map { offered in
            let symbol = Self.symbol(offered), name = Self.name(offered)
            guard asksBefore(offered) else { return .plain(symbol, name) { act(offered) } }
            return .danger(symbol, name, asks: ShellQuestion.unfollow(named, at: source)) { act(offered) }
        })
    }
}

/// The pills of how the reader stands to somebody, on the heading's own line: each a few words
/// of this app's on the well, as a row's source pill is.
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
        acting.press != nil || !acting.more.isEmpty
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
            if !acting.more.isEmpty {
                ShellMoreButton(label: ShellMore.label()) { acting.menu(head: head, act: onAct) }
                    .fixedSize()
            }
        }
    }
}

/// What stands under somebody's heading about how the reader stands to them, where there is
/// something to say that no pill says: how the sign-in stands, dim with the lock and pressed to
/// ask; that the source could not be asked, with the press that asks again; and a press that
/// did not arrive, in full ink.
struct PersonStandingLines: View {
    let acting: PersonActing
    var onAsk: () -> Void
    var onAgain: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// Whether there is any line to draw.
    static func draws(_ acting: PersonActing) -> Bool {
        acting.lock != nil || acting.reading == .failed || acting.missed != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let words = acting.lockWords() { locked(words) }
            if let failed = acting.failedWords() {
                WordsThenPress(
                    words: Text(failed).shellFont(.meta).foregroundStyle(ShellChrome.ink(colorScheme)),
                    press: ShellLinkButton(L10n.t("person.retry"), action: onAgain).fixedSize()
                )
            }
            if let missed = acting.missedWords() {
                Text(missed)
                    .shellFont(.meta)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.vertical, ShellSpace.snug)
            }
        }
    }

    /// How the sign-in stands, dim, after the glyph a source's row draws where its sign-in
    /// must be asked again: the whole line is the press where it asks, and words where not.
    @ViewBuilder
    private func locked(_ words: String) -> some View {
        let label = Label(words, systemImage: SourceRow.permissionSymbol)
            .shellFont(.meta)
            .foregroundStyle(ShellChrome.markDim(colorScheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.vertical, ShellSpace.snug)
        if acting.lock?.asks == true {
            Button(action: onAsk) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(L10n.t("mark.dim.askAgain"))
        } else {
            label
        }
    }
}
