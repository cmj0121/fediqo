import SwiftUI

/// **What did not arrive, said in the frame that was waiting for it** — the place a surface puts
/// where a real thing would have been, once the wait has ended and nothing came.
///
/// ## Why this is a place and not a banner
///
/// A wait that never ends reads as the app being slow. A line somewhere else reads as a status
/// the reader has to go and find. The argument is `ShellWaiting`'s: the fact belongs in the
/// hole the thing would have filled, and every surface that can fail owes the reader the same
/// hole rather than a second vocabulary. A spinner would be a wait that did not end; an alert
/// would be a fact somewhere else. This is the plate, still, with the source named and a way
/// to ask again from here.
///
/// ## What it is
///
/// **It takes the place it is given.** A picture-sized hole, a row-sized hole and a pane-sized
/// hole are the same view under three frames. Given room, it writes the source and the retry;
/// given only an avatar's square, the whole plate is the retry and the sentence is spoken.
/// `ViewThatFits` is that split, so a surface never has to pick a compact variant.
///
/// **It names the source, and it offers try-again.** The sentence is the fact; the control is
/// the next thing to do. A screen reader hears the sentence and the retry is the action. A
/// finger presses the place. `r` is the timeline's own key and is not remapped here.
///
/// **One, not a stack.** A second failure replaces the first: this view draws whatever sources
/// it is handed, and the surface that hands them is the one that must not append.
struct ShellFailure: View {
    /// The hosts that did not answer, in the order they were asked.
    let sources: [String]
    var retry: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    init(sources: [String], retry: @escaping () -> Void) {
        self.sources = sources
        self.retry = retry
    }

    init(source: String, retry: @escaping () -> Void) {
        self.init(sources: [source], retry: retry)
    }

    /// The fact, named so a test can hold it without drawing the view.
    static func spoken(_ sources: [String]) -> String {
        String(format: L10n.t("shell.failed"), sources.joined(separator: ", "))
    }

    /// The control's name, and the VoiceOver action a reader activates to ask again.
    static var retryName: String { L10n.t("shell.failed.retry") }

    var body: some View {
        Button(action: retry) {
            ViewThatFits {
                full
                compact
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken(sources)))
        .accessibilityHint(Text(Self.retryName))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text(Self.retryName), retry)
    }

    /// Pane-sized: the source, then the retry as words a reader can press.
    private var full: some View {
        VStack(alignment: .leading, spacing: ShellSpace.snug) {
            Text(Self.spoken(sources))
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.retryName)
                .shellFont(.meta, weight: .medium)
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                .accessibilityHidden(true)
        }
        .padding(ShellSpace.pad)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Picture-sized: the still well the wait was, with the reload mark so a press is visible.
    /// Not a spinner, and not the pulsing plate — the wait has ended.
    private var compact: some View {
        RoundedRectangle(cornerRadius: ShellSpace.tight, style: .continuous)
            .fill(ShellChrome.well(colorScheme))
            .overlay {
                Image(systemName: "arrow.clockwise")
                    .shellFont(.meta, weight: .medium)
                    .foregroundStyle(ShellChrome.inkFaint(colorScheme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

#Preview("Did not arrive, at two sizes") {
    @Previewable @Environment(\.colorScheme) var scheme
    VStack(alignment: .leading, spacing: ShellSpace.step) {
        ShellFailure(source: "one.example", retry: {})
            .frame(height: 120)
        ShellFailure(source: "one.example", retry: {})
            .frame(width: 36, height: 36)
    }
    .padding(ShellSpace.pad)
    .frame(width: 360, alignment: .leading)
    .background(ShellChrome.page(scheme))
}
