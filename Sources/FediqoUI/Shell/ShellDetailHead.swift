import SwiftUI

/// The head of a list row's detail, drawn in place of the list it was opened from (#233, #234):
/// the way back, then what the detail is of — the row's own mark and title, so the reader sees
/// they are inside the row they entered — and, where the detail has one, a control of its own at
/// the end (Usage's Clear).
///
///     ‹  [mark]  title                              [control]
///
/// **Back is an icon button.** It names itself on hover and to VoiceOver. Escape is the shell's
/// on a page — `FediqoRootView` hears it before any view and closes the detail first — so only a
/// detail in a sheet, which the shell does not hear, answers the cancel key here (`escapes`).
/// The title is a header to VoiceOver, so a reader arriving in the detail hears where they are.
struct ShellDetailHead<Mark: View, Trailing: View>: View {
    let title: String
    let backName: String
    let escapes: Bool
    let onBack: () -> Void
    let mark: Mark
    let trailing: Trailing

    @Environment(\.colorScheme) private var colorScheme

    init(
        _ title: String, back backName: String = "detail.back", escapes: Bool = false, onBack: @escaping () -> Void,
        @ViewBuilder mark: () -> Mark, @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.backName = backName
        self.escapes = escapes
        self.onBack = onBack
        self.mark = mark()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: ShellSpace.snug) {
            ShellIconButton("chevron.left", name: backName, action: onBack)
                .keyboardShortcut(escapes ? .cancelAction : nil)
            mark
                .foregroundStyle(ShellChrome.selectInk(colorScheme))
                .accessibilityHidden(true)
            Text(title)
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: ShellSpace.snug)
            trailing
        }
        .textCase(nil)
    }
}

extension ShellDetailHead where Trailing == EmptyView {
    /// A head with nothing of its own at the end.
    init(
        _ title: String, back backName: String = "detail.back", escapes: Bool = false, onBack: @escaping () -> Void,
        @ViewBuilder mark: () -> Mark
    ) {
        self.init(title, back: backName, escapes: escapes, onBack: onBack, mark: mark, trailing: { EmptyView() })
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
