import FediqoCore
import SwiftUI

/// What a post said before its source changed it (#286), under the post where it is opened: each
/// wording this device held, oldest first, headed by when the source said it changed from that.
///
/// **Only where the post is opened, and only what this device held.** A row says the post was
/// changed and no more — a list under a thumb is not where two wordings are compared — and a
/// post already changed when it was first read has nothing here, since nothing is asked of its
/// source for what it said before.
///
/// **An earlier wording is the author's, cover and all.** One that was covered then — by a line
/// of warning, or marked sensitive with none — or that belongs to a post covered now, shows what
/// it was covered with and not its words: `carriedWords`' rule, for its reason, that printing
/// them underneath would lift the cover for the reader. It is uncovered by lifting the post's
/// own cover, **or by its own Show it** — which is there whenever a covered wording is drawn,
/// because a post no longer covered has no cover to lift, and a wording nothing could uncover
/// would be one this device holds and nobody can read. The same press covers it again, and
/// putting the post's own cover back covers them all.
///
/// Drawn as the copies a post was carried in are (`DummyThreadPane.carried`): a quiet heading
/// and plain, selectable text, with no mark of its own and nothing the keys walk.
struct EarlierWordings: View {
    let item: DummyItem
    /// Whether the reader has lifted the post's own cover, for this run.
    let lifted: Bool

    @Environment(\.colorScheme) private var colorScheme
    /// The wordings the reader has pressed Show it on, for as long as this pane is open.
    @State private var shown = Shown()

    /// Which wording one line is, whatever place it has in the list: when it stopped being what
    /// the post says, to the millisecond a store keeps, and what it said.
    ///
    /// **Not its place.** A wording arriving, or the oldest going, while the pane is open moves
    /// every place — and a press remembered by place would then uncover a wording nobody pressed.
    struct Key: Hashable {
        let until: Int64
        let words: String

        init(_ wording: Wording) {
            until = Int64((wording.until.timeIntervalSince1970 * 1000).rounded())
            words = wording.body
        }
    }

    /// The wordings uncovered one by one, and the two things that change them: a press, and the
    /// post's own cover going back on.
    struct Shown: Equatable {
        private(set) var keys: Set<Key> = []

        func contains(_ key: Key) -> Bool { keys.contains(key) }

        /// Show it, or cover it again: the one press, both ways.
        mutating func toggle(_ key: Key) {
            if keys.remove(key) == nil { keys.insert(key) }
        }

        /// The post's cover lifted or put back. **Put back, every wording is covered again**: the
        /// reader has asked for the cover, and a wording left open under it would not be under it.
        mutating func postCover(lifted: Bool) {
            if !lifted { keys = [] }
        }
    }

    /// One earlier wording as it is read: when it stopped being what the post says, and what it
    /// said — its warning where it had one, and its words where they may be shown.
    struct Line: Equatable, Identifiable {
        let id: Key
        let until: String
        let warning: String?
        /// Nothing while the wording is covered.
        let words: String?
        /// Whether its words are held back, and so whether Show it is offered on it.
        var covered: Bool { words == nil }
        /// Whether its words are drawn only because the reader pressed Show it on it — and so
        /// whether the press that covers it again is offered.
        let pressedOpen: Bool
    }

    /// The lines for `item`, oldest first — the one place a wording becomes something to read,
    /// so what is drawn and what a test reads are the same.
    ///
    /// `lifted` is the post's own cover lifted; `shown` are the wordings uncovered one by one.
    static func lines(
        of item: DummyItem, lifted: Bool, shown: Shown = Shown(), language: DummyLanguage? = nil
    ) -> [Line] {
        item.earlier.map { wording in
            let key = Key(wording)
            let line = wording.spoiler ?? ""
            let coverable = (item.covered || wording.covered) && !lifted
            let covered = coverable && !shown.contains(key)
            let warning: String? = line.isEmpty
                ? (covered ? L10n.t("item.covered.mark", language: language) : nil)
                : String(format: L10n.t("item.covered.warning", language: language), line)
            return Line(
                id: key,
                until: String(format: L10n.t("thread.earlier.until", language: language), when(wording.until, language: language)),
                warning: warning,
                words: covered ? nil : wording.body,
                pressedOpen: coverable && !covered
            )
        }
    }

    /// A moment as the pane says it: the day and the minute, in the shell's language.
    static func when(_ moment: Date, language: DummyLanguage? = nil) -> String {
        moment.formatted(
            .dateTime.year().month(.abbreviated).day().hour().minute().locale(L10n.locale(language))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Text(L10n.t("thread.earlier.title"))
                .shellFont(.meta, weight: .medium)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .accessibilityAddTraits(.isHeader)
            ForEach(Self.lines(of: item, lifted: lifted, shown: shown)) { line in
                VStack(alignment: .leading, spacing: ShellSpace.tight) {
                    Text(line.until)
                        .shellFont(.mark)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    if let warning = line.warning {
                        Text(warning)
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let words = line.words {
                        Text(words)
                            .shellFont(.body)
                            .foregroundStyle(ShellChrome.ink(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                // One wording, one thing heard: when it changed, then what it said — and never
                // the words of one still covered, which are not in the tree at all.
                .accessibilityElement(children: .combine)
                if line.covered || line.pressedOpen {
                    Button(L10n.t(line.covered ? "item.covered.show" : "item.covered.again")) {
                        shown.toggle(line.id)
                    }
                    .shellFont(.meta)
                    .buttonStyle(.plain)
                    .foregroundStyle(ShellChrome.selectInk(colorScheme))
                }
            }
        }
        .padding(.horizontal, ShellSpace.pad)
        .padding(.vertical, ShellSpace.snug)
        .onChange(of: lifted) { _, lifted in shown.postCover(lifted: lifted) }
    }
}
