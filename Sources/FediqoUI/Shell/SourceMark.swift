import SwiftUI

/// The glyph a source's shape is drawn with.
///
/// **A table and nothing else now.** This used to be a view as well — an avatar, a display name, a
/// handle and a `ShellChrome.well` capsule per source, drawn in `AccountPane`'s masthead three
/// lines above a list that said the same servers with every act attached. That view is gone; what
/// it was carrying that nothing else was is the table, and the table is shared rather than
/// restated so the source page's rows and the masthead glance cannot come to disagree about what a
/// forum looks like.
///
/// What was never safe to share was the *override* that sat over this table: a signed-in microblog
/// drawn as a person rather than as a place gave `person.crop.circle` a third meaning, and two of
/// them were on the Account page at once — the row's sign-in control being the other.
enum SourceMark {
    /// The glyph for a shape, with nobody signed in. **The one table**, read by the source page's
    /// rows and by the masthead glance.
    ///
    /// **No `default:`**, the rule this branch states everywhere it switches over a closed set: a
    /// shape swept into somebody else's glyph is a film drawn with a globe over it, and nothing
    /// would break.
    static func symbol(_ kind: DummySourceKind) -> String {
        switch kind {
        case .microblog: "globe"
        case .forum: "text.bubble"
        case .board: "list.bullet"
        // Provisional: the nearest thing already in the set, chosen so the mark is not a globe
        // while nothing can produce a `.video` source anyway. M2's PeerTube unit picks the real
        // one alongside the row that draws a film.
        case .video: "film"
        }
    }
}

/// The whole of what this device reads, on one line, without scrolling.
///
/// **What it is for, now that the Sources list exists three lines beneath it.** You read three
/// things and are signed in to one. The list below is per-source, it scrolls, and it is where a
/// reader deals with one server; this is where they see the collection. That sentence decides
/// everything drawn here, and everything not drawn: no host, no "Not signed in", no plate — all
/// three are the row's job, said better — and a count, which is the one fact a list of rows cannot
/// state at a glance.
///
/// **Six faults, answered by the drawing rather than by a comment.** It wore `ShellChrome.well`,
/// this app's statement of *pressable*, learnt from the rail's keycaps, and was a readout. It
/// duplicated the list beneath it. Its `markSymbol` gave `person.crop.circle` three meanings, two
/// of them on this page at once, and its signed-in branch was **dead**, because the value it was
/// handed was always unsigned. Its avatar was a fixed 28pt beside scaling text. It was a hidden
/// horizontal scroller on a vertically scrolling page — at 318pt with six sources the sixth was off
/// the edge and nothing said so. And it said nothing the row does not.
///
/// **`.accessibilityElement(children: .ignore)` is permitted here, and only here.** `DESIGN.md`
/// §0's eighth rule bans it on a row *containing a button*, which is the defect `PreferencesPane`
/// records shipping twice: a container collapsed to one element swallows its buttons' activation.
/// There is no button in this one. What it collapses is a glyph line and the sentence that already
/// says what the glyphs say, and collapsing them is what stops a reader hearing six unlabelled
/// images before the fact.
struct SourceMarkRow: View {
    /// One source, as the glance sees it: the shape it is drawn with, and whether this device last
    /// saw a sign-in reached there. The host is the id and is never drawn — the row below carries
    /// the identity, and this line carries the collection.
    struct Mark: Identifiable, Hashable {
        let id: String
        let shape: DummySourceKind
        let signedIn: Bool
    }

    let marks: [Mark]

    @Environment(\.colorScheme) private var colorScheme
    /// Scaling, unlike the 28pt avatar it replaces, because it sits beside text that scales.
    @ScaledMetric(relativeTo: .callout) private var glyph: CGFloat = 16

    /// How many glyphs are drawn before the line stops growing. **The sentence carries a seventh**,
    /// which is the whole reason a cap is affordable: nothing is hidden by it, because the count is
    /// stated in words directly beneath.
    static let shown = 6

    /// Whether the glance is drawn at all.
    ///
    /// **Two or more, and it disposes of the plural problem rather than working around it.** At one
    /// source the pane title says everything this line would. This repo ships no `.stringsdict` and
    /// `board.choose.threads` = "%d threads" sets the precedent, so "1 sources" is the one bad case
    /// — and it now cannot occur.
    ///
    /// A `static func` and not an `if` in a body, so the rule is drivable from a test (risk 12).
    static func drawn(sources: Int) -> Bool { sources > 1 }

    /// Which sentence the count is said in.
    ///
    /// **Chosen on `signedIn > 0`, so an all-Mastodon reader is not told "0 signed in"** about a
    /// capability their protocols never had — decision 28 draws the *control* for a protocol that
    /// lacks a sign-in, struck, because a control is where a reader asks that question. A masthead
    /// readout is not, and a zero there would be a figure about nothing.
    static func countKey(signedIn: Int) -> String {
        signedIn > 0 ? "account.standing.count.signedIn" : "account.standing.count"
    }

    /// The whole line, in words. Also the glance's spoken label, because the two are the same fact
    /// and one of them cannot be allowed to say less.
    @MainActor
    static func count(_ marks: [Mark]) -> String {
        let signedIn = marks.count(where: \.signedIn)
        let sentence = L10n.t(countKey(signedIn: signedIn))
        return signedIn > 0
            ? String(format: sentence, marks.count, signedIn)
            : String(format: sentence, marks.count)
    }

    var body: some View {
        // Built once: the drawn line and the spoken label are the same sentence, and asking for it
        // twice is two scans of the array and two bundle lookups on every redraw of the masthead.
        let line = Self.count(marks)
        return VStack(alignment: .leading, spacing: ShellSpace.tight) {
            HStack(spacing: ShellSpace.snug) {
                ForEach(marks.prefix(Self.shown)) { mark in
                    Image(systemName: SourceMark.symbol(mark.shape))
                        .font(.system(size: glyph))
                        // The same relationship spelt the same way as the row's sign-in control,
                        // so the masthead and the row agree rather than collide.
                        .symbolVariant(mark.signedIn ? .fill : .none)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(
                            mark.signedIn
                                ? ShellChrome.filament(colorScheme)
                                : ShellChrome.inkFaint(colorScheme)
                        )
                }
            }
            Text(line)
                .font(ShellType.mark)
                .foregroundStyle(ShellChrome.inkFaint(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line)
    }
}
