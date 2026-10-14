import SwiftUI

/// One thing a page counts, as its head says it: a glyph and the figure whole (F10).
///
/// **Two forms, and which is not said by colour.** A figure that opens its tab is a press on
/// a well, lit while that tab is in front — glyph filled, figure semibold, on the lamp's wash.
/// A figure that opens nothing is the glyph and the figure on no well and no press. Either
/// way a glyph alone says nothing: a pointer and a listener are told the figure's sentence.
struct PageFigure: Equatable {
    /// The glyph it wears: its tab's, where it opens one.
    let symbol: String
    /// The figure whole, its thousands apart — or nothing where none was said, and then the
    /// glyph stands alone.
    let figure: String?
    /// What a pointer and a listener are told it is: the figure in its sentence.
    let spoken: String
    /// Whether a press brings its tab in front.
    let opens: Bool
    /// Whether the tab it opens is the one in front: never of a figure that opens nothing.
    let lit: Bool

    init(symbol: String, figure: String?, spoken: String, opens: Bool = true, lit: Bool = false) {
        self.symbol = symbol
        self.figure = figure
        self.spoken = spoken
        self.opens = opens
        self.lit = opens && lit
    }

    /// What they are told a press on it does.
    static func hint(language: DummyLanguage? = nil) -> String {
        L10n.t("person.figure.hint", language: language)
    }
}

/// A `PageFigure`, drawn: the press that opens its tab, or the glyph and figure alone.
struct PageFigureView: View {
    let figure: PageFigure
    /// The press, where the figure opens its tab.
    var onOpen: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if figure.opens {
            Button(action: onOpen) { well }
                .buttonStyle(.plain)
                .help(ShellIconButton.hover(name: figure.spoken, help: PageFigure.hint()))
                .accessibilityLabel(figure.spoken)
                .accessibilityHint(PageFigure.hint())
                .accessibilityAddTraits(figure.lit ? .isSelected : [])
        } else {
            // A figure that opens nothing: words on no well, and no press.
            drawn
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .padding(.vertical, ShellSpace.tight)
                .help(figure.spoken)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(figure.spoken)
        }
    }

    private var drawn: some View {
        HStack(spacing: ShellSpace.tight) {
            Image(systemName: figure.symbol)
                .symbolVariant(figure.lit ? .fill : .none)
                .accessibilityHidden(true)
            if let said = figure.figure { Text(said).fixedSize(horizontal: false, vertical: true) }
        }
        .shellFont(.meta, weight: figure.lit ? .semibold : .regular)
    }

    private var well: some View {
        drawn
            .foregroundStyle(figure.lit ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
            .padding(.horizontal, ShellSpace.snug)
            .padding(.vertical, ShellSpace.tight)
            .background(
                Capsule(style: .continuous)
                    .fill(figure.lit ? ShellChrome.selectFill(colorScheme) : ShellChrome.well(colorScheme))
            )
            .contentShape(Capsule(style: .continuous))
    }
}
