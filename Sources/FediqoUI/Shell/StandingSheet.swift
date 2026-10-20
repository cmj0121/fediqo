import FediqoCore
import SwiftUI

/// A mute or a block asked about before it is sent (#314): who, at which source, and — for a
/// whole server — which server; and how much this device holds of them, which the person says
/// what becomes of.
///
/// **The sheet is the question.** Nothing is sent while it is up, and leaving it any way but its
/// one yes sends nothing and changes nothing.
struct StandingAsk: Identifiable, Equatable {
    /// `.mute`, `.block` or `.blockServer`.
    let act: PersonAct
    /// Whose page it was asked from.
    let who: DummyPerson
    /// Their handle, made fit for a line.
    let named: String
    /// Their handle as the source spelt it: what this device's posts of them are told by.
    let handle: String
    /// The source it is sent to.
    let source: String
    /// The server a whole server's block names. Nothing for a mute or a block of one person.
    let server: String?
    /// How many posts this device holds of them — of everybody of the server, for its block.
    let held: Int

    var id: String { who.id + "\u{1e}" + String(describing: act) }
}

/// What the sheet says, as a value: its title, what the act takes away, and the words of each
/// choice — worked out here, so it is checked without standing a view up.
struct StandingSheetSaid: Equatable {
    let ask: StandingAsk

    private var key: String {
        switch ask.act {
        case .mute: "standing.mute"
        case .block: "standing.block"
        default: "standing.server"
        }
    }

    func title(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t(key + ".title", language: language), ask.server ?? ask.named)
    }

    /// What the act takes away, as the source does it.
    func line(language: DummyLanguage? = nil) -> String {
        String(format: L10n.t(key + ".line", language: language), ask.server ?? ask.named, ask.source)
    }

    /// The press that sends it.
    func yes(language: DummyLanguage? = nil) -> String {
        L10n.t(key + ".yes", language: language)
    }

    /// Whether the yes takes away more than the person's own view: a whole server's block ends
    /// follows of people the reader may never have looked at. Drawn as a loss.
    var destructive: Bool { ask.act == .blockServer }

    /// Whether the sheet asks how long, and whether notices go too: a mute's alone.
    var asksLength: Bool { ask.act == .mute }

    /// One length a mute is offered for, in words.
    static func length(_ seconds: Int?, language: DummyLanguage? = nil) -> String {
        guard let seconds else { return L10n.t("standing.mute.forGood", language: language) }
        let key = switch seconds {
        case ..<3600: "standing.mute.minutes"
        case ..<86400: "standing.mute.hours"
        default: "standing.mute.days"
        }
        let count = seconds < 3600 ? seconds / 60 : seconds < 86400 ? seconds / 3600 : seconds / 86400
        return String(format: L10n.t(key + (count == 1 ? ".one" : ""), language: language), count)
    }

    /// The heading over what becomes of what is held, with how much that is.
    func heldTitle(language: DummyLanguage? = nil) -> String {
        let one = ask.held == 1
        let subject = ask.act == .blockServer ? "server" : "person"
        return String(
            format: L10n.t("standing.held.\(subject)\(one ? ".one" : "")", language: language), ask.held, ask.server ?? ask.named
        )
    }

    /// One answer of what becomes of what is held, in words.
    static func held(_ held: StandingChoice.Held, language: DummyLanguage? = nil) -> String {
        L10n.t("standing.held.\(held.rawValue)", language: language)
    }
}

/// The sheet a mute or a block is asked on (#314), drawn from its value.
struct StandingSheet: View {
    let said: StandingSheetSaid
    @Binding var choice: StandingChoice
    let onYes: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShellSpace.pad) {
                Text(said.title())
                    .shellFont(.pane)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(said.line())
                    .shellFont(.reading)
                    .foregroundStyle(ShellChrome.inkDim(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                if said.asksLength { length }
                if said.ask.held > 0 { held }
                presses
            }
            .padding(ShellSpace.room)
        }
        .background(ShellChrome.page(colorScheme))
        .frame(minWidth: 320, idealWidth: 420)
    }

    private var length: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(L10n.t("standing.mute.length"))
                .shellFont(.meta, weight: .medium)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .accessibilityAddTraits(.isHeader)
            ForEach(StandingChoice.lengths, id: \.self) { seconds in
                ChoiceLine(words: StandingSheetSaid.length(seconds), chosen: choice.seconds == seconds) { choice.seconds = seconds }
            }
            Toggle(L10n.t("standing.mute.notices"), isOn: $choice.notices)
                .shellFont(.reading)
                .padding(.top, ShellSpace.tight)
        }
    }

    private var held: some View {
        VStack(alignment: .leading, spacing: ShellSpace.tight) {
            Text(said.heldTitle())
                .shellFont(.meta, weight: .medium)
                .foregroundStyle(ShellChrome.ink(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ForEach(StandingChoice.Held.allCases, id: \.self) { held in
                ChoiceLine(words: StandingSheetSaid.held(held), chosen: choice.held == held) { choice.held = held }
            }
        }
    }

    private var presses: some View {
        HStack(spacing: ShellSpace.snug) {
            Spacer(minLength: 0)
            Button(L10n.t("board.choose.cancel"), role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(said.yes(), role: said.destructive ? .destructive : nil, action: onYes)
                .tint(said.destructive ? ShellChrome.alarm(colorScheme) : ShellChrome.selectInk(colorScheme))
                .accessibilityHint(said.destructive ? L10n.t("confirm.destructive.hint") : "")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

/// One answer among several, as a line: a mark that says whether it is the one chosen — in its
/// shape, never by colour alone — and its words.
private struct ChoiceLine: View {
    let words: String
    let chosen: Bool
    let onChoose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onChoose) {
            HStack(alignment: .firstTextBaseline, spacing: ShellSpace.snug) {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(chosen ? ShellChrome.selectInk(colorScheme) : ShellChrome.inkDim(colorScheme))
                    .accessibilityHidden(true)
                Text(words)
                    .foregroundStyle(ShellChrome.ink(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .shellFont(.reading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(words)
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
    }
}

/// The sheet put up and taken down (#314): **in a modifier of its own**, never in the root's
/// chain of presenters (`test-before-push`).
struct StandingSheetPresenter: ViewModifier {
    let people: ShellPersonPages
    let session: ShellSession

    func body(content: Content) -> some View {
        content.sheet(item: shown) { ask in StandingSheetHost(ask: ask, people: people, session: session) }
    }

    private var shown: Binding<StandingAsk?> {
        Binding(get: { people.standingAsk }, set: { if $0 == nil { people.standingAsk = nil } })
    }
}

/// The sheet and the choice it holds while it is up: let go with the sheet.
private struct StandingSheetHost: View {
    let ask: StandingAsk
    let people: ShellPersonPages
    let session: ShellSession
    @State private var choice = StandingChoice()

    var body: some View {
        StandingSheet(
            said: StandingSheetSaid(ask: ask), choice: $choice,
            onYes: { Task { await people.answer(ask, choice, in: session) } },
            onCancel: { people.standingAsk = nil }
        )
    }
}
