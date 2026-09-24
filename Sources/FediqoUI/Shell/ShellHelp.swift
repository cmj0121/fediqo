import SwiftUI

/// The (?) beside a short line, and the long explanation behind it (#232) — **rule 2 of #231.**
///
/// A press opens a small bubble beside the mark, on a Mac and on an iPhone alike: `.popover` is
/// a sheet on a compact width unless it is told otherwise, and `presentationCompactAdaptation`
/// is what keeps it a bubble on a phone. A second press, a press outside it, or Escape closes it.
///
/// **Three readers, one string.** On a Mac the pointer shows the whole text on hover without a
/// press; VoiceOver speaks it as the mark's hint, so a reader who never opens the bubble has
/// still heard it; the bubble is the finger's way to it. `.help` alone does nothing on a phone,
/// which is why the mark exists at all.
///
/// While the bubble is open the mark is lit, filled and in the lamp's hue — the one place on the
/// screen the reader has just asked about.
struct ShellHelp: View {
    let text: String

    @State private var shown = false

    /// The explanation behind `key`.
    init(_ key: String) {
        text = L10n.t(key)
    }

    /// An explanation already built — a sentence with a count or a name in it.
    init(verbatim text: String) {
        self.text = text
    }

    var body: some View {
        ShellHelpButton(text: text, shown: $shown)
    }
}

/// The mark as a press, with where its bubble's state is kept handed in — `ShellHelp` keeps it in
/// its own `@State`; a test keeps it where it can read it back.
struct ShellHelpButton: View {
    let text: String
    @Binding var shown: Bool
    @ShellMetric(relativeTo: .caption) private var touch: CGFloat = 24

    var body: some View {
        Button(action: press) {
            ShellHelpMark(lit: shown)
                .frame(minWidth: touch, minHeight: touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel(L10n.t("help.more"))
        .accessibilityHint(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            ShellHelpBubble(text: text)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// A press opens the bubble, and a press on the lit mark closes it.
    func press() {
        shown.toggle()
    }
}

/// The mark itself: a circled question, quiet until its bubble is open.
struct ShellHelpMark: View {
    let lit: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "questionmark.circle")
            .symbolVariant(lit ? .fill : .none)
            .shellFont(.meta, weight: .medium)
            .foregroundStyle(lit ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkFaint(colorScheme))
            .accessibilityHidden(true)
    }
}

/// What the bubble holds: the text, at a reading measure, and nothing else.
struct ShellHelpBubble: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .body) private var measure: CGFloat = 280

    var body: some View {
        Text(text)
            .shellFont(.body)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: measure, alignment: .leading)
            .padding(ShellSpace.step)
    }
}

extension View {
    /// This view, with the (?) for `key` after it — the one line a screen writes to put a short
    /// line's long explanation behind it.
    func shellHelp(_ key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
            self
            ShellHelp(key)
        }
    }
}
