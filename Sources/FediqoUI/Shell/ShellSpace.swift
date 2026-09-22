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

    init(_ titleKey: String, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.titleKey = titleKey
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(L10n.t(titleKey), systemImage: "chevron.left")
                .shellFont(.meta, weight: .medium)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShellChrome.selectInk(colorScheme))
        .keyboardShortcut(shortcut)
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
struct ShellRule: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(ShellChrome.hairline(colorScheme))
            .frame(height: ShellSpace.hair)
            .accessibilityHidden(true)
    }
}
