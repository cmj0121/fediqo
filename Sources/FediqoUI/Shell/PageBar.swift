import SwiftUI

/// A mark in the bar of an opened page: a glyph, the words beside it, and what its press does.
///
/// **Its words are its name everywhere**: drawn beside the glyph where the bar has room, and
/// said to a listener and to a pointer where it has not.
struct PageMark: Identifiable {
    let symbol: String
    let name: String
    /// What a pointer is told, where that is more than the name.
    var help: String?
    /// What a listener is told the press does, where the name does not say.
    var hint: String?
    let action: () -> Void

    var id: String { symbol + "\n" + name }
}

/// What the bar of an opened page draws on a narrow page, most first (#302, F10): the first
/// that fits is drawn, and the last where none does. Back, the title and every mark's glyph
/// are on every one.
enum PageBarFit: Hashable, CaseIterable, Sendable {
    /// Everything the bar holds.
    case whole
    /// Without the hint about a key: the way back it names is the button at the bar's start.
    case unhinted
    /// And each mark as its glyph alone, still named to VoiceOver and to a pointer.
    case glyphs

    static let ladder: [PageBarFit] = [.whole, .unhinted, .glyphs]

    /// The rungs tried on `layout`, or nothing where the bar is not fitted at all: a wide page
    /// draws the one line it always did.
    static func fits(on layout: ShellLayout) -> [PageBarFit]? {
        layout == .narrow ? ladder : nil
    }

    var hintsKey: Bool { self == .whole }
    var namesMarks: Bool { self != .glyphs }
}

/// The bar of an opened page (F10): the way back, the page's title where it has no head to
/// say it, the page's marks, the mark that asks again, and the key that leaves.
///
///     ‹ Back   title                                  [marks] [↻]   Esc or q
///
/// **On a wide page it is one line.** On a narrow one every part is as wide as its words, so
/// the bar is tried as `PageBarFit` lists it and the first that fits is drawn: the hint about
/// a key goes first, then the words beside each mark, which stays as its glyph — whole, or
/// with less on it, never squeezed.
struct PageBar: View {
    /// What the page is, where no head under the bar says it.
    var title: String?
    var marks: [PageMark] = []
    /// What the mark that asks again is called — whom it asks — or nothing where there is
    /// nobody to ask: then the mark is absent.
    var reload: String?
    var onBack: () -> Void = {}
    var onReload: () -> Void = {}
    /// What stops the asking the reader pressed for, while there is such a one running: the
    /// mark that asks again is then Stop (#307). Nothing where a page has nothing to stop.
    var onStop: (() -> Void)?

    /// When the mark was last pressed to begin asking: a press on Stop just after is not heard.
    @State private var reloadPressed: Date?
    @Environment(\.shellLayout) private var shellLayout
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pageBarProbe) private var probe

    var body: some View {
        if let ladder = PageBarFit.fits(on: shellLayout) {
            ViewThatFits(in: .horizontal) {
                ForEach(ladder, id: \.self) { line($0, whole: true) }
            }
        } else {
            line(.whole, whole: false)
        }
    }

    /// `whole` holds each part to its own width, which a rung tried for size needs and the
    /// wide page's line never had.
    private func line(_ fit: PageBarFit, whole: Bool) -> some View {
        HStack(spacing: ShellSpace.snug) {
            ShellBackButton("person.back", action: onBack)
            if let title {
                Text(title)
                    .shellFont(.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .lineLimit(whole ? 1 : nil)
                    .fixedSize(horizontal: whole, vertical: false)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            ForEach(marks) { mark in
                PageMarkPress(mark: mark, named: fit.namesMarks, whole: whole)
                    .modifier(BarProbed(part: .mark(mark.symbol), probe: probe))
            }
            if let reload { again(reload) }
            if fit.hintsKey { ShellKeyHint("person.leaveHint").modifier(BarProbed(part: .hint, probe: probe)) }
        }
    }

    /// What the mark that asks again is called as it stands: whom it asks, or that it stops.
    static func againName(_ reload: String, shown: ReloadMark, language: DummyLanguage? = nil) -> String {
        shown == .stop ? L10n.t(ReloadMark.stop.name, language: language) : reload
    }

    /// **One button whose glyph and name change**, and not two that take turns, as the
    /// timelines' own mark is: a listener stays on it as it flips, and the bar does not shift.
    @ViewBuilder
    private func again(_ reload: String) -> some View {
        if let shown = ReloadMark.shown(canReload: true, stoppable: onStop != nil) {
            let name = Self.againName(reload, shown: shown)
            Button {
                switch ReloadMark.press(shown, at: Date(), pressedAt: reloadPressed) {
                case .begins:
                    reloadPressed = Date()
                    onReload()
                case .stops: onStop?()
                case .unheard: break
                }
            } label: {
                Image(systemName: shown.symbol)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .modifier(ShellGlyphBox())
            }
            .buttonStyle(.plain)
            .help(name)
            .accessibilityLabel(name)
        }
    }
}

/// One mark of the bar, pressed: its glyph with its words beside it, or its glyph alone where
/// the bar has no room for them — and then still called by them.
private struct PageMarkPress: View {
    let mark: PageMark
    let named: Bool
    let whole: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: mark.action) {
            Label(mark.name, systemImage: mark.symbol)
                .shellFont(.meta, weight: .medium)
                .lineLimit(1)
                .fixedSize(horizontal: whole, vertical: false)
                .modifier(GlyphAlone(alone: !named))
        }
        .buttonStyle(.plain)
        .foregroundStyle(ShellChrome.selectInk(colorScheme))
        .help(mark.help ?? mark.name)
        .accessibilityLabel(mark.name)
        .accessibilityHint(Text(mark.hint ?? ""))
    }
}

/// A label drawn as its glyph alone, where a line has no room for its words: the bar is no
/// taller for it.
private struct GlyphAlone: ViewModifier {
    let alone: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if alone { content.labelStyle(.iconOnly) } else { content }
    }
}

/// Which parts of a hosted bar were drawn, and how wide: what tells one rung of `PageBarFit`
/// from another.
@MainActor
final class PageBarProbe {
    enum Part: Hashable {
        /// A mark, by its glyph.
        case mark(String)
        case hint
    }

    var widths: [Part: CGFloat] = [:]
}

extension EnvironmentValues {
    /// Where a hosted bar reports what it drew. Nothing in the app.
    @Entry var pageBarProbe: PageBarProbe? = nil
}

/// Reports how wide one part of the bar was drawn to a probe, where one is handed in; draws
/// nothing either way.
private struct BarProbed: ViewModifier {
    let part: PageBarProbe.Part
    let probe: PageBarProbe?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let probe {
            content.background(GeometryReader { room in
                let _ = probe.widths[part] = room.size.width
                Color.clear
            })
        } else {
            content
        }
    }
}
