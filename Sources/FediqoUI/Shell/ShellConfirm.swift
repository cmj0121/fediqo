import SwiftUI

/// A question asked before something that cannot be undone (#232) — **#231's rules, applied to
/// the one screen that must not be answered by accident.**
///
/// What it says, already in words: a title naming the act, **one line** saying what will happen,
/// and the rest behind a (?). Strings rather than keys because most of these carry a count or a
/// host (`L10n.count`, `String(format:)`), and the caller already builds that sentence.
struct ShellConfirmation: Equatable {
    /// The glyph of the act: `trash` for removing, `arrow.uturn.backward` for taking back.
    var symbol: String
    var title: String
    var line: String
    /// What the question used to say at length. Nothing where the line says it all.
    var help: String?
    /// The destructive press, named for what it does.
    var confirm: String
}

/// What the reader answered. Nothing else closes the question: Escape, Cancel, a click outside or
/// a swipe down are all `.cancel`.
enum ShellConfirmAnswer: Equatable {
    case confirm
    case cancel

    /// The one door to the act. Only a clear yes runs it; every other way out leaves everything
    /// as it was.
    static func settle(_ answer: Self, act: () -> Void) {
        if answer == .confirm { act() }
    }
}

/// The question, drawn by the app rather than the system's alert.
///
///     (glyph)  Title
///              What will happen, in one line  (?)
///                                 [ Cancel ] [ Remove ]
///
/// **Cancel holds the keyboard.** It is the default focus and Escape's key; Return is given to
/// neither, so a reader who pressed Return to open this cannot answer it with the same finger.
/// The destructive press is drawn in the alarm hue and carries the destructive role, so VoiceOver
/// says so before it is pressed.
struct ShellConfirmCard: View {
    let question: ShellConfirmation
    let answer: (ShellConfirmAnswer) -> Void

    private enum Field: Hashable { case cancel, confirm }
    @FocusState private var focus: Field?
    @Environment(\.colorScheme) private var colorScheme
    @ShellMetric(relativeTo: .title3) private var side: CGFloat = 36
    @ShellMetric(relativeTo: .body) private var measure: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: ShellSpace.pad) {
            HStack(alignment: .top, spacing: ShellSpace.step) {
                glyph
                words
            }
            presses
        }
        .padding(ShellSpace.room)
        .frame(maxWidth: measure)
        .background(ShellChrome.page(colorScheme))
        .defaultFocus($focus, .cancel)
        .onAppear { focus = .cancel }
    }

    private var glyph: some View {
        Image(systemName: question.symbol)
            .shellFont(.pane)
            .foregroundStyle(ShellChrome.alarm(colorScheme))
            .frame(width: side, height: side)
            .background(Circle().fill(ShellChrome.well(colorScheme)))
            .accessibilityHidden(true)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(question.title)
                .shellFont(.pane)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ShellConfirmLine(line: question.line, help: question.help)
        }
    }

    private var presses: some View {
        HStack(spacing: ShellSpace.snug) {
            Spacer(minLength: 0)
            Button(L10n.t("confirm.cancel"), role: .cancel) { answer(.cancel) }
                .keyboardShortcut(.cancelAction)
                .focused($focus, equals: .cancel)
            Button(question.confirm, role: .destructive) { answer(.confirm) }
                .tint(ShellChrome.alarm(colorScheme))
                .focused($focus, equals: .confirm)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

/// The one line, and its (?) where there is more.
private struct ShellConfirmLine: View {
    let line: String
    let help: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.tight) {
            Text(line)
                .shellFont(.body)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            if let help { ShellHelp(verbatim: help) }
        }
    }
}

/// Puts the question up while `item` holds a value, and takes it down however it is answered.
///
/// **A modifier, and the only way this is presented**, so a screen asks in one line and the
/// closure presenter stays out of any long view chain (the runner's type checker). `item` is what
/// the act is about — how many months, which source — and is what `onConfirm` is handed, so the
/// answer acts on the value that was asked about and not on whatever is current when it lands.
struct ShellConfirm<Value>: ViewModifier {
    @Binding var item: Value?
    let question: (Value) -> ShellConfirmation
    let onConfirm: (Value) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: asking) {
            if let value = item {
                ShellConfirmCard(question: question(value)) { answer in
                    item = nil
                    ShellConfirmAnswer.settle(answer) { onConfirm(value) }
                }
                .presentationSizing(.fitted)
                .presentationDetents([.medium])
            }
        }
    }

    /// Up while there is something to ask about; any way down clears it.
    private var asking: Binding<Bool> {
        Binding(get: { item != nil }, set: { if !$0 { item = nil } })
    }
}

extension View {
    /// Asks the question `item` makes while it is set; runs `onConfirm` with it only on a clear
    /// yes. Escape, Cancel and every other way out clear `item` and change nothing else.
    func shellConfirm<Value>(
        _ item: Binding<Value?>, question: @escaping (Value) -> ShellConfirmation,
        onConfirm: @escaping (Value) -> Void
    ) -> some View {
        modifier(ShellConfirm(item: item, question: question, onConfirm: onConfirm))
    }

    /// The same, for a question about nothing but itself — the flag a screen already holds.
    func shellConfirm(
        _ isPresented: Binding<Bool>, question: ShellConfirmation, onConfirm: @escaping () -> Void
    ) -> some View {
        let item = Binding<Bool?>(
            get: { isPresented.wrappedValue ? true : nil },
            set: { isPresented.wrappedValue = $0 != nil }
        )
        return modifier(ShellConfirm(item: item, question: { _ in question }, onConfirm: { _ in onConfirm() }))
    }
}
