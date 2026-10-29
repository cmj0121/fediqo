import SwiftUI

/// One thing a page's status list says of a source (#396): its state in a sentence, and the
/// press that answers it where there is one. A page works these out from its sources; the mark
/// in its head (`StatusMark`) only draws them.
struct StatusLine: Identifiable {
    let id: String
    /// The source it is about, or nothing where it is about the whole page — a limit of this
    /// device, a read stopped as a whole. What the mark counts by.
    let host: String?
    let words: String
    /// Whether the line is counted by the mark: **it counts when the reader can act on it, or
    /// when what it describes is missing from the page** — a source held to the most kept, a
    /// source that cannot be asked. A line that only informs — a request on its way, an ask
    /// out now, a limit of this device, a failure whose retry is another line's press — is
    /// listed and not counted.
    var needsReader = true
    /// Drawn in the page's full ink: something is missing from the list under it.
    var standsOut = false
    var press: StatusPress?
}

/// What a status line offers: asking a source for the first time, or asking again.
struct StatusPress {
    enum Kind: Equatable {
        case ask
        case again
    }

    let kind: Kind
    /// What it is called to a listener, who hears it apart from the words beside it.
    let spoken: String
    let act: () -> Void

    /// Ask's glyph is the one a source's row draws where its sign-in must be asked again
    /// (`SourceRow.permissionSymbol`): the same errand, wherever a page offers it.
    var symbol: String {
        switch kind {
        case .ask: SourceRow.permissionSymbol
        case .again: "arrow.clockwise"
        }
    }

    /// Again, reading `host` once more.
    static func readAgain(_ host: String, language: DummyLanguage? = nil, act: @escaping () -> Void) -> StatusPress {
        StatusPress(
            kind: .again, spoken: String(format: L10n.t("status.press.again.read.spoken", language: language), host),
            act: act
        )
    }

    /// Again, asking `host`'s sign-in once more.
    static func askAgain(_ host: String, language: DummyLanguage? = nil, act: @escaping () -> Void) -> StatusPress {
        StatusPress(
            kind: .again, spoken: String(format: L10n.t("status.press.again.ask.spoken", language: language), host),
            act: act
        )
    }

    func word(language: DummyLanguage? = nil) -> String {
        switch kind {
        case .ask: L10n.t("status.press.ask", language: language)
        case .again: L10n.t("status.press.again", language: language)
        }
    }
}

/// What the mark says of its lines: functions of them, so a page and a test ask it alike.
enum StatusWords {
    static let symbol = "exclamationmark.circle"
    /// The mark where nothing needs the reader and something is still to be known.
    static let quietSymbol = "info.circle"

    /// How many sources need the reader: one a source named, and one a line about the page.
    /// A line that only informs is not counted.
    static func count(_ lines: [StatusLine]) -> Int {
        Set(lines.filter(\.needsReader).map { $0.host.map { "host:" + $0 } ?? $0.id }).count
    }

    /// The mark as a listener hears it: the count, and what pressing it opens — or, where no
    /// source needs the reader, that it opens what there is to know of them.
    static func spoken(_ lines: [StatusLine], language: DummyLanguage? = nil) -> String {
        let count = count(lines)
        guard count > 0 else { return L10n.t("status.mark.quiet.spoken", language: language) }
        return L10n.count("status.mark.spoken", count, language: language)
    }
}

/// **Every source's trouble and state, gathered into one mark in a page's head** (#395): an
/// icon with how many sources need the reader, which opens a small list of each — its state in
/// a sentence, and its Ask or Again. Where nothing needs the reader and something is still to
/// be known, a quiet mark with no number; nothing at all while every source is well.
///
/// A head mark of the page's own (`ShellIconButton`'s glyph box and names), so it stands among
/// the reload and `…` as one of them.
struct StatusMark: View {
    let lines: [StatusLine]
    @State private var open = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !lines.isEmpty {
            let spoken = StatusWords.spoken(lines)
            let count = StatusWords.count(lines)
            Button { open = true } label: {
                HStack(spacing: ShellSpace.hair) {
                    Image(systemName: count > 0 ? StatusWords.symbol : StatusWords.quietSymbol)
                    if count > 0 {
                        Text(L10n.grouped(count))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(count > 0 ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme))
                .modifier(ShellGlyphBox())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help(spoken)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: $open) {
                StatusList(lines: lines) { open = false }
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// The list the mark opens: a line a source, its sentence whole, and its press under or beside it.
struct StatusList: View {
    let lines: [StatusLine]
    /// The list is closed before a press acts, so what it raises is not drawn under it.
    let close: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shellStatusProbe) private var probe

    /// A press in the list: the list closes first, then the press acts — so a question it
    /// raises is not drawn under a list still open.
    static func pressed(_ press: StatusPress, close: () -> Void) {
        close()
        press.act()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { at, line in
                    if at > 0 { ShellRule() }
                    WordsThenPress(words: words(line), press: press(line))
                        .accessibilityElement(children: .contain)
                }
            }
            .padding(.vertical, ShellSpace.tight)
        }
        .scrollIndicators(.never)
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(ShellChrome.page(colorScheme))
    }

    private func words(_ line: StatusLine) -> some View {
        Text(line.words)
            .shellFont(.meta)
            .foregroundStyle(line.standsOut ? ShellChrome.ink(colorScheme) : ShellChrome.inkDim(colorScheme))
            .modifier(StatusProbed(.words(line.id), probe: probe))
    }

    @ViewBuilder
    private func press(_ line: StatusLine) -> some View {
        if let press = line.press {
            ShellLinkButton(press.word(), symbol: press.symbol) { Self.pressed(press, close: close) }
                .accessibilityLabel(press.spoken)
                .help(press.spoken)
                .fixedSize()
                .modifier(StatusProbed(.press(line.id), probe: probe))
        }
    }
}

/// The parts of a status list a hosted test reads: where each line's words and press were laid
/// out, by the line's id.
@MainActor
final class StatusProbe {
    enum Part: Hashable {
        case words(String), press(String)
    }

    var frames: [Part: CGRect] = [:]
}

extension EnvironmentValues {
    /// See `StatusProbe`. Nothing outside a test.
    @Entry var shellStatusProbe: StatusProbe?
}

/// Reports one part of a status list to a probe, where one is handed down; draws nothing.
private struct StatusProbed: ViewModifier {
    let part: StatusProbe.Part
    let probe: StatusProbe?

    init(_ part: StatusProbe.Part, probe: StatusProbe?) {
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
