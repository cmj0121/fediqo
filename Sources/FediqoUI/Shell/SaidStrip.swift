import SwiftUI

/// What did not happen, said at the foot of whatever page is in front (`ShellSaid`): the one
/// place a write's outcome is said when no sheet and no row is there to say it.
///
/// **An inset, not an overlay.** The page ends above it, so it covers no row, and the
/// timeline's own capsule stands over it rather than under it. It is the page's — put on each
/// place's page by the root — so it is never over the rail or the tabs, and a sheet raised from
/// the root is over it. Nothing is drawn, and no room is taken, while there is nothing to say.
///
/// **In the toast's chrome** (`TimelineToastBanner`): the same recess, ink, type and measure,
/// beside the compose button where it floats and never under it. A line carries the glyph a
/// row's mark takes where its act did not arrive (`ItemActs.glyph`), so the two read as one
/// fact, and is never cut: a sentence that does not fit one line breaks.
///
/// **It takes no focus.** A line arriving moves neither the keys nor VoiceOver; it is said
/// aloud once, by `ShellSaid.say`, and is there to be reached afterwards.
///
/// **The list behind the count is never over, or under, something the root raised.** It is
/// this page's own sheet, which the root cannot see; so the root says when it has a sheet or a
/// question up, or this page is not the one in front (`held`), and then the list is not
/// opened, and one that is open closes.
struct SaidStrip: ViewModifier {
    let said: ShellSaid
    /// The root has something raised, or this page is not in front: no list is opened here.
    var held = false

    /// The most lines drawn on a page; the rest are behind a count.
    ///
    /// **One on a narrow page**, where a line stands beside the compose button in what is left
    /// of the width and a sentence runs to several lines: three of them were most of a phone.
    static func shown(in layout: ShellLayout) -> Int {
        switch layout {
        case .narrow: 1
        case .wide: 3
        }
    }

    /// The glyph before each line: a row's own for an act that did not arrive.
    static let symbol = "exclamationmark.triangle"

    @State private var showingAll = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !said.lines.isEmpty {
                    SaidLines(said: said, showAll: { showingAll = Self.opensAll(held: held) })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: said.lines)
            .sheet(isPresented: $showingAll) {
                SaidAll(said: said) { showingAll = false }
            }
            // The last line taken down leaves nothing to list.
            .onChange(of: said.lines.isEmpty) { _, empty in
                if empty { showingAll = false }
            }
            .onChange(of: held) { _, held in
                if held { showingAll = false }
            }
    }

    /// Whether a press on the count opens the list: not while the root holds this page.
    static func opensAll(held: Bool) -> Bool { !held }

    /// What a page draws of `lines`, and how many more there are behind the count.
    static func drawn(_ lines: [Said], in layout: ShellLayout) -> (shown: [Said], more: Int) {
        let shown = shown(in: layout)
        return (Array(lines.prefix(shown)), max(0, lines.count - shown))
    }

    static func more(_ count: Int, language: DummyLanguage? = nil) -> (word: String, spoken: String) {
        (
            String(format: L10n.t("said.more", language: language), count),
            L10n.count("said.more.spoken", count, language: language)
        )
    }
}

/// The strip itself: the newest lines, newest first, and the count of the rest.
struct SaidLines: View {
    let said: ShellSaid
    let showAll: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellLayout) private var layout
    @Environment(\.shellSaidProbe) private var probe

    var body: some View {
        let drawn = SaidStrip.drawn(said.folded, in: layout)
        VStack(spacing: ShellSpace.tight) {
            ForEach(drawn.shown) { line in
                SaidLine(line: line) { said.takeDown(line.id) }
            }
            if drawn.more > 0 { more(drawn.more) }
        }
        .frame(maxWidth: TimelineToast.measure)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("said.title"))
        .padding(.horizontal, ShellSpace.pad)
        .padding(.top, ShellSpace.tight)
        .padding(.bottom, ShellSpace.snug)
        // Beside the compose button where it floats, as the toast is (#302).
        .standsBesideFloatingCorner(by: ShellSpace.pad)
        .frame(maxWidth: .infinity)
    }

    private func more(_ count: Int) -> some View {
        let more = SaidStrip.more(count)
        return ShellLinkButton(more.word, action: showAll)
            .accessibilityLabel(more.spoken)
            .help(more.spoken)
            .padding(.horizontal, ShellSpace.step)
            .padding(.vertical, ShellSpace.tight)
            .background(ShellChrome.well(colorScheme), in: Capsule())
            .modifier(SaidProbed(.more, probe: probe))
    }
}

/// One line: its glyph, its sentence whole, and the press that takes it down.
struct SaidLine: View {
    let line: Said
    let takeDown: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellSaidProbe) private var probe

    var body: some View {
        let words = line.words()
        HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
            Image(systemName: SaidStrip.symbol)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.inkDim(colorScheme))
                .accessibilityHidden(true)
            Text(words)
                .shellFont(.meta)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // A listener who is on the sentence takes it down from there, too.
                .accessibilityAction(named: L10n.t("said.close"), takeDown)
                .modifier(SaidProbed(.words(line.id), probe: probe))
            ShellIconButton("xmark", name: "said.close", action: takeDown)
                .fixedSize()
                .modifier(SaidProbed(.close(line.id), probe: probe))
        }
        .padding(.leading, ShellSpace.step)
        .padding(.trailing, ShellSpace.tight)
        .padding(.vertical, ShellSpace.tight)
        .background(
            ShellChrome.well(colorScheme),
            in: RoundedRectangle(cornerRadius: ShellSpace.step, style: .continuous)
        )
        .modifier(SaidProbed(.line(line.id), probe: probe))
    }
}

/// Every line held, behind the strip's count: a sheet, so it is left by the platform's own
/// ways — its mark, Escape, a swipe — and each line is taken down there as on the page.
struct SaidAll: View {
    let said: ShellSaid
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ShellSpace.step) {
                Text(L10n.t("said.title"))
                    .shellFont(.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                ShellLinkButton(L10n.t("said.clear")) { said.clear() }
                ShellIconButton("xmark", name: "said.all.close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(ShellSpace.pad)
            ShellRule()
            ScrollView {
                VStack(spacing: ShellSpace.tight) {
                    ForEach(said.lines) { line in
                        SaidLine(line: line) { said.takeDown(line.id) }
                    }
                }
                .padding(ShellSpace.pad)
            }
        }
        .shellSheetFloor(width: 420, height: 360)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .background(ShellChrome.page(colorScheme))
    }
}

/// Where the strip laid out each part, for a hosted test that asks.
@MainActor
final class SaidProbe {
    enum Part: Hashable {
        /// One line, its words and its press to take it down, by `Said.id`.
        case line(String), words(String), close(String)
        case more
    }

    var frames: [Part: CGRect] = [:]
}

extension EnvironmentValues {
    /// See `SaidProbe`. Nothing outside a test.
    @Entry var shellSaidProbe: SaidProbe?
}

/// Reports one part of the strip to a probe, where one is handed down; draws nothing and
/// changes nothing.
struct SaidProbed: ViewModifier {
    let part: SaidProbe.Part
    let probe: SaidProbe?

    init(_ part: SaidProbe.Part, probe: SaidProbe?) {
        self.part = part
        self.probe = probe
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let probe {
            content.background(GeometryReader { room in
                let _ = (probe.frames[part] = room.frame(in: .global))
                Color.clear
            })
        } else {
            content
        }
    }
}
