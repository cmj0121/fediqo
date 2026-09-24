import SwiftUI

/// The head of a list row's detail, drawn in place of the list it was opened from (#233): the way
/// back, then what the detail is of — the row's own glyph and title, so the reader sees they are
/// inside the row they entered.
///
///     ‹  [mark]  title
///
/// **Back is an icon button, and Escape.** It names itself on hover and to VoiceOver, and answers
/// the cancel key, so a detail opened by Return is left by the keyboard as well as by a press.
/// The title is a header to VoiceOver, so a reader arriving in the detail hears where they are.
struct ShellDetailHead<Mark: View>: View {
    let title: String
    let onBack: () -> Void
    let mark: Mark

    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .callout) private var side: CGFloat = 28

    init(_ title: String, onBack: @escaping () -> Void, @ViewBuilder mark: () -> Mark) {
        self.title = title
        self.onBack = onBack
        self.mark = mark()
    }

    var body: some View {
        HStack(spacing: ShellSpace.snug) {
            ShellIconButton("chevron.left", name: "detail.back", action: onBack)
                .keyboardShortcut(.cancelAction)
            mark
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                .frame(width: side, height: side)
                .background(
                    RoundedRectangle(cornerRadius: RailView.Metrics.wellRadius, style: .continuous)
                        .fill(ShellChrome.selectFill(colorScheme))
                )
                .accessibilityHidden(true)
            Text(title)
                .shellFont(.name)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .textCase(nil)
    }
}

/// One fact of a detail: what it is, and under it what it says — under rather than beside, so a
/// long answer has the row's width on a phone. One element to VoiceOver, read label then value.
struct ShellDetailFact: View {
    let label: String
    let value: String
    var alarm = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.hair) {
            Text(label)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
            Text(value)
                .foregroundStyle(alarm ? ShellChrome.alarm(colorScheme) : ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A list's ↑ and ↓ (`ShellListRow.onStep`): the row after or before the lit one, or the first
/// or last where none is lit — the timeline's own step, over any list's ids.
enum ShellListStep {
    static func stepped<ID: Equatable>(_ ids: [ID], from lit: ID?, by step: Int) -> ID? {
        DummyCommand.stepped(ids, from: lit, by: step) ?? lit
    }
}
