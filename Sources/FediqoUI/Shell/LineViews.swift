import SwiftUI

/// On a joined source's page: whether what is new in its Home arrives as it happens (#325). Draws
/// what `ShellLines.offer` hands it and decides nothing: a source that cannot is dim and says so,
/// one not signed in is dim with the sentence that asks, and its press is the read-or-act question.
struct LineControl: View {
    let host: String
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let offer = session.lines.offer(host: host, in: session) {
            VStack(alignment: .leading, spacing: ShellSpace.tight) {
                switch offer {
                case .choice(let on, let standing):
                    let title = String(format: L10n.t("source.line"), host)
                    Toggle(title, isOn: Binding(
                        get: { on },
                        set: { session.lines.choose($0, host: host) }
                    ))
                    .shellFont(.reading)
                    .shellHelp(verbatim: String(format: L10n.t("source.line.help"), host), about: title)
                    if on, let line = Self.line(standing, host: host) {
                        Text(line)
                            .shellFont(.meta)
                            .foregroundStyle(ShellChrome.inkDim(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .signIn(let sentence):
                    Button(sentence) { session.lines.pressSignIn(host: host, in: session) }
                        .buttonStyle(.plain)
                        .shellFont(.reading)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(sentence)
                case .cannot(let sentence):
                    Text(sentence)
                        .shellFont(.meta)
                        .foregroundStyle(ShellChrome.inkDim(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ShellSpace.pad)
            .padding(.bottom, ShellSpace.step)
        }
    }

    /// What is said under the switch of how its line stands: open, or refused. Nothing while it
    /// is opening, waiting after a drop, or not held — reading goes on as it does without it.
    static func line(_ standing: ShellLines.Standing?, host: String, language: DummyLanguage? = nil) -> String? {
        switch standing {
        case .open?: String(format: L10n.t("source.line.open", language: language), host)
        case .refused(let status)?: String(format: L10n.t("source.line.refused", language: language), host, status)
        case .opening?, .waiting?, nil: nil
        }
    }
}

/// Over the top of the timeline in front: how many posts arrived on a line above where the
/// reader is (#325). Appearing moves nothing; the press goes up to them.
struct LineArrivedPill: View {
    let session: ShellSession
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let count = session.lines.above
        if count > 0 {
            let words = L10n.count("timeline.line.above", count)
            Button(action: { session.lines.goUp() }) {
                Label(words, systemImage: "arrow.up")
                    .shellFont(.meta)
                    .padding(.horizontal, ShellSpace.pad)
                    .padding(.vertical, ShellSpace.snug)
                    .background(Capsule(style: .continuous).fill(ShellChrome.well(colorScheme)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(ShellChrome.ink(colorScheme))
            .accessibilityLabel(words)
            .accessibilityHint(L10n.t("timeline.line.above.hint"))
            .padding(.top, ShellSpace.step)
            .transition(.opacity)
        }
    }
}

/// While the timeline is in front and the window is not in the background, the lines it wants are
/// held (#325); its leaving, a change of what is wanted, or the background lets them go. A
/// modifier of its own for `AsksOnAWait`'s reason.
struct HearsLines: ViewModifier {
    let session: ShellSession
    let timeline: TimelineQuery
    let inFront: Bool
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        let wanted = session.lines.wanted(timeline: timeline, inFront: inFront && phase != .background, in: session)
        content
            .task(id: wanted) { await session.lines.hear(wanted, in: session) }
            .onChange(of: timeline) { _, _ in session.lines.forgetAbove() }
    }
}
