import SwiftUI

/// A control that is only a glyph, and names itself (#232) — **rule 1 of #231, as a piece.**
///
/// What it is (`name`) and, where there is more to say, what it does (`help`), both as keys: the
/// hover on a Mac shows them, and VoiceOver speaks the name as the label and the help as the hint
/// everywhere. One pair of strings for the two, so a pointer and a VoiceOver reader cannot be told
/// different things about the same press.
///
/// **The timeline's header marks, lifted.** One glyph at the caption size, quiet ink, a finger's
/// worth of room round it whatever size the glyph is drawn. `tone` is the one thing a caller
/// chooses about how it looks: quiet, lit where the reader is, or the alarm a press that removes
/// something wears.
struct ShellIconButton: View {
    enum Tone: Equatable {
        case quiet
        case lit
        case alarm
    }

    let symbol: String
    let nameKey: String
    let helpKey: String?
    var tone: Tone = .quiet
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @ShellMetric(relativeTo: .caption) private var touch: CGFloat = 32

    init(
        _ symbol: String, name nameKey: String, help helpKey: String? = nil, tone: Tone = .quiet,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.nameKey = nameKey
        self.helpKey = helpKey
        self.tone = tone
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .shellFont(.meta, weight: .medium)
                .foregroundStyle(ink)
                .frame(minWidth: touch, minHeight: touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.hover(name: name, help: help))
        .accessibilityLabel(name)
        .accessibilityHint(help ?? "")
        .accessibilityAddTraits(tone == .lit ? .isSelected : [])
    }

    var name: String { L10n.t(nameKey) }
    var help: String? { helpKey.map { L10n.t($0) } }

    /// What the pointer is shown: the name, and the help after it where there is any.
    static func hover(name: String, help: String?) -> String {
        guard let help, !help.isEmpty else { return name }
        return "\(name). \(help)"
    }

    private var ink: Color {
        guard isEnabled else { return ShellChrome.inkFaint(colorScheme) }
        switch tone {
        case .quiet: return ShellChrome.inkDim(colorScheme)
        case .lit: return ShellChrome.selectInk(colorScheme)
        case .alarm: return ShellChrome.alarm(colorScheme)
        }
    }
}
