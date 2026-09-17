import FediqoCore
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
    /// **The fallback tier, and `kindMark` below is the tier above it.** The two are one pair, and
    /// the row and the masthead glance both ask the pair in that order — so a protocol that gains
    /// a drawing gains it in *both* places at once, and neither can come to show a different
    /// picture of the same server. That property is the reason the pair is asked and not copied;
    /// a surface reading only this table would go on drawing `text.bubble` for a Discuz! the row
    /// beside it draws as a Discuz!.
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

    /// The protocol's own mark, where this repo draws one — decision 36, and decision 37 makes it
    /// the row's leading icon always rather than a fallback behind the server's own picture.
    ///
    /// **Two drawings per protocol, chosen by rendered pixels**, which is the artwork's own rule:
    /// `assets/README.md` snaps the `-small` pair to the 64-unit grid because anything narrower
    /// lands mid-pixel and anti-aliases to grey. At 24pt the row draws 24px on a 1× display and
    /// 48px on a 2×, which straddles that boundary — so the row asks rather than picks, and the
    /// gate is the pixel count and never the platform.
    ///
    /// **No `default:`.** A protocol added without an answer here falls to the shape glyph, which
    /// is a correct fallback — but it must be a *chosen* one. Discourse is the case that proves it
    /// is: it is drawn, joinable and deliberately `nil`, because this repo has no Discourse
    /// drawing and inventing one to avoid a `nil` would be worse than the glyph.
    ///
    /// Returns a name in `Media.xcassets`, drawn `.renderingMode(.template)` so it takes the
    /// enclosing ink rather than any colour of its own.
    ///
    /// The ink it takes is `ink(signedIn:quiet:scheme:)` below, on both surfaces and in both tiers.
    static func kindMark(_ kind: ProtocolKind, pixels: CGFloat) -> String? {
        // **The switch answers which protocol; the line after it answers which drawing.** They are
        // two independent questions, and a `fine ? … : …` inside every case mixed them: each new
        // protocol would have restated an artwork rule that has nothing to do with protocols, and
        // could have got it wrong one case at a time.
        let base: String?
        switch kind {
        // One drawing for the whole Mastodon-API family. What the mark says is *this is a place
        // that speaks the Mastodon API*, which is true of every fork in this list — and unit 6
        // unlocks five of them at once, so a per-fork drawing would be five drawings for one fact.
        case .mastodon, .pleroma, .akkoma, .gotosocial, .pixelfed, .friendica, .misskey:
            base = "KindMastodon"
        case .discuz:
            base = "KindDiscuz"
        // No drawing yet. The shape glyph answers, and that is a decision and not a gap.
        case .discourse, .lemmy, .peertube, .unknown:
            base = nil
        }
        // 32 rendered pixels: above it the fine drawings' geometry resolves, at or below it the
        // 64-unit pair is what stays on whole pixels.
        return base.map { pixels > 32 ? $0 : $0 + "Small" }
    }

    /// What a source's mark is drawn in: `filament` once the reader has switched this device's
    /// relationship with it on, and the surface's own quiet ink otherwise.
    ///
    /// **One function because the fact is one fact, and the surfaces disagreed about it.** The
    /// row's tier 3 hardcoded `inkFaint` with no variant while the glance's tier 3 honoured
    /// `signedIn` — unreachable today only because the one protocol with a sign-in is also the one
    /// with a drawing, so tier 3 is never reached for it. **The first protocol with a sign-in and
    /// no drawing would have made the masthead and the row say different things about one server**,
    /// which is exactly what the one-server-one-picture ruling exists to prevent, arriving through
    /// the ink instead of through the picture.
    ///
    /// `quiet` is the caller's, and the two callers differ on purpose: the row's kind mark is
    /// `inkDim` because it is a leading mark on a row of controls, the glance's is `inkFaint`
    /// because it is a glance and not a control, and either surface's shape glyph is `inkFaint`.
    /// What must not differ is **whether `signedIn` is honoured at all**, and that is this
    /// function.
    static func ink(signedIn: Bool, quiet: Color, scheme: ColorScheme) -> Color {
        signedIn ? ShellChrome.filament(scheme) : quiet
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
    /// One source, as the glance sees it: what it is, and whether this device last saw a sign-in
    /// reached there. The host is the id and is never drawn — the row below carries the identity,
    /// and this line carries the collection.
    ///
    /// **Both `kind` and `shape`, because the two tiers need one each.** `kind` asks
    /// `SourceMark.kindMark` for the protocol's own drawing; `shape` answers `SourceMark.symbol`
    /// where this repo has none. Carrying only the shape is what let the glance draw `text.bubble`
    /// over a Discuz! the row three lines below drew as a Discuz! — one server with two pictures
    /// on one screen. They are derived together in `AccountPane.mark(_:signedIn:)` from the row
    /// itself, so they cannot be handed in disagreeing.
    struct Mark: Identifiable, Hashable {
        let id: String
        let kind: ProtocolKind
        let shape: DummySourceKind
        let signedIn: Bool
    }

    let marks: [Mark]

    @Environment(\.colorScheme) private var colorScheme
    /// How many pixels a point is, so a mark can ask for the drawing made for the size it will
    /// actually be rendered at. At 16pt this glance is 16px at 1x and 32px at 2x — both at or
    /// under `kindMark`'s 32-pixel gate, so the glance is normally drawn from the `-small` pair
    /// the 64-unit grid was made for, and a 3x phone reaches the fine one.
    @Environment(\.displayScale) private var displayScale
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
    /// capability their protocols never had. Decision 33 draws no control at all for a protocol
    /// that lacks a sign-in, so there is nothing anywhere on this page implying such a reader has
    /// a sign-in to be counted — and a zero here would be a figure about nothing.
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
                    drawing(mark)
                        .frame(width: glyph, height: glyph)
                        // The same relationship spelt the same way as the row's, through the same
                        // function, so the masthead and the row agree rather than collide.
                        .foregroundStyle(Self.ink(mark, scheme: colorScheme))
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

    /// One source's picture: the protocol's own mark, or the shape glyph where this repo draws
    /// none.
    ///
    /// **The same two tiers the row asks, in the same order** — `SourceMark.kindMark` then
    /// `SourceMark.symbol`. Not a copy of the row's drawing but the same pair of questions, which
    /// is what makes "one server, one picture" hold by construction rather than by two surfaces
    /// remembering: a protocol that gains a drawing gains it here and in the row at once.
    ///
    /// **What stays different, deliberately.** This is a glance and not a control, so the quiet
    /// half is `inkFaint` where the row's kind mark is `inkDim`, and it is 16pt where the row is
    /// 24. What it *says* has not changed at all: the count and the signed-in fact, in the
    /// sentence beneath. What is **not** allowed to differ is whether `signedIn` is honoured —
    /// see `SourceMark.ink`.
    @ViewBuilder
    private func drawing(_ mark: Mark) -> some View {
        if let name = SourceMark.kindMark(mark.kind, pixels: glyph * displayScale) {
            Image(name, bundle: .module)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: SourceMark.symbol(mark.shape))
                .font(.system(size: glyph))
                .symbolVariant(mark.signedIn ? .fill : .none)
                .symbolRenderingMode(.hierarchical)
        }
    }

    /// One mark's ink. **Internal and pinned**, because "the glance and the row say the same thing
    /// about one server" is a property of these two values and not of the two drawings alone — and
    /// a colour decided inside a `View` body is reachable from nothing.
    static func ink(_ mark: Mark, scheme: ColorScheme) -> Color {
        // One quiet ink for both tiers here: a glance is not a control, so neither its kind mark
        // nor its shape glyph takes the row's `inkDim`.
        SourceMark.ink(signedIn: mark.signedIn, quiet: ShellChrome.inkFaint(scheme), scheme: scheme)
    }
}
