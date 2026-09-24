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
                .modifier(ShellTouchFloor(drawn: touch))
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

/// **A finger's floor on a phone, without growing what is drawn.** The press is widened to 44
/// points — the platform's own minimum — by a content shape padded out and the padding taken back,
/// so the glyph keeps the room it takes in its row and only what a finger can land on grows. On a
/// Mac a pointer is exact, and the drawn size is the press.
struct ShellTouchFloor: ViewModifier {
    let drawn: CGFloat

    static let finger: CGFloat = 44

    /// How far the press reaches past each edge of what is drawn.
    static func spill(drawn: CGFloat) -> CGFloat {
        max(0, (finger - drawn) / 2)
    }

    func body(content: Content) -> some View {
        #if os(iOS)
        let spill = Self.spill(drawn: drawn)
        content
            .padding(spill)
            .contentShape(Rectangle())
            .padding(-spill)
        #else
        content
        #endif
    }
}

extension View {
    /// A glyph-only control drawn its own way — a pill, a floating disc — named as
    /// `ShellIconButton` names itself: on hover on a Mac, and to VoiceOver everywhere, from the
    /// same keys.
    func shellNamed(_ nameKey: String, help helpKey: String? = nil) -> some View {
        let name = L10n.t(nameKey)
        let help = helpKey.map { L10n.t($0) }
        return self
            .help(ShellIconButton.hover(name: name, help: help))
            .accessibilityLabel(name)
            .accessibilityHint(help ?? "")
    }
}
