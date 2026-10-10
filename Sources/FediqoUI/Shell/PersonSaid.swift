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
        if person.suspended { say("person.slash", "person.line.suspended", source) }
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

/// What the source says of somebody, drawn as the first rows of their page's list: so it
/// scrolls away with their posts, and the heading above stays a face and three lines.
struct PersonSaidBlock: View {
    let person: Person
    let source: String
    /// The press beside "They moved to …": that account's page, through this same source.
    /// Nothing where the block is drawn with nobody to answer, and then the line is words alone.
    var onOpenMoved: ((Person.Moved) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .body) private var bandHeight: CGFloat = 96
    @ShellMetric(relativeTo: .caption2) private var sealColumn: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.step) {
            let lines = PersonSaid.lines(of: person, source: source)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    ForEach(lines) { line in
                        let words = HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                            Image(systemName: line.symbol).accessibilityHidden(true)
                            Text(line.words).fixedSize(horizontal: false, vertical: true)
                        }
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .accessibilityElement(children: .combine)
                        if let moved = line.moved, let onOpenMoved {
                            // The words, and the press under them where one line has no room
                            // for both: neither is cut.
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.step) {
                                    words.fixedSize()
                                    movedPress(moved, onOpenMoved)
                                }
                                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                                    words
                                    movedPress(moved, onOpenMoved)
                                }
                            }
                        } else {
                            words
                        }
                    }
                }
            }
            if let header = person.headerURL {
                // The picture at the head of their profile: a low band, the source's own copy.
                RemoteImage(
                    url: header, tier: .deck, host: source, standing: .picture, alt: nil, speaks: false,
                    radius: DummyItemRow.Box.plate
                )
                .frame(maxWidth: .infinity)
                .frame(height: bandHeight)
                .clipped()
                .accessibilityHidden(true)
            }
            if !person.words.isEmpty {
                EmojiText(prose: person.words, emojis: person.emojis, host: source)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !person.fields.isEmpty { fields }
            let counts = PersonSaid.counts(of: person.tally)
            if !counts.isEmpty {
                // Each figure whole, wrapped to the next line where they do not fit on one.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: ShellSpace.room) { ForEach(counts, id: \.self) { Text($0).fixedSize() } }
                    VStack(alignment: .leading, spacing: ShellSpace.tight) { ForEach(counts, id: \.self) { Text($0) } }
                }
                .shellFont(.reading)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func movedPress(_ moved: Person.Moved, _ open: @escaping (Person.Moved) -> Void) -> some View {
        ShellLinkButton(PersonSaid.openMoved()) { open(moved) }.fixedSize()
    }

    /// The fields they filled in: a label, and what stands under it.
    ///
    /// **The source's "checked" is a mark of ours, in a place of its own**: after the value, in
    /// the shell's own ink, outside the run their letters and pictures are drawn in — so
    /// nothing they wrote, a custom emoji least of all, can stand where it stands.
    private var fields: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            ForEach(Array(person.fields.enumerated()), id: \.offset) { _, field in
                HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
                    // The seal's own column, before the label and as wide for every field: no
                    // letter or picture of theirs is ever drawn in it.
                    Group {
                        if field.verifiedAt != nil {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                                .help(PersonSaid.checked(source))
                                .accessibilityLabel(PersonSaid.checked(source))
                        } else {
                            Color.clear.accessibilityHidden(true)
                        }
                    }
                    .shellFont(.mark)
                    .frame(width: sealColumn, alignment: .leading)
                    VStack(alignment: .leading, spacing: ShellSpace.hair) {
                        EmojiText(field.name, emojis: person.emojis, host: source, role: .meta)
                            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                            .lineLimit(1)
                        EmojiText(field.value, emojis: person.emojis, host: source, role: .meta)
                            .foregroundStyle(ShellChrome.ink(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// What stands under somebody's posts: older ones to read, a stretch on its way, the end of
/// what the source gives, or a stretch that did not come — the notices page's foot, for a list
/// that reads on only when pressed.
struct PersonFootRow: View {
    let foot: PersonSaid.Foot
    let source: String
    let onPress: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let words = foot.words(source)
        if foot.presses {
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
            Image(systemName: foot.symbol)
                .accessibilityHidden(true)
            Text(words)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .shellFont(.meta)
        .foregroundStyle(foot.presses ? ShellChrome.inkDim(colorScheme) : ShellChrome.inkFaint(colorScheme))
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.step)
        .contentShape(Rectangle())
    }
}
