import FediqoCore
import SwiftUI

/// What a source says of somebody, as their page is handed it (#310): who answered, where the
/// asking has got to, and their posts as far as the page has read them.
///
/// **Handed to the page, or not.** A page handed none is the page of somebody whose source is
/// not asked who people are — a forum's author — and draws what it always drew: what this
/// device holds of theirs, and nothing else. The page never asks which kind of source it is.
///
/// **One source's word.** Everything here is said as that source's, by name, because it may be
/// about somebody who lives elsewhere and then it is only the part that reached it.
struct PersonSaid: Equatable {
    /// Where asking who they are has got to.
    enum Reading: Equatable {
        /// The ask is out, or about to be.
        case asking
        case said(Person)
        /// The source knows nobody of that name. A state of the page, and not a failure: it
        /// answered, and this is what it said.
        case unheardOf
        /// The source refused, failed, or sent what could not be read.
        case failed
    }

    /// What asking again came to on a page the source had already answered.
    enum Trouble: Equatable {
        /// It refused, failed, or sent what could not be read.
        case failed
        /// It no longer knows anybody of that name.
        case unheardOf
    }

    /// What stands under their posts.
    enum Foot: Equatable {
        /// Older posts can be asked for: a press reads them.
        case more
        /// An older stretch is on the wire.
        case reading
        /// The source named no next: it has sent all it gives this reader.
        case end
        /// The last stretch asked for did not come. A press asks again.
        case failed
        /// The source stopped handing its posts on in order — it named a place it had named
        /// before, or went on with nothing new. The list ends here, and no press asks again.
        case stopped

        var symbol: String {
            switch self {
            case .more: "arrow.down.circle"
            case .reading: "ellipsis"
            case .end: "checkmark.circle"
            case .failed: "exclamationmark.arrow.circlepath"
            case .stopped: "exclamationmark.circle"
            }
        }

        var presses: Bool { self == .more || self == .failed }

        func words(_ source: String, language: DummyLanguage? = nil) -> String {
            switch self {
            case .more: L10n.t("person.foot.more", language: language)
            case .reading: L10n.t("person.foot.reading", language: language)
            case .end: String(format: L10n.t("person.foot.end", language: language), source)
            case .failed: String(format: L10n.t("person.foot.failed", language: language), source)
            case .stopped: String(format: L10n.t("person.foot.stopped", language: language), source)
            }
        }
    }

    /// The host of the source that says.
    let source: String
    var reading: Reading
    /// What asking again came to, where the source had said who they are before: said in a
    /// line of its own, above what it said then — which stands.
    var again: Trouble?
    /// Their posts as the source gave them, newest first — or nothing until a stretch has
    /// answered, and then what this device holds of theirs stays drawn.
    var posts: [DummyItem]?
    /// Whether who they are is being asked for.
    var asking = false
    /// Whether their newest posts are being asked for.
    var askingPosts = false
    var foot: Foot?

    var person: Person? {
        if case .said(let person) = reading { person } else { nil }
    }

    // MARK: - Words

    /// Whose view this is, on the heading's third line: the source's, by name, and where they
    /// live elsewhere where that is. **Their home is said exactly as it is held** — the one
    /// spelling a host has, `xn--…` where it is not ASCII — and never turned back into letters
    /// a stranger chose.
    static func whoseView(_ source: String, person: Person?, language: DummyLanguage? = nil) -> String {
        if let person, !person.livesHere, let home = person.home {
            return String(format: L10n.t("person.said.elsewhere", language: language), source, home)
        }
        return String(format: L10n.t("person.said.by", language: language), source)
    }

    /// What is said above everything: where the asking stands while the source has not said
    /// who they are, and — once it has — what asking again came to.
    ///
    /// **`named` is a stranger's word set inside a sentence of ours** — a handle or a name a
    /// row carried — so it is made fit to stand in one here, where the sentence is made.
    func stateLine(of named: String, language: DummyLanguage? = nil) -> String? {
        let named = LineText.oneLine(named)
        switch (reading, again) {
        case (.asking, _): return String(format: L10n.t("person.asking", language: language), source, named)
        case (.unheardOf, _): return String(format: L10n.t("person.unheardOf", language: language), source)
        case (.failed, _): return String(format: L10n.t("person.failed", language: language), source, named)
        case (.said, .failed): return String(format: L10n.t("person.again.failed", language: language), source)
        case (.said, .unheardOf): return String(format: L10n.t("person.again.unheardOf", language: language), source)
        case (.said, nil): return nil
        }
    }

    /// Whether the line above everything offers the press that asks again.
    var offersAgain: Bool { reading == .failed || again != nil }

    /// One thing the source says of the account that the page says in a line of its own.
    struct Line: Equatable, Identifiable {
        let symbol: String
        let words: String
        /// Where they went, on the line that says they moved: what its press opens.
        var moved: Person.Moved?
        var id: String { symbol }
    }

    /// What the press beside "They moved to …" says.
    static func openMoved(language: DummyLanguage? = nil) -> String {
        L10n.t("person.line.moved.open", language: language)
    }

    /// The lines an account earns, in the order they are drawn: gone before moved before the
    /// rest, since each makes what follows it matter less.
    static func lines(of person: Person, source: String, language: DummyLanguage? = nil) -> [Line] {
        var lines: [Line] = []
        func say(_ symbol: String, _ key: String, _ arguments: any CVarArg...) {
            lines.append(Line(symbol: symbol, words: String(format: L10n.t(key, language: language), arguments: arguments)))
        }
        if person.suspended { say(gone, "person.line.suspended", source) }
        if let moved = person.moved {
            say("arrow.turn.up.right", "person.line.moved", moved.lineHandle)
            lines[lines.count - 1].moved = moved
        }
        if person.limited { say("eye.slash", "person.line.limited", source) }
        switch person.sort {
        case .automated: say("gearshape.2", "person.line.automated")
        case .group: say("person.3", "person.line.group")
        case .person: break
        }
        if !person.livesHere { say("point.3.connected.trianglepath.dotted", "person.line.partial", source) }
        return lines
    }

    /// What the source counts of them, each figure it said and none it did not. **Its figures,
    /// and never a promise of rows**: it counts posts this reader is not given, and people a
    /// list leaves out.
    static func counts(of tally: Person.Tally, language: DummyLanguage? = nil) -> [String] {
        [
            tally.posts.map { figure("person.count.posts", $0, language: language) },
            tally.following.map { figure("person.count.following", $0, language: language) },
            tally.followers.map { figure("person.count.followers", $0, language: language) },
        ].compactMap { $0 }
    }

    /// One thing the source counts of them, as the head of their page says it: the glyph of the
    /// tab it counts, and the figure whole.
    struct Figure: Equatable, Identifiable {
        /// The tab whose glyph it wears, and which a press brings in front.
        let tab: PersonTab
        /// The figure whole, its thousands apart — or nothing where the source said none, and
        /// then the glyph stands alone.
        let figure: String?
        /// The figure in its sentence, or what it would count where the source said none.
        let words: String
        /// Whether a press brings its tab in front: not where the page has no such tab.
        var opens = true
        /// Whether the account says it hides the list this counts.
        var hidden = false

        var id: String { tab.rawValue }

        /// What a pointer and a listener are told it is: the figure in its sentence, and of a
        /// list the account hides, that it is hidden.
        func spoken(language: DummyLanguage? = nil) -> String {
            hidden ? String(format: L10n.t("person.figure.hidden", language: language), words) : words
        }

        /// What they are told a press on it does.
        static func hint(language: DummyLanguage? = nil) -> String {
            L10n.t("person.figure.hint", language: language)
        }
    }

    /// What the source counts of them, in the order the head draws them: their posts, who
    /// follows them, whom they follow. **Its figures, and never a promise of rows.**
    ///
    /// **Each is a press that brings its tab in front, whatever was counted**: a figure of
    /// nothing is still the way to what the source gives. Where the source said no figure the
    /// glyph stands alone and is still that press. **A list the account hides has no tab**
    /// (`tabs`): its figure stays as the source said it, opens nothing and says why — and one
    /// the source did not say is then nothing at all.
    ///
    /// **A suspended account has neither list.** Its page has said the account is gone, and
    /// the source names it and gives nothing else.
    static func figures(of person: Person, tabs: [PersonTab], language: DummyLanguage? = nil) -> [Figure] {
        func said(_ tab: PersonTab, _ counted: Int?, key: String, unsaid: String) -> Figure? {
            let opens = tabs.contains(tab)
            guard opens || counted != nil else { return nil }
            return Figure(
                tab: tab, figure: counted.map { L10n.grouped($0, language: language) },
                words: counted.map { figure(key, $0, language: language) } ?? L10n.t(unsaid, language: language),
                opens: opens, hidden: !opens && tab.list != nil && person.hidesLists
            )
        }
        let posts = said(.posts, person.tally.posts, key: "person.count.posts", unsaid: PersonTab.posts.titleKey)
        if person.suspended { return [posts].compactMap { $0 } }
        return [
            posts,
            said(.followers, person.tally.followers, key: "person.count.followers", unsaid: "person.count.followers.unsaid"),
            said(.following, person.tally.following, key: "person.count.following", unsaid: "person.count.following.unsaid"),
        ].compactMap { $0 }
    }

    /// The marks of the account after their name, in the order they are drawn: that they ask
    /// before anyone may follow, then that the source limits it, what kind of account it is,
    /// and that they live elsewhere. Each a glyph, called by the sentence About says in words.
    static func marks(of person: Person, source: String, language: DummyLanguage? = nil) -> [Line] {
        let lock = person.locked ? [Line(symbol: "lock", words: locked(language: language))] : []
        return lock + sentences(of: person, source: source, language: language)
    }

    /// The account's sentences About says in words: every line it earns but the two the page
    /// says over every tab (`standing`).
    static func sentences(of person: Person, source: String, language: DummyLanguage? = nil) -> [Line] {
        lines(of: person, source: source, language: language).filter { $0.symbol != Self.gone && $0.moved == nil }
    }

    /// The line of the account the page says over every tab: that it is suspended, or else
    /// where they moved to — the first that applies, and nothing for anybody else.
    static func standing(of person: Person, source: String, language: DummyLanguage? = nil) -> Line? {
        lines(of: person, source: source, language: language).first { $0.symbol == Self.gone || $0.moved != nil }
    }

    /// The glyph of an account its source suspended.
    static let gone = "person.slash"

    /// A sentence about one figure, with the figure written whole and its thousands apart
    /// (`L10n.grouped`), and in the words for one where it is one and the language has them.
    static func figure(_ key: String, _ value: Int, before: [String] = [], language: DummyLanguage? = nil) -> String {
        let one = L10n.t(key + ".one", language: language)
        let sentence = value == 1 && one != key + ".one" ? one : L10n.t(key, language: language)
        return String(format: sentence, arguments: before + [L10n.grouped(value, language: language)])
    }

    /// What a pointer and a listener are told the lock after a name means.
    static func locked(language: DummyLanguage? = nil) -> String {
        L10n.t("person.line.locked", language: language)
    }

    /// What stands where their posts would, once the source answered with none. **It says the
    /// source gave none, and never that there are none**: beside a count that is not nothing,
    /// it says so; and it gives no reason, because none is known here.
    static func gaveNone(_ source: String, counted: Int?, language: DummyLanguage? = nil) -> String {
        if let counted, counted > 0 {
            return figure("person.posts.noneOf", counted, before: [source], language: language)
        }
        return String(format: L10n.t("person.posts.none", language: language), source)
    }

    /// What a listener is told a checked field is.
    static func checked(_ source: String, language: DummyLanguage? = nil) -> String {
        String(format: L10n.t("person.field.checked", language: language), source)
    }
}

/// What the server somebody lives on said of them, where the person pressed to ask it (#310):
/// drawn in place of what the added source says, until they go back.
///
/// **Words and figures, and nothing that is fetched or pressed.** It carries no picture, its
/// figures open no list and the addresses in its words are letters: that server was asked one
/// thing, once, and drawing its answer asks it nothing more.
struct PersonHomeSaid: Equatable {
    /// The server asked: the one their handle names.
    let home: String
    let person: Person
    /// When it answered.
    let at: Date

    /// Whose view the heading says the page is while this is drawn, and when it was asked: so
    /// it is not taken for the added source's, nor for newer than it is.
    func whoseView(language: DummyLanguage? = nil) -> String {
        let time = at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale(language)))
        return String(format: L10n.t("person.home.said", language: language), home, time)
    }
}

/// The one line on somebody's page about the server they live on: the press that asks it,
/// where the asking stands, what it came to, or the way back to what the source says.
struct PersonHomeLine: Equatable {
    enum Press: Equatable {
        /// Ask their own server, once.
        case ask
        /// Back to what the added source says.
        case back
    }

    /// A sentence, or nothing where the press says it all.
    var words: String?
    var press: Press?
    var pressWords: String?
    /// Whether the sentence is about an ask that came to nothing, and so in full ink.
    var failed = false
}

/// The line about somebody's own server, drawn: its sentence, and the press beside or under it.
struct PersonHomeLineView: View {
    let line: PersonHomeLine
    var onPress: (PersonHomeLine.Press) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WordsThenPress(
            words: Group {
                if let said = line.words {
                    Text(said)
                        .shellFont(.meta)
                        .foregroundStyle(line.failed ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme))
                }
            },
            press: Group {
                if let act = line.press, let said = line.pressWords {
                    ShellLinkButton(said) { onPress(act) }
                        .multilineTextAlignment(.leading)
                }
            }
        )
    }
}

/// What stands under somebody's posts: older ones to read, a stretch on its way, the end of
/// what the source gives, or a stretch that did not come — the notices page's foot, for a list
/// that reads on only when pressed.
struct PersonFootRow: View {
    let symbol: String
    let words: String
    /// Whether the foot is a press: it reads on, or asks again for a stretch that did not come.
    let presses: Bool
    let onPress: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(foot: PersonSaid.Foot, source: String, onPress: @escaping () -> Void) {
        self.init(symbol: foot.symbol, words: foot.words(source), presses: foot.presses, onPress: onPress)
    }

    /// The same foot under a list that is not of posts: what it says is that list's own.
    init(symbol: String, words: String, presses: Bool, onPress: @escaping () -> Void) {
        self.symbol = symbol
        self.words = words
        self.presses = presses
        self.onPress = onPress
    }

    var body: some View {
        if presses {
            Button(action: onPress) { label(words) }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words)
                .accessibilityAddTraits(.isButton)
        } else {
            label(words)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words)
        }
    }

    private func label(_ words: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(words)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .shellFont(.meta)
        .foregroundStyle(presses ? ShellChrome.inkDim(colorScheme) : ShellChrome.inkFaint(colorScheme))
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .contentShape(Rectangle())
    }
}

/// What somebody pinned at a source, as the Pinned tab of their page is handed it: where the
/// asking has got to, and the posts as far as the tab has read them.
///
/// **In the source's own order**, which is not newest first, and never sorted here. **None
/// pinned is what the source gave, said as that**: whether anything is pinned is not known
/// until it is asked, so the tab is there either way — and a source with no such thing is
/// said the same, in the one sentence.
struct PersonPinnedSaid: Equatable {
    /// The host of the source that says.
    let source: String
    /// Whether the source has answered: what is drawn is then its word.
    var answered = false
    /// Whether asking from the top last came to a failure. With nothing answered that is the
    /// tab; with posts already given, it is said over them, and they stand.
    var failed = false
    var posts: [DummyItem] = []
    var foot: PersonSaid.Foot?

    /// What is said over the rows: that the pinned posts are being asked for, or could not be.
    func stateLine(language: DummyLanguage? = nil) -> String? {
        if failed { return String(format: L10n.t("person.pinned.failed", language: language), source) }
        return answered ? nil : String(format: L10n.t("person.pinned.asking", language: language), source)
    }

    /// What stands where rows would, once the source has answered with none.
    func nothing(language: DummyLanguage? = nil) -> String? {
        guard answered, posts.isEmpty, foot == nil else { return nil }
        return String(format: L10n.t("person.pinned.none", language: language), source)
    }

    /// What the foot says: of more to read and of the end in the tab's own words, and of a
    /// stretch on its way, one that did not come and a source that stopped as under any posts.
    func footWords(_ foot: PersonSaid.Foot, language: DummyLanguage? = nil) -> String {
        switch foot {
        case .more: L10n.t("person.pinned.foot.more", language: language)
        case .end: String(format: L10n.t("person.pinned.foot.end", language: language), source)
        case .reading, .failed, .stopped: foot.words(source, language: language)
        }
    }
}
