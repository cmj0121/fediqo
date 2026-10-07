import CoreGraphics
import SwiftUI

/// One spacing scale for the shell. Every gap in a pane is one of these.
///
/// Three panes used to carry a private metrics table each, and the gaps between them
/// drifted — 16, 12, 10, 8, 6, 4 all appeared, and none of them agreed about what a
/// step was. These are the steps.
enum ShellSpace {
    /// A rule, a border, a lamp's own width before it is doubled.
    static let hair: CGFloat = 1

    /// Inside a control: glyph to its count, cap to its edge.
    static let tight: CGFloat = 4

    /// Between things that belong together: an avatar and the name beside it.
    static let snug: CGFloat = 8

    /// Between the parts of one row.
    static let step: CGFloat = 12

    /// A pane's own margin, and the gap between its blocks.
    static let pad: CGFloat = 16

    /// Around something that has to stand alone.
    static let room: CGFloat = 24
}

/// One ladder of corners, as `ShellSpace` is one ladder of gaps: the four rungs a corner that was
/// spelled as a bare number is now read from.
///
/// **Not yet every corner in the shell.** Some are still `ShellSpace.tight` used as a radius, and
/// some come from a pane's own table (`DummyItemRow.Box.plate`, `AttachmentViewer.Box.corner`);
/// those were named already and were left where they are.
///
/// The literals 3, 4, 6 and 10 were each spelled where they were drawn, and two private tables
/// (`RailView.Metrics.wellRadius`, `AccountPane.Metrics.fieldRadius`) named one rung each; those
/// two now read theirs from here. Nothing was moved to another rung: these are the four the
/// shell already drew.
enum ShellRadius {
    /// A row's plate, the plate under a row's mark, a tick box.
    static let well: CGFloat = 3

    /// A cap, a chip, a picked choice: the corner of something a glyph or a word sits on.
    static let chip: CGFloat = ShellSpace.tight

    /// A field's box, a band heading, a bubble over the page.
    static let field: CGFloat = 6

    /// A card that stands on the page by itself.
    static let card: CGFloat = 10
}

/// The way back, at the head of whatever the walk stepped onto — a conversation, somebody's page,
/// a page read out of a post (#169). **One button for the three**, so a reader who has learnt to
/// leave one has learnt to leave the others, and a fourth is drawn the same without being copied.
/// What it says is each place's own, and so is any key that leaves it too — `shortcut`, put on
/// the button itself.
struct ShellBackButton: View {
    let titleKey: String
    let shortcut: KeyboardShortcut?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// The one glyph that means "back", here and on every bare back button (`ShellDetailHead`,
    /// the rule editor's, the edge swipe's row on Gestures). `chevron.left`, not
    /// `chevron.backward`: two of the five drew the other, and the two differ only where a
    /// language reads right to left, which none of this app's three does.
    static let symbol = "chevron.left"

    init(_ titleKey: String, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.titleKey = titleKey
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(L10n.t(titleKey), systemImage: Self.symbol)
                .shellFont(.meta, weight: .medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShellChrome.selectInk(colorScheme))
        .keyboardShortcut(shortcut)
    }
}

/// A press written as words in the page's own line — read the rest, try again, open it in a
/// browser, show what is covered. **One face for all of them**: `.meta` at medium weight in the
/// ink a selection is drawn in, no plate and no border, with a glyph before the words where the
/// press has one.
///
/// Eight sites drew this by hand and three of them had drifted: one semibold, one regular, and
/// one left to the system's own button, which is a bordered capsule on a Mac and blue text on a
/// phone. What each says and does is its own; how it looks is this.
struct ShellLinkButton: View {
    let title: String
    let symbol: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let symbol {
                Label(title, systemImage: symbol)
            } else {
                Text(title)
            }
        }
        .shellFont(.meta, weight: .medium)
        .buttonStyle(.plain)
        .foregroundStyle(ShellChrome.selectInk(colorScheme))
    }
}

/// The shell's one-pixel rule, wherever a surface divides.
///
/// **A view rather than three copies of five lines.** `AccountPane`, `JoinSheet` and
/// `SourcePreviewView` each grew a byte-identical `private var hairline`, and eleven other sites
/// spell the same `Rectangle` inline — of which **eight omit `.accessibilityHidden(true)`**, so a
/// VoiceOver reader hears the shell's rules in some panes and not others. Somewhere to put the
/// answer is what that drift was missing.
///
/// **The scheme comes from its own environment**, so callers pass nothing and cannot pass the
/// wrong one.
///
/// **Across or down.** A rule across takes the width it is given and one point of height; a rule
/// down — a thread's rail, the edge between the rail and the page — takes the height and one
/// point of width. Five sites drew the second by hand because there was only the first.
struct ShellRule: View {
    let axis: Axis
    @Environment(\.colorScheme) private var colorScheme

    /// `axis` is the way the rule runs: `.horizontal` across, `.vertical` down.
    init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    var body: some View {
        Rectangle()
            .fill(ShellChrome.hairline(colorScheme))
            // A hair across the way it runs, and as much as it is given along it.
            .frame(
                width: axis == .horizontal ? nil : ShellSpace.hair,
                height: axis == .vertical ? nil : ShellSpace.hair
            )
            .accessibilityHidden(true)
    }
}
